package local.islet.link.link

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.os.ParcelUuid
import android.provider.Settings
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import local.islet.link.features.Features
import local.islet.link.wire.Link
import local.islet.link.wire.Message
import org.json.JSONObject

/** A Mac found on the network (for pairing). */
data class FoundMac(val id: String, val name: String, val host: String, val port: Int)

sealed interface LinkState {
    /** Not paired with any Mac yet. */
    data object Unpaired : LinkState
    /** Paired; looking for the Mac. */
    data class Searching(val macName: String) : LinkState
    data class Pairing(val macName: String, val code: String?) : LinkState
    data class Connected(val macName: String, val transport: Transport) : LinkState
}

data class MacStatus(
    val name: String = "Mac",
    val battery: Int? = null,
    val charging: Boolean = false,
    val volume: Float = 0.5f,
    val brightness: Float? = null,
)

data class MacMedia(
    val title: String,
    val artist: String,
    val album: String,
    val app: String,
    val durationMs: Long,
    val positionMs: Long,
    val stampMs: Long,
    val playing: Boolean,
    val art: Bitmap?,
) {
    fun positionAt(now: Long): Long {
        val moved = if (playing) now - stampMs else 0
        val position = positionMs + moved
        return if (durationMs > 0) position.coerceIn(0, durationMs) else position
    }
}

data class Transfer(val name: String, val done: Long, val total: Long, val incoming: Boolean)

/**
 * The phone's side of Islet Link: one Mac, reached over USB (adb reverse), Wi-Fi
 * (Bonjour/NSD) or Bluetooth (an L2CAP channel), always on the fastest link available.
 * Lives as long as the process; [LinkService] keeps the process alive while paired.
 */
@SuppressLint("MissingPermission")
class LinkManager(private val context: Context) : Connection.Listener {
    private val prefs = context.getSharedPreferences("link", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val dialer = Executors.newCachedThreadPool()

    val phoneId: String = prefs.getString("phoneId", null) ?: UUID.randomUUID().toString().also {
        prefs.edit().putString("phoneId", it).apply()
    }

    private val _state = MutableStateFlow<LinkState>(LinkState.Unpaired)
    val state: StateFlow<LinkState> = _state.asStateFlow()
    private val _found = MutableStateFlow<List<FoundMac>>(emptyList())
    val found: StateFlow<List<FoundMac>> = _found.asStateFlow()
    private val _mac = MutableStateFlow(MacStatus())
    val mac: StateFlow<MacStatus> = _mac.asStateFlow()
    private val _media = MutableStateFlow<MacMedia?>(null)
    val media: StateFlow<MacMedia?> = _media.asStateFlow()
    private val _shortcuts = MutableStateFlow<List<String>>(emptyList())
    val shortcuts: StateFlow<List<String>> = _shortcuts.asStateFlow()
    private val _transfer = MutableStateFlow<Transfer?>(null)
    val transfer: StateFlow<Transfer?> = _transfer.asStateFlow()
    /** One-off notes for the UI ("Allow Accessibility on the Mac"). */
    val notes = MutableSharedFlow<String>(extraBufferCapacity = 4)

    @Volatile private var active: Connection? = null
    private val attempts = mutableSetOf<Transport>()
    private var loop: Job? = null
    private var pairingWith: FoundMac? = null

    val pairedMacId: String? get() = prefs.getString("macId", null)
    val pairedMacName: String get() = prefs.getString("macName", null) ?: "your Mac"

    init {
        if (pairedMacId != null) _state.value = LinkState.Searching(pairedMacName)
    }

    val identity: Connection.Identity
        get() = Connection.Identity(
            phoneId,
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL,
            "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}",
        )

    val connected: Boolean get() = active?.phase == Connection.Phase.READY

    // MARK: Running

    /** Starts the keep-connected loop (the foreground service calls this). */
    fun run() {
        if (loop?.isActive == true) return
        loop = scope.launch {
            var tick = 0
            while (isActive) {
                if (pairedMacId != null) maintain(tick)
                tick++
                delay(4000)
            }
        }
    }

    fun stop() {
        loop?.cancel()
        loop = null
        stopDiscovery()
        stopBluetoothScan()
        active?.close()
    }

    private fun maintain(tick: Int) {
        val current = active?.takeIf { it.phase == Connection.Phase.READY }
        // Keep-alive, and drop a link that went quiet.
        if (current != null) {
            if (tick % 6 == 0) current.send(Message.of("ping"))
            if (System.currentTimeMillis() - current.lastHeard > 75_000) current.close()
        }
        val transport = current?.transport
        if (usbPlugged() && (transport == null || transport > Transport.USB)) dialTcp("127.0.0.1", Link.PORT, Transport.USB)
        if (transport == null || transport > Transport.WIFI) {
            if (onWifi()) {
                startDiscovery()
                _found.value.firstOrNull { it.id == pairedMacId }?.let { dialTcp(it.host, it.port, Transport.WIFI) }
                    ?: prefs.getString("lastHost", null)?.let { dialTcp(it, Link.PORT, Transport.WIFI) }
            }
        } else {
            stopDiscovery()
        }
        if (current == null && Features.prefs(context).getBoolean("bluetooth", true)) startBluetoothScan() else stopBluetoothScan()
    }

    private fun usbPlugged(): Boolean {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        return battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) == BatteryManager.BATTERY_PLUGGED_USB
    }

