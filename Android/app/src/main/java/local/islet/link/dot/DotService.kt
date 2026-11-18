package local.islet.link.dot

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.FrameLayout
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The Dynamic Dot: a black shape around the front camera that grows into what's
 * happening. It lives in an accessibility overlay because that is the only window an app
 * may draw above the status bar; it reads no screen content, only which app is in front.
 */
class DotService : AccessibilityService(), LifecycleOwner, SavedStateRegistryOwner {
    /** The camera and screen, in pixels. */
    data class Geometry(val screenWidth: Int, val holeX: Int, val holeTop: Int, val holeSize: Int, val density: Float, val landscape: Boolean)

    data class Charge(val level: Int, val stamp: Long = System.nanoTime())

    val geometry = MutableStateFlow<Geometry?>(null)
    val foreground = MutableStateFlow<String?>(null)
    val screenOn = MutableStateFlow(true)
    val charge = MutableStateFlow<Charge?>(null)
    val outside = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    private val registry = LifecycleRegistry(this)
    private val savedState = SavedStateRegistryController.create(this)
    override val lifecycle: Lifecycle get() = registry
    override val savedStateRegistry: SavedStateRegistry get() = savedState.savedStateRegistry

    private var root: FrameLayout? = null
    private var touchRoot: FrameLayout? = null
    private var compose: ComposeView? = null

