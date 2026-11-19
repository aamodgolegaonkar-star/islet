package local.islet.link.mirror

import android.app.ActivityOptions
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.createBitmap
import androidx.core.graphics.scale
import kotlin.concurrent.thread
import local.islet.link.link.LinkManager
import local.islet.link.ui.Button
import local.islet.link.ui.Islet
import local.islet.link.ui.IsletTheme
import local.islet.link.ui.pressable
import local.islet.link.wire.Message

/** Closes the mirrored phone's home screen with its display, so it never lands on the real screen. */
private fun finishWithDisplay(activity: ComponentActivity) {
    val own = activity.display?.displayId ?: return
    if (own == android.view.Display.DEFAULT_DISPLAY) { activity.finish(); return }
    val displays = activity.getSystemService(DisplayManager::class.java)
    val listener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) { if (displayId == own) activity.finish() }
    }
    displays.registerDisplayListener(listener, Handler(Looper.getMainLooper()))
    activity.lifecycle.addObserver(object : androidx.lifecycle.DefaultLifecycleObserver {
        override fun onDestroy(owner: androidx.lifecycle.LifecycleOwner) = displays.unregisterDisplayListener(listener)
    })
}

/**
 * The mirrored phone's home screen, on the mirror's own display: every app, a search field
 * (⌘3 on the Mac), and an app switcher of what's been opened this session (⌘2).
 */
class MirrorHome : ComponentActivity() {
    private data class App(val label: String, val pkg: String, val intent: Intent, val icon: Bitmap?)

