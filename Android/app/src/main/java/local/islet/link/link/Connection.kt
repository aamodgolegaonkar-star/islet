package local.islet.link.link

import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.KeyPair
import java.security.interfaces.ECPublicKey
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import local.islet.link.wire.Frames
import local.islet.link.wire.Link
import local.islet.link.wire.LinkCipher
import local.islet.link.wire.LinkCrypto
import local.islet.link.wire.Message

enum class Transport(val rank: Int, val label: String) {
    USB(0, "USB"), WIFI(1, "Wi-Fi"), BLUETOOTH(2, "Bluetooth")
}

/** A file waiting to go to the Mac: opened lazily, read chunk by chunk. */
class OutgoingFile(val name: String, val size: Long, val mime: String, val open: () -> InputStream) {
    val id: String = UUID.randomUUID().toString()
    @Volatile var sent = 0L
    internal var stream: InputStream? = null
    internal var begun = false
}

/** Where a file from the Mac is written while it arrives. */
interface IncomingSink {
    val output: OutputStream
    fun finish(ok: Boolean)
}

/**
 * One connection to the Mac over one byte stream (TCP or an L2CAP socket).
 *
 * Handshake (plain): both send `hello`. With a saved secret for that Mac the phone sends
 * `auth` and both switch to encryption; otherwise, when pairing, `pair.request` {pub},
 * the Mac answers `pair.key` {pub}, both show the code, and the Mac's sealed `pair.ok`
 * means it was accepted (`pair.no`: declined; `pair.needed`: the Mac forgot us).
 *
 * Writes go through one thread: control messages first, then file chunks, each sealed
 * as it goes out so the counter nonces stay in wire order.
 */