    private fun layout(title: String) = WindowManager.LayoutParams(
        1, 1, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= 30) WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            else WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        this.title = title
    }

    /** Where the dot draws: pinned to the top-left and never moved, so nothing can jump mid-animation. */
    private val drawParams = layout("Islet Dynamic Dot")
    /** Where the dot is touched: invisible, so it can be resized to the dot instantly. */
    private val touchParams = layout("Islet Dynamic Dot touch").apply {
        flags = flags or WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    screenOn.value = false
                    // The lock screen is System UI, which is filtered out; it isn't the app that was open.
                    foreground.value = null
                }
                Intent.ACTION_SCREEN_ON -> screenOn.value = true
                Intent.ACTION_POWER_CONNECTED -> if (DotFeed.on(context, "charging")) {
                    val level = getSystemService(BatteryManager::class.java).getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                    charge.value = Charge(level)
                }
                Intent.ACTION_POWER_DISCONNECTED -> charge.value = null
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        savedState.performRestore(null)
        registry.currentState = Lifecycle.State.CREATED
    }

    override fun onServiceConnected() {
        instance = this
        screenOn.value = getSystemService(PowerManager::class.java).isInteractive
        measure()
        registerReceiver(receiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_POWER_CONNECTED); addAction(Intent.ACTION_POWER_DISCONNECTED)
        })
        val wm = getSystemService(WindowManager::class.java)
        val compose = ComposeView(this).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
            setContent { DynamicDot(this@DotService) }
        }
        val frame = FrameLayout(this)
        frame.addView(compose)
        frame.setViewTreeLifecycleOwner(this)
        frame.setViewTreeSavedStateRegistryOwner(this)
        val touch = FrameLayout(this)
        touch.setOnTouchListener { _, event ->
            // A touch anywhere else on screen closes an open dot, like on iPhone.
            if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) { outside.tryEmit(Unit); return@setOnTouchListener false }
            val moved = MotionEvent.obtain(event)
            moved.offsetLocation(touchParams.x.toFloat() - drawParams.x, touchParams.y.toFloat() - drawParams.y)
            compose.dispatchTouchEvent(moved)
            moved.recycle()
            true
        }
        runCatching { wm.addView(frame, drawParams) }.onSuccess { root = frame; this.compose = compose }
        runCatching { wm.addView(touch, touchParams) }.onSuccess { touchRoot = touch }
        registry.currentState = Lifecycle.State.RESUMED
        DotFeed.seed(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        val cls = event.className?.toString() ?: return
        // Only real app screens count: the shade, keyboards and Samsung's fingerprint and Pay
        // overlays come and go over an app without it leaving.
        if (pkg == "com.android.systemui" || !isActivity(pkg, cls)) return
        foreground.value = pkg
    }

    private val activities = HashMap<String, Boolean>()

    private fun isActivity(pkg: String, cls: String): Boolean = activities.getOrPut("$pkg/$cls") {
        runCatching { packageManager.getActivityInfo(ComponentName(pkg, cls), 0) }.isSuccess
    }

    override fun onInterrupt() {}

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        measure()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        tearDown()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        tearDown()
        registry.currentState = Lifecycle.State.DESTROYED
        super.onDestroy()
    }

    private fun tearDown() {
        if (instance === this) instance = null
        root?.let { runCatching { getSystemService(WindowManager::class.java).removeView(it) } }
        touchRoot?.let { runCatching { getSystemService(WindowManager::class.java).removeView(it) } }
        root = null
        touchRoot = null
        runCatching { unregisterReceiver(receiver) }
        DotFeed.media.value = null
        DotFeed.alert.value = null
        DotFeed.call.value = null
    }

    private fun measure() {
        val wm = getSystemService(WindowManager::class.java)
        val bounds: Rect
        val cutout = if (Build.VERSION.SDK_INT >= 30) {
            val metrics = wm.currentWindowMetrics
            bounds = metrics.bounds
            metrics.windowInsets.displayCutout
        } else {
            val dm = resources.displayMetrics
            bounds = Rect(0, 0, dm.widthPixels, dm.heightPixels)
            @Suppress("DEPRECATION") wm.defaultDisplay.cutout
        }
        val density = resources.displayMetrics.density
        val hole = cutout?.boundingRectTop?.takeIf { !it.isEmpty }
        geometry.value = Geometry(
            screenWidth = bounds.width(),
            holeX = hole?.centerX() ?: (bounds.width() / 2),
            holeTop = hole?.top ?: (10 * density).toInt(),
            holeSize = hole?.let { minOf(it.width(), it.height()) } ?: (12 * density).toInt(),
            density = density,
            landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE,
        )
    }

    private var canvasHeight = -1
    private var touchArea = Rect()
    private var touchable = false

    /** The drawing window is the screen's width and [height] tall; resized only while nothing shows. */
    fun canvas(height: Int) {
        val view = root ?: return
        val width = geometry.value?.screenWidth ?: return
        if (height == canvasHeight && drawParams.width == width) return
        canvasHeight = height
        drawParams.x = 0; drawParams.y = 0
        drawParams.width = width; drawParams.height = height.coerceAtLeast(1)
        runCatching { getSystemService(WindowManager::class.java).updateViewLayout(view, drawParams) }
    }

    /** Only the dot itself takes touches, so the rest of the status bar and the app below keep working. */
    fun touch(area: Rect, canTouch: Boolean) {
        val view = touchRoot ?: return
        if (area == touchArea && canTouch == touchable) return
        touchArea = Rect(area)
        touchable = canTouch
        touchParams.x = area.left; touchParams.y = area.top
        touchParams.width = area.width().coerceAtLeast(1); touchParams.height = area.height().coerceAtLeast(1)
        touchParams.flags = if (canTouch) touchParams.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            else touchParams.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        runCatching { getSystemService(WindowManager::class.java).updateViewLayout(view, touchParams) }
    }

    companion object {
        @Volatile var instance: DotService? = null
            private set

        fun enabled(context: Context): Boolean =
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
                ?.split(':')?.any { ComponentName.unflattenFromString(it) == ComponentName(context, DotService::class.java) } == true

        /** Straight to the dot's switch where Android allows it, else the accessibility list. */
        fun openSettings(context: Context) {
            val component = ComponentName(context, DotService::class.java).flattenToString()
            val details = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
                .putExtra(Intent.EXTRA_COMPONENT_NAME, component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching { context.startActivity(details) }.onFailure {
                runCatching { context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            }
        }
    }
}