    private var mode by mutableStateOf("home")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        finishWithDisplay(this)
        handle(intent)
        setContent {
            IsletTheme {
                var apps by remember { mutableStateOf<List<App>>(emptyList()) }
                remember { thread { apps = loadApps() } }
                Box(Modifier.fillMaxSize().background(Islet.background)) {
                    when (mode) {
                        "recents" -> Switcher(apps.filter { it.pkg in recents }.sortedBy { recents.indexOf(it.pkg) })
                        else -> Grid(apps, searching = mode == "search")
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent) {
        mode = intent.getStringExtra("mode") ?: "home"
        intent.getStringExtra("launch")?.let { pkg ->
            packageManager.getLaunchIntentForPackage(pkg)?.let { open(pkg, it) }
        }
    }

    @Composable
    private fun Grid(apps: List<App>, searching: Boolean) {
        var query by remember { mutableStateOf("") }
        val focus = remember { androidx.compose.ui.focus.FocusRequester() }
        LaunchedEffect(searching) { if (searching) runCatching { focus.requestFocus() } else query = "" }
        val shown = if (query.isBlank()) apps else apps.filter { it.label.contains(query.trim(), ignoreCase = true) }
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            androidx.compose.foundation.text.BasicTextField(
                query, { query = it },
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(color = Islet.text, fontSize = 17.sp),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(Islet.text),
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Go),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onGo = { shown.firstOrNull()?.let { open(it.pkg, it.intent) } }),
                modifier = Modifier.padding(start = 18.dp, end = 18.dp, top = 18.dp).fillMaxWidth()
                    .background(Islet.card, androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
                    .padding(horizontal = 16.dp, vertical = 12.dp).focusRequester(focus),
                decorationBox = { field ->
                    if (query.isEmpty()) Text("Search apps", color = Islet.tertiary, fontSize = 17.sp)
                    field()
                },
            )
            LazyVerticalGrid(
                GridCells.Fixed(4),
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = 14.dp, end = 14.dp, top = 22.dp, bottom = 40.dp),
                verticalArrangement = Arrangement.spacedBy(22.dp),
            ) {
                items(shown, key = { it.intent.component.toString() }) { app ->
                    Column(Modifier.pressable(0.92f) { open(app.pkg, app.intent) }, horizontalAlignment = Alignment.CenterHorizontally) {
                        AppImage(app, 56.dp)
                        Spacer(Modifier.height(6.dp))
                        Text(app.label, color = Islet.text, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                             textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                    }
                }
            }
        }
    }

    /** What was opened this session, newest first, as big cards. */
    @Composable
    private fun Switcher(apps: List<App>) {
        Column(Modifier.fillMaxSize().statusBarsPadding().padding(top = 28.dp)) {
            Text("Recent", style = Islet.title, modifier = Modifier.padding(start = 24.dp, bottom = 20.dp))
            if (apps.isEmpty()) {
                Text("Apps you open while mirroring appear here.", color = Islet.secondary, fontSize = 15.sp, modifier = Modifier.padding(horizontal = 24.dp))
            }
            androidx.compose.foundation.lazy.LazyRow(
                contentPadding = PaddingValues(horizontal = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                items(apps.size) { index ->
                    val app = apps[index]
                    Column(
                        Modifier.size(200.dp, 360.dp).background(Islet.card, androidx.compose.foundation.shape.RoundedCornerShape(28.dp))
                            .pressable(0.95f) { open(app.pkg, app.intent) }.padding(20.dp),
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                    ) {
                        AppImage(app, 88.dp)
                        Spacer(Modifier.height(16.dp))
                        Text(app.label, color = Islet.text, fontSize = 16.sp, maxLines = 2, textAlign = TextAlign.Center)
                    }
                }
            }
        }
    }

    @Composable
    private fun AppImage(app: App, size: androidx.compose.ui.unit.Dp) {
        val image = remember(app) { app.icon?.asImageBitmap() }
        if (image != null) Image(image, app.label, Modifier.size(size))
        else Box(Modifier.size(size).background(Islet.cardHigh, CircleShape))
    }

    private fun loadApps(): List<App> {
        val pm = packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(launcher, 0)
            .filter { it.activityInfo.packageName != packageName }
            .map { info: ResolveInfo ->
                val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    .setClassName(info.activityInfo.packageName, info.activityInfo.name)
                App(info.loadLabel(pm).toString(), info.activityInfo.packageName, intent, runCatching {
                    val drawable = info.loadIcon(pm)
                    (drawable as? BitmapDrawable)?.bitmap?.scale(144, 144) ?: createBitmap(144, 144).also {
                        drawable.setBounds(0, 0, 144, 144); drawable.draw(android.graphics.Canvas(it))
                    }
                }.getOrNull())
            }
            .sortedBy { it.label.lowercase() }
    }

    private fun open(pkg: String, intent: Intent) {
        val options = ActivityOptions.makeBasic().setLaunchDisplayId(display?.displayId ?: return)
        recents.remove(pkg)
        recents.add(0, pkg)
        val launch = Intent(intent).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        runCatching { startActivity(launch, options.toBundle()) }
        mode = "home"
    }

    companion object {
        /** Packages opened on the mirror, newest first; it lasts as long as the app's process. */
        private val recents = mutableListOf<String>()
    }
}

/**
 * What the real screen shows while the phone is mirrored, over the lock screen: the phone
 * can't be used until mirroring ends (here, on the Mac, or by unlocking it).
 */
class MirrorLockActivity : ComponentActivity() {
    private val unlocked = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = finish()
    }

    /** The server sends `done` when mirroring has ended. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra("done", false)) finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (Build.VERSION.SDK_INT >= 27) setShowWhenLocked(true)
        if (intent.getBooleanExtra("done", false)) { finish(); return }
        // Over USB, unplugging ends it, so this page must never be left behind. (Over Wi-Fi the
        // server closes it, and the charger has nothing to do with mirroring.)
        if (!intent.getBooleanExtra("wireless", false)) registerReceiver(unlocked, IntentFilter(Intent.ACTION_POWER_DISCONNECTED))
        val mac = intent.getStringExtra("mac") ?: LinkManager.get(this).pairedMacName
        // Stays on (plugged in), saying the phone is in use, but dimmed to almost nothing after a moment.
        Handler(Looper.getMainLooper()).postDelayed({
            window.attributes = window.attributes.apply { screenBrightness = 0.01f }
        }, 6_000)
        setContent {
            IsletTheme {
                Box(Modifier.fillMaxSize().background(Islet.background), contentAlignment = Alignment.Center) {
                    Column(Modifier.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(Modifier.size(96.dp).background(Islet.cardHigh, CircleShape), contentAlignment = Alignment.Center) {
                            Icon(Icons.Rounded.Laptop, null, tint = Islet.text, modifier = Modifier.size(48.dp))
                        }
                        Spacer(Modifier.height(28.dp))
                        Text("Phone in use", style = Islet.title)
                        Spacer(Modifier.height(8.dp))
                        Text("This phone is being used on $mac. Using it here ends mirroring.",
                             color = Islet.secondary, fontSize = 16.sp, textAlign = TextAlign.Center)
                        Spacer(Modifier.height(36.dp))
                        Button("Stop Mirroring", primary = false) { stop() }
                    }
                }
            }
        }
    }

    private fun stop() {
        // The server watches this file too, so mirroring ends even if the Mac can't be reached.
        runCatching { java.io.File(getExternalFilesDir(null), "mirror-stop").writeText(System.currentTimeMillis().toString()) }
        LinkManager.get(this).send(Message.of("mirror.stop"))
    }

    // Going home or to another app from here means using the phone, which ends mirroring.
    override fun onStop() {
        super.onStop()
        if (!isFinishing && !isChangingConfigurations) { stop(); finish() }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(unlocked) }
        super.onDestroy()
    }
}
