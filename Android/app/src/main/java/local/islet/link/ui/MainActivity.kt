package local.islet.link.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForwardIos
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Usb
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import local.islet.link.features.FindPhone
import local.islet.link.features.NotificationMirror
import local.islet.link.link.FoundMac
import local.islet.link.link.LinkManager
import local.islet.link.link.LinkService
import local.islet.link.link.LinkState

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        LinkService.channels(this)
        LinkService.start(this)
        setContent { IsletTheme { App() } }
    }

    override fun onResume() {
        super.onResume()
        // Found it: opening Islet stops Find My Phone.
        if (FindPhone.ringing) FindPhone.stop(this)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // Presenting: the volume buttons change slides.
        if (slidesMode && (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP)) {
            LinkManager.get(this).input("key", "key" to if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) "right" else "left",
                                        "mods" to emptyList<String>())
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    companion object {
        @Volatile var slidesMode = false
    }
}

@Composable
fun App() {
    val context = LocalContext.current
    val link = remember { LinkManager.get(context) }
    val state by link.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(Unit) { link.notes.collect { snackbar.showSnackbar(it) } }

    Box(Modifier.fillMaxSize().background(Islet.background)) {
        AnimatedContent(
            targetState = state is LinkState.Unpaired || state is LinkState.Pairing,
            transitionSpec = { fadeIn(tween(420, easing = Motion.easeOutExpo)) togetherWith fadeOut(tween(200)) },
            label = "root",
        ) { pairing ->
            if (pairing) PairScreen(link, state) else Home(link)
        }
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 96.dp))
    }
}

// MARK: Pairing

@Composable
fun PairScreen(link: LinkManager, state: LinkState) {
    val found by link.found.collectAsStateWithLifecycle()
    DisposableEffect(Unit) {
        link.startDiscovery()
        onDispose { if (link.pairedMacId == null) link.stopDiscovery() }
    }
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal = 24.dp)) {
        Spacer(Modifier.height(56.dp))
        IslandHero(Modifier.align(Alignment.CenterHorizontally).entrance(0))
        Spacer(Modifier.height(40.dp))
        Text("Islet", style = Islet.title.copy(fontSize = 44.sp, lineHeight = 48.sp), modifier = Modifier.entrance(1))
        Text("Your phone and your Mac, together. Notifications, music, files and a remote, all private and local.",
             style = Islet.body.copy(color = Islet.secondary), modifier = Modifier.padding(top = 8.dp).entrance(2))
        Spacer(Modifier.height(36.dp))
        AnimatedContent(state, transitionSpec = { fadeIn(tween(320)) togetherWith fadeOut(tween(160)) }, label = "pair") { current ->
            when {
                current is LinkState.Pairing && current.code != null -> CodeCard(current.macName, current.code) { link.cancelPairing() }
                current is LinkState.Pairing -> Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = Islet.text, strokeWidth = 1.5.dp)
                    Spacer(Modifier.width(14.dp))
                    Text("Connecting to ${current.macName}", style = Islet.body.copy(color = Islet.secondary))
                }
                else -> MacList(found, onPair = { link.pair(it) }, onUsb = { link.pairOverUsb() })
            }
        }
    }
}

@Composable
private fun MacList(found: List<FoundMac>, onPair: (FoundMac) -> Unit, onUsb: () -> Unit) {
    Column(Modifier.fillMaxWidth().entrance(3)) {
        Text("MACS ON THIS WI-FI", style = Islet.label, modifier = Modifier.padding(start = 4.dp, bottom = 12.dp))
        Card(Modifier.fillMaxWidth(), padding = 0.dp) {
            if (found.isEmpty()) {
                Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(16.dp), color = Islet.secondary, strokeWidth = 1.5.dp)
                    Spacer(Modifier.width(14.dp))
                    Column {
                        Text("Looking…", style = Islet.body)
                        Text("Open Islet on your Mac: Settings → Android Phone.", style = Islet.caption)
                    }
                }
            }
            found.forEachIndexed { index, mac ->
                if (index > 0) HorizontalDivider(color = Islet.stroke, modifier = Modifier.padding(start = 64.dp))
                Row(Modifier.fillMaxWidth().pressable(0.98f) { onPair(mac) }.padding(horizontal = 20.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Laptop, null, tint = Islet.text, modifier = Modifier.size(26.dp))
                    Spacer(Modifier.width(18.dp))
                    Column(Modifier.weight(1f)) {
                        Text(mac.name, style = Islet.body.copy(fontWeight = FontWeight.Medium))
                        Text("Tap to pair", style = Islet.caption)
                    }
                    Icon(Icons.AutoMirrored.Rounded.ArrowForwardIos, null, tint = Islet.tertiary, modifier = Modifier.size(14.dp))
                }
            }
        }
        Spacer(Modifier.height(14.dp))
        Button("Pair over USB", Modifier.fillMaxWidth(), icon = Icons.Rounded.Usb, primary = false, onClick = onUsb)
        Text("Needs USB debugging on the phone.", style = Islet.caption.copy(color = Islet.tertiary),
             textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(top = 10.dp))
    }
}