    private fun onWifi(): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val caps = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }


    // MARK: Dialling

    private fun dialTcp(host: String, port: Int, transport: Transport, pairing: Boolean = false) {
        synchronized(attempts) { if (!attempts.add(transport)) return }
        dialer.execute {
            try {
                val socket = Socket()
                socket.tcpNoDelay = true
                socket.keepAlive = true
                socket.connect(InetSocketAddress(host, port), if (transport == Transport.USB) 800 else 2500)
                adopt(Connection(transport, socket.getInputStream(), socket.getOutputStream(), { socket.close() },
                                 identity, pairing, this))
            } catch (error: Exception) {
                // Nothing there (yet): the next tick tries again.
            } finally {
                synchronized(attempts) { attempts.remove(transport) }
            }
        }
    }

    private fun adopt(connection: Connection) {
        connection.start()
    }

    /** Pair with a Mac found on Wi-Fi: both screens then show the same code. */
    fun pair(mac: FoundMac) {
        pairingWith = mac
        _state.value = LinkState.Pairing(mac.name, null)
        dialTcp(mac.host, mac.port, Transport.WIFI, pairing = true)
    }

    /** Pair over USB (adb reverse), for when Wi-Fi discovery isn't possible. */
    fun pairOverUsb() {
        pairingWith = FoundMac("", "Mac over USB", "127.0.0.1", Link.PORT)
        _state.value = LinkState.Pairing("your Mac", null)
        dialTcp("127.0.0.1", Link.PORT, Transport.USB, pairing = true)
    }

    fun cancelPairing() {
        if (_state.value is LinkState.Pairing) {
            active?.takeIf { it.phase != Connection.Phase.READY }?.close()
            _state.value = if (pairedMacId != null) LinkState.Searching(pairedMacName) else LinkState.Unpaired
        }
    }

    fun forget() {
        Log.i("IsletLink", "forgetting the Mac")
        active?.send(Message.of("unpair"))
        scope.launch {
            delay(300)
            active?.close()
        }
        prefs.edit().remove("macId").remove("macName").remove("secret").remove("lastHost").apply()
        _state.value = LinkState.Unpaired
        _media.value = null
    }

    // MARK: Connection.Listener

    override fun secretFor(macId: String): ByteArray? =
        if (macId == pairedMacId) prefs.getString("secret", null)?.let { Base64.decode(it, Base64.NO_WRAP) } else null

    override fun onPairingCode(connection: Connection, code: String) {
        active = connection
        _state.value = LinkState.Pairing(connection.macName, code)
    }

    override fun onPaired(connection: Connection, secret: ByteArray) {
        Log.i("IsletLink", "paired with ${connection.macName}")
        prefs.edit()
            .putString("macId", connection.macId)
            .putString("macName", connection.macName)
            .putString("secret", Base64.encodeToString(secret, Base64.NO_WRAP))
            .commit()
        pairingWith?.takeIf { it.host != "127.0.0.1" }?.let { prefs.edit().putString("lastHost", it.host).apply() }
        pairingWith = null
        LinkService.start(context)
    }

    override fun onPairNeeded(connection: Connection) {
        Log.i("IsletLink", "Mac ${connection.macName} says pair again")
        if (connection.macId == pairedMacId) {
            // The Mac forgot this phone: start over.
            prefs.edit().remove("macId").remove("secret").apply()
            _state.value = LinkState.Unpaired
            notes.tryEmit("Your Mac forgot this phone. Pair again.")
        }
    }

    override fun onPairDeclined(connection: Connection) {
        _state.value = if (pairedMacId != null) LinkState.Searching(pairedMacName) else LinkState.Unpaired
        notes.tryEmit("Pairing was declined on the Mac.")
    }

    override fun onReady(connection: Connection) {
        val previous = active
        if (previous != null && previous !== connection && previous.phase == Connection.Phase.READY) {
            // Keep the faster link; let the other one go once the new one is up.
            if (connection.transport.rank > previous.transport.rank) { connection.close(); return }
            scope.launch { delay(1500); if (!previous.busySending) previous.close() }
        }
        active = connection
        if (connection.transport == Transport.WIFI) {
            _found.value.firstOrNull { it.id == connection.macId }?.let { prefs.edit().putString("lastHost", it.host).apply() }
        }
        prefs.edit().putString("macName", connection.macName).apply()
        _state.value = LinkState.Connected(connection.macName, connection.transport)
        stopBluetoothScan()
        Features.onConnected(context, this)
        LinkService.refresh(context)
    }

    override fun onMessage(connection: Connection, message: Message) {
        val json = message.json
        when (message.type) {
            "status" -> _mac.value = MacStatus(
                name = json.optString("name", "Mac"),
                battery = if (json.has("battery")) json.optInt("battery") else null,
                charging = json.optBoolean("charging"),
                volume = json.optDouble("volume", 0.5).toFloat(),
                brightness = json.optDouble("brightness", -1.0).takeIf { it >= 0 }?.toFloat(),
            )
            "media.state" -> {
                val art = if (message.body.isNotEmpty()) BitmapFactory.decodeByteArray(message.body, 0, message.body.size)
                          else _media.value?.takeIf { it.title == json.optString("title") }?.art
                _media.value = MacMedia(
                    json.optString("title"), json.optString("artist"), json.optString("album"), json.optString("app"),
                    json.optLong("duration"), json.optLong("position"), System.currentTimeMillis(),
                    json.optBoolean("playing"), art,
                )
                LinkService.refresh(context)
            }
            "media.clear" -> { _media.value = null; LinkService.refresh(context) }
            "shortcuts" -> _shortcuts.value = json.optJSONArray("names")?.let { names -> List(names.length()) { names.getString(it) } } ?: emptyList()
            "remote.denied" -> notes.tryEmit("Allow Islet in Accessibility on your Mac to use the trackpad and keyboard.")
            "unpair" -> {
                prefs.edit().remove("macId").remove("secret").apply()
                _state.value = LinkState.Unpaired
            }
            else -> Features.handle(context, this, message)
        }
    }

    override fun openIncoming(connection: Connection, name: String, size: Long, mime: String): IncomingSink? =
        Features.openIncoming(context, name, size, mime)

    override fun onTransfer(connection: Connection, name: String, done: Long, total: Long, incoming: Boolean) {
        _transfer.value = if (done >= total) null else Transfer(name, done, total, incoming)
        Features.transferProgress(context, name, done, total, incoming)
    }

    override fun onClosed(connection: Connection) {
        if (active !== connection) return
        active = null
        when (_state.value) {
            is LinkState.Connected -> _state.value = if (pairedMacId != null) LinkState.Searching(pairedMacName) else LinkState.Unpaired
            is LinkState.Pairing -> if (pairedMacId == null) _state.value = LinkState.Unpaired
            else -> Unit
        }
        _transfer.value = null
        LinkService.refresh(context)
    }

    // MARK: Sending (UI and features)

    fun send(message: Message) { active?.takeIf { it.phase == Connection.Phase.READY }?.send(message) }

    fun send(file: OutgoingFile): Boolean {
        val connection = active?.takeIf { it.phase == Connection.Phase.READY } ?: return false
        connection.send(file)
        return true
    }

    fun macCommand(action: String, value: Double? = null, name: String? = null) =
        send(Message.of("mac.cmd", buildMap {
            put("action", action)
            value?.let { put("value", it) }
            name?.let { put("name", it) }
        }))

    fun input(kind: String, vararg fields: Pair<String, Any>) =
        send(Message.of("input", mapOf("kind" to kind) + fields))

    /** Updates the local copy straight away so sliders don't jump while dragging. */
    fun setMacVolume(value: Float) {
        _mac.value = _mac.value.copy(volume = value)
        macCommand("volume", value.toDouble())
    }

    fun setMacBrightness(value: Float) {
        _mac.value = _mac.value.copy(brightness = value)
        macCommand("brightness", value.toDouble())
    }

    // MARK: Wi-Fi discovery (NSD)

    private var discovery: NsdManager.DiscoveryListener? = null
    private val nsd by lazy { context.getSystemService(NsdManager::class.java) }
    private val resolving = Executors.newSingleThreadExecutor()

    fun startDiscovery() {
        if (discovery != null) return
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { discovery = null }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) { resolving.execute { resolve(info) } }
            override fun onServiceLost(info: NsdServiceInfo) {
                _found.value = _found.value.filterNot { it.name == info.serviceName }
            }
        }
        discovery = listener
        runCatching { nsd.discoverServices(Link.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { discovery = null }
    }

    fun stopDiscovery() {
        val listener = discovery ?: return
        discovery = null
        runCatching { nsd.stopServiceDiscovery(listener) }
    }

    @Suppress("DEPRECATION")
    private fun resolve(info: NsdServiceInfo) {
        val lock = Object()
        var done = false
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                synchronized(lock) { done = true; lock.notifyAll() }
            }

            override fun onServiceResolved(resolved: NsdServiceInfo) {
                val host = resolved.host?.hostAddress
                val id = resolved.attributes["id"]?.let { String(it) } ?: ""
                if (host != null && !host.contains(':')) {
                    val mac = FoundMac(id, resolved.serviceName, host, resolved.port)
                    _found.value = _found.value.filterNot { it.id == id || it.name == mac.name } + mac
                    // Our Mac just (re)appeared: connect now rather than on the next tick.
                    if (id == pairedMacId && active?.transport.let { it == null || it == Transport.BLUETOOTH }) {
                        dialTcp(host, resolved.port, Transport.WIFI)
                    }
                }
                synchronized(lock) { done = true; lock.notifyAll() }
            }
        })
        // Older Android resolves one service at a time.
        synchronized(lock) { if (!done) lock.wait(5000) }
    }

    // MARK: Bluetooth (L2CAP)

    private var scanning: ScanCallback? = null
    private val bluetooth by lazy { context.getSystemService(BluetoothManager::class.java)?.adapter }

    private fun bluetoothAllowed(): Boolean =
        Build.VERSION.SDK_INT < 31 ||
            (ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED)

    private fun startBluetoothScan() {
        if (scanning != null || !bluetoothAllowed() || bluetooth?.isEnabled != true) return
        val scanner = bluetooth?.bluetoothLeScanner ?: return
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                stopBluetoothScan()
                connectBluetooth(result.device)
            }
        }
        scanning = callback
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build()
        runCatching { scanner.startScan(listOf(filter), settings, callback) }.onFailure { scanning = null }
    }

    private fun stopBluetoothScan() {
        val callback = scanning ?: return
        scanning = null
        runCatching { bluetooth?.bluetoothLeScanner?.stopScan(callback) }
    }

    private fun connectBluetooth(device: BluetoothDevice) {
        synchronized(attempts) { if (!attempts.add(Transport.BLUETOOTH)) return }
        device.connectGatt(context, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) gatt.discoverServices()
                else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    gatt.close()
                    synchronized(attempts) { attempts.remove(Transport.BLUETOOTH) }
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val characteristic = gatt.getService(SERVICE)?.getCharacteristic(PSM)
                if (characteristic == null || !gatt.readCharacteristic(characteristic)) gatt.disconnect()
            }

            @Deprecated("Deprecated in Java")
            override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                @Suppress("DEPRECATION") val value = characteristic.value ?: byteArrayOf()
                gatt.disconnect()
                if (value.size < 2) return
                val psm = ((value[0].toInt() and 0xFF) shl 8) or (value[1].toInt() and 0xFF)
                dialer.execute {
                    try {
                        val socket = device.createInsecureL2capChannel(psm)
                        socket.connect()
                        adopt(Connection(Transport.BLUETOOTH, socket.inputStream, socket.outputStream, { socket.close() },
                                         identity, false, this@LinkManager))
                    } catch (error: Exception) {
                        Log.i("IsletLink", "L2CAP failed: $error")
                    } finally {
                        synchronized(attempts) { attempts.remove(Transport.BLUETOOTH) }
                    }
                }
            }
        }, BluetoothDevice.TRANSPORT_LE)
    }

    companion object {
        val SERVICE: UUID = UUID.fromString("6E1A0001-6C69-4E6B-8A1E-15E7E0000001")
        val PSM: UUID = UUID.fromString("6E1A0002-6C69-4E6B-8A1E-15E7E0000001")

        @Volatile private var instance: LinkManager? = null
        fun get(context: Context): LinkManager =
            instance ?: synchronized(this) { instance ?: LinkManager(context.applicationContext).also { instance = it } }
    }
}

/** Convenience for JSON fields in features. */
fun JSONObject.optStringOrNull(key: String): String? = if (has(key) && !isNull(key)) optString(key) else null