class Connection(
    val transport: Transport,
    input: InputStream,
    output: OutputStream,
    private val closeSocket: () -> Unit,
    private val identity: Identity,
    private val wantsPairing: Boolean,
    private val listener: Listener,
) {
    interface Listener {
        fun secretFor(macId: String): ByteArray?
        fun onPairingCode(connection: Connection, code: String) {}
        fun onPaired(connection: Connection, secret: ByteArray) {}
        fun onPairNeeded(connection: Connection) {}
        fun onPairDeclined(connection: Connection) {}
        fun onReady(connection: Connection)
        fun onMessage(connection: Connection, message: Message)
        fun openIncoming(connection: Connection, name: String, size: Long, mime: String): IncomingSink?
        fun onTransfer(connection: Connection, name: String, done: Long, total: Long, incoming: Boolean) {}
        fun onClosed(connection: Connection)
    }

    data class Identity(val id: String, val name: String, val model: String)

    enum class Phase { HELLO, PAIRING, READY, CLOSED }

    @Volatile var phase = Phase.HELLO
        private set
    @Volatile var macId = ""
        private set
    @Volatile var macName = "Mac"
        private set
    @Volatile var lastHeard = System.currentTimeMillis()
        private set

    private val input = DataInputStream(BufferedInputStream(input, 64 shl 10))
    private val output = BufferedOutputStream(output, 64 shl 10)
    private val writeLock = Object()
    private val closed = AtomicBoolean(false)
    private val phoneNonce = LinkCrypto.nonce()
    private var macNonce = ByteArray(0)
    @Volatile private var sealer: LinkCipher? = null
    @Volatile private var opener: LinkCipher? = null
    private var keyPair: KeyPair? = null
    private var pendingSecret: ByteArray? = null

    private val controls = ConcurrentLinkedQueue<Message>()
    private val files = ConcurrentLinkedQueue<OutgoingFile>()
    private val incoming = ConcurrentHashMap<String, Incoming>()
    private val signal = Object()

    private class Incoming(val name: String, val size: Long, val sink: IncomingSink) { var received = 0L }

    fun start() {
        // Hello goes out before anything is read, so it always precedes `auth` on the wire.
        writePlain(Message.of("hello", mapOf(
            "v" to Link.VERSION, "id" to identity.id, "name" to identity.name, "model" to identity.model,
            "kind" to "phone", "nonce" to Base64.getEncoder().encodeToString(phoneNonce),
        )))
        Thread({ readLoop() }, "link-read-$transport").start()
        Thread({ writeLoop() }, "link-write-$transport").start()
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        phase = Phase.CLOSED
        runCatching { closeSocket() }
        synchronized(signal) { signal.notifyAll() }
        incoming.values.forEach { it.sink.finish(false) }
        incoming.clear()
        files.forEach { runCatching { it.stream?.close() } }
        files.clear()
        listener.onClosed(this)
    }

    // MARK: Sending

    fun send(message: Message) {
        if (phase == Phase.CLOSED || sealer == null) return
        controls.add(message)
        synchronized(signal) { signal.notifyAll() }
    }

    fun send(file: OutgoingFile) {
        if (phase == Phase.CLOSED) return
        files.add(file)
        synchronized(signal) { signal.notifyAll() }
    }

    val busySending: Boolean get() = files.isNotEmpty()

    private fun writeLoop() {
        try {
            while (!closed.get()) {
                val message = controls.poll() ?: nextFileMessage()
                if (message == null) {
                    synchronized(signal) { if (controls.isEmpty() && files.isEmpty() && !closed.get()) signal.wait(1000) }
                    continue
                }
                val sealer = sealer ?: continue
                synchronized(writeLock) {
                    output.write(Frames.frame(sealer.seal(message.encoded())))
                    if (controls.isEmpty()) output.flush()
                }
            }
        } catch (error: Exception) {
            Log.i(TAG, "write ended: $error")
            close()
        }
    }

    private fun nextFileMessage(): Message? {
        val file = files.peek() ?: return null
        if (!file.begun) {
            file.begun = true
            return Message.of("file.begin", mapOf("id" to file.id, "name" to file.name, "size" to file.size, "mime" to file.mime))
        }
        val stream = file.stream ?: file.open().also { file.stream = it }
        val buffer = ByteArray(Link.CHUNK)
        var filled = 0
        while (filled < buffer.size) {
            val count = stream.read(buffer, filled, buffer.size - filled)
            if (count < 0) break
            filled += count
        }
        if (filled == 0) {
            files.poll()
            runCatching { stream.close() }
            listener.onTransfer(this, file.name, file.sent, file.size, false)
            return Message.of("file.end", mapOf("id" to file.id, "size" to file.sent))
        }
        file.sent += filled
        listener.onTransfer(this, file.name, file.sent, file.size, false)
        return Message.of("file.chunk", mapOf("id" to file.id), buffer.copyOf(filled))
    }

    private fun writePlain(message: Message) {
        try {
            synchronized(writeLock) {
                output.write(Frames.frame(message.encoded()))
                output.flush()
            }
        } catch (error: Exception) {
            close()
        }
    }

    // MARK: Receiving

    private fun readLoop() {
        try {
            while (!closed.get()) {
                val frame = Frames.read(input)
                lastHeard = System.currentTimeMillis()
                val opener = opener
                if (opener == null) {
                    Message.decode(frame)?.let { handshake(it) }
                    continue
                }
                val plain = runCatching { opener.open(frame) }.getOrNull()
                if (plain == null) {
                    // Before the Mac switched over, it may still answer in the clear.
                    val message = Message.decode(frame)
                    when (message?.type) {
                        "pair.needed" -> { listener.onPairNeeded(this); close() }
                        "pair.no" -> { listener.onPairDeclined(this); close() }
                        else -> { Log.w(TAG, "a frame failed to open"); close() }
                    }
                    return
                }
                val message = Message.decode(plain) ?: continue
                handle(message)
            }
        } catch (error: Exception) {
            Log.i(TAG, "read ended: $error")
        } finally {
            close()
        }
    }

    private fun handshake(message: Message) {
        val json = message.json
        when (message.type) {
            "hello" -> {
                macId = json.optString("id")
                macName = json.optString("name", "Mac")
                macNonce = Base64.getDecoder().decode(json.optString("nonce"))
                val secret = listener.secretFor(macId)
                if (secret != null && macNonce.size == 32) {
                    writePlain(Message.of("auth"))
                    startEncryption(secret)
                    becomeReady()
                } else if (wantsPairing) {
                    val pair = LinkCrypto.keyPair()
                    keyPair = pair
                    writePlain(Message.of("pair.request", mapOf(
                        "pub" to Base64.getEncoder().encodeToString(LinkCrypto.x963(pair.public as ECPublicKey)),
                    )))
                    phase = Phase.PAIRING
                } else {
                    // No secret for this Mac and not pairing: just not ours to talk to.
                    close()
                }
            }
            "pair.key" -> {
                val pair = keyPair ?: return close()
                val macKey = Base64.getDecoder().decode(json.optString("pub"))
                val ours = LinkCrypto.x963(pair.public as ECPublicKey)
                val shared = LinkCrypto.shared(pair, LinkCrypto.publicKey(macKey, pair.public as ECPublicKey))
                val pairing = LinkCrypto.pairing(shared, macKey, ours)
                pendingSecret = pairing.secret
                startEncryption(pairing.secret)
                listener.onPairingCode(this, pairing.code)
            }
            "pair.no" -> { listener.onPairDeclined(this); close() }
            "pair.needed" -> { listener.onPairNeeded(this); close() }
        }
    }

    private fun startEncryption(secret: ByteArray) {
        val (macToPhone, phoneToMac) = LinkCrypto.session(secret, macNonce, phoneNonce)
        opener = LinkCipher(macToPhone)
        sealer = LinkCipher(phoneToMac)
    }

    private fun becomeReady() {
        phase = Phase.READY
        listener.onReady(this)
    }

    private fun handle(message: Message) {
        val json = message.json
        when (message.type) {
            "pair.ok" -> {
                pendingSecret?.let { listener.onPaired(this, it) }
                pendingSecret = null
                becomeReady()
            }
            "ping" -> send(Message.of("pong"))
            "pong" -> Unit
            "file.begin" -> {
                val id = json.optString("id")
                val name = json.optString("name", "File")
                val size = json.optLong("size")
                val sink = listener.openIncoming(this, name, size, json.optString("mime", "application/octet-stream")) ?: return
                incoming[id] = Incoming(name, size, sink)
                listener.onTransfer(this, name, 0, size, true)
            }
            "file.chunk" -> {
                val file = incoming[json.optString("id")] ?: return
                file.sink.output.write(message.body)
                file.received += message.body.size
                listener.onTransfer(this, file.name, file.received, file.size, true)
            }
            "file.end" -> {
                val file = incoming.remove(json.optString("id")) ?: return
                // Every chunk was authenticated and in order, so a matching size is the whole file.
                file.sink.finish(file.received == file.size)
            }
            "file.cancel" -> {
                incoming.remove(json.optString("id"))?.sink?.finish(false)
                files.removeAll { it.id == json.optString("id") }
            }
            else -> listener.onMessage(this, message)
        }
    }

    companion object {
        private const val TAG = "IsletLink"
    }
}