/** The pairing code: six digits, each in its own key, arriving one after another. */
@Composable
private fun CodeCard(macName: String, code: String, cancel: () -> Unit) {
    val view = LocalView.current
    LaunchedEffect(code) { Haptic.edge(view) }
    Column(Modifier.fillMaxWidth()) {
        Text("PAIRING WITH ${macName.uppercase()}", style = Islet.label, modifier = Modifier.padding(start = 4.dp, bottom = 14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            code.forEachIndexed { index, digit ->
                if (index == 3) Spacer(Modifier.width(6.dp))
                Box(
                    Modifier.weight(1f).height(64.dp).entrance(index).clip(RoundedCornerShape(14.dp))
                        .background(Islet.card).border(1.dp, Islet.stroke, RoundedCornerShape(14.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(digit.toString(), fontFamily = Islet.mono, fontSize = 30.sp, color = Islet.text)
                }
            }
        }
        Text("If your Mac shows the same code, click Pair in its island.",
             style = Islet.body.copy(color = Islet.secondary), modifier = Modifier.padding(top = 18.dp))
        Spacer(Modifier.height(22.dp))
        Button("Cancel", primary = false, onClick = cancel)
    }
}

/**
 * The island, opening once: a dot that widens into the pill (pairing happens rarely, so
 * it can afford a moment). A still, faint light sits behind it; nothing loops.
 */
@Composable
fun IslandHero(modifier: Modifier = Modifier) {
    val reduced = LocalReducedMotion.current
    val open = remember { Animatable(if (reduced) 1f else 0f) }
    LaunchedEffect(Unit) { if (!reduced) open.animateTo(1f, androidx.compose.animation.core.spring(dampingRatio = 0.7f, stiffness = 140f)) }
    Box(modifier.size(280.dp, 140.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            drawRect(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.07f), Color.Transparent),
                                          Offset(size.width / 2, size.height / 2), size.height / 2))
        }
        Box(
            Modifier.size(200.dp, 56.dp)
                .graphicsLayer { scaleX = 0.28f + 0.72f * open.value; scaleY = 0.85f + 0.15f * open.value }
                .clip(CircleShape).background(Color.Black)
                .border(1.dp, Islet.stroke, CircleShape),
            contentAlignment = Alignment.CenterEnd,
        ) {
            Box(Modifier.padding(end = 22.dp).size(9.dp).graphicsLayer { alpha = open.value }.clip(CircleShape).background(Islet.green))
        }
    }
}

// MARK: Home

private enum class Tab(val label: String, val icon: ImageVector) {
    Mac("Mac", Icons.Rounded.Laptop), Remote("Remote", Icons.Rounded.Mouse),
    Files("Files", Icons.Rounded.Folder), Settings("Settings", Icons.Rounded.Settings)
}

@Composable
fun Home(link: LinkManager) {
    var tab by rememberSaveable { mutableStateOf(Tab.Mac) }
    Box(Modifier.fillMaxSize()) {
        // Switching tabs happens all day: a quick cross-fade, no travel.
        AnimatedContent(tab, transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(120)) }, label = "tab") { current ->
            when (current) {
                Tab.Mac -> MacScreen(link)
                Tab.Remote -> RemoteScreen(link)
                Tab.Files -> FilesScreen(link)
                Tab.Settings -> SettingsScreen(link)
            }
        }
        // A fade under the bar so content slips beneath the glass.
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(120.dp)
            .background(Brush.verticalGradient(listOf(Color.Transparent, Islet.background.copy(alpha = 0.92f)))))
        LiquidSelector(
            items = Tab.entries,
            selected = tab.ordinal,
            onSelect = { tab = Tab.entries[it] },
            modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding()
                .padding(start = 22.dp, end = 22.dp, bottom = 10.dp).fillMaxWidth(),
            height = 66.dp,
        ) { item, highlight ->
            val tint = lerp(Islet.tertiary, Islet.text, highlight)
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(item.icon, item.label, tint = tint, modifier = Modifier.size(23.dp))
                Spacer(Modifier.height(3.dp))
                Text(item.label, color = tint, fontSize = 10.5.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

// MARK: Permissions

/** One thing the app needs, with how to grant it. */
data class Need(val title: String, val detail: String, val granted: Boolean, val fix: () -> Unit)

/** Re-reads permissions whenever the app comes back to the front. */
@Composable
fun rememberNeeds(): List<Need> {
    val context = LocalContext.current
    var refresh by remember { mutableIntStateOf(0) }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) refresh++ }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    val runtime = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh++ }
    @Suppress("UNUSED_EXPRESSION") refresh
    fun has(permission: String) = ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    val needs = mutableListOf(
        Need("Notification access", "Your notifications, calls and music on the Mac. If Android says it's restricted: App info → ⋮ → Allow restricted settings.",
             NotificationMirror.allowed(context)) { openListenerSettings(context) },
    )
    if (Build.VERSION.SDK_INT >= 33) {
        needs += Need("Notifications", "Your Mac's music, files and Find My Phone", has(Manifest.permission.POST_NOTIFICATIONS)) {
            runtime.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
        }
    }
    if (Build.VERSION.SDK_INT >= 31) {
        needs += Need("Nearby devices", "Connect over Bluetooth when there's no Wi-Fi",
                      has(Manifest.permission.BLUETOOTH_SCAN) && has(Manifest.permission.BLUETOOTH_CONNECT)) {
            runtime.launch(arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT))
        }
    }
    needs += Need("Photo locations", "Photos you send keep where they were taken", has(Manifest.permission.ACCESS_MEDIA_LOCATION)) {
        runtime.launch(arrayOf(Manifest.permission.ACCESS_MEDIA_LOCATION))
    }
    val power = context.getSystemService(PowerManager::class.java)
    needs += Need("Stay connected", "Let Islet run in the background so it doesn't drop the link",
                  power.isIgnoringBatteryOptimizations(context.packageName)) {
        @Suppress("BatteryLife")
        context.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")))
    }
    return needs
}

fun openListenerSettings(context: Context) {
    val component = ComponentName(context, NotificationMirror::class.java)
    val intent = if (Build.VERSION.SDK_INT >= 30) {
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
            .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, component.flattenToString())
    } else {
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
    }
    runCatching { context.startActivity(intent) }.onFailure {
        context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    }
}
