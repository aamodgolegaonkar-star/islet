package local.islet.link.mirror

import android.annotation.SuppressLint
import android.app.Application
import android.app.Instrumentation
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ApplicationInfo
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Build
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import kotlin.concurrent.thread
import kotlin.system.exitProcess

/**
 * Phone Mirroring, phone side. The Mac starts this over adb as the shell user:
 *
 *     CLASSPATH=<this APK> app_process / local.islet.link.mirror.Server
 *
 * Like iPhone Mirroring, the mirrored phone is a separate screen: a virtual display with
 * its own focus. Its picture is H.264 straight from the display's surface; taps and keys
 * from the Mac are injected into it. Meanwhile the real screen shows "Phone in use", then
 * powers off. Locking the phone would lock the mirrored screen too (Android covers it with
 * a credential prompt), so instead any use of the phone ends mirroring: the power button,
 * leaving that page, or Stop. Mirroring always ends with the phone locked.
 *
 * Wire (over `adb forward tcp:… localabstract:islet-mirror`, two connections):
 *  - video: status i32 (2 = hello; 0 = waiting for the phone to be unlocked, repeated; 1 = started),
 *    then width i32, height i32, then packets of pts i64, flags i32 (1 config, 2 key frame), size i32, bytes;
 *  - control: messages starting with a type byte (see [Control]).
 */
object Server {
    const val SOCKET = "islet-mirror"
    const val DISPLAY_NAME = "Islet Mirror"
    private const val TAG = "IsletMirror"

    // android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_* (public and @hide), as scrcpy uses them.
    private const val FLAG_PUBLIC = 1
    private const val FLAG_PRESENTATION = 1 shl 1
    private const val FLAG_OWN_CONTENT_ONLY = 1 shl 3
    private const val FLAG_SUPPORTS_TOUCH = 1 shl 6
    private const val FLAG_ROTATES_WITH_CONTENT = 1 shl 7
    private const val FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS = 1 shl 9
    private const val FLAG_TRUSTED = 1 shl 10
    private const val FLAG_OWN_DISPLAY_GROUP = 1 shl 11
    private const val FLAG_ALWAYS_UNLOCKED = 1 shl 12
    private const val FLAG_TOUCH_FEEDBACK_DISABLED = 1 shl 13
    private const val FLAG_OWN_FOCUS = 1 shl 14
    private const val FLAG_DEVICE_DISPLAY_GROUP = 1 shl 15

    @Volatile private var running = true
    private var display: VirtualDisplay? = null
    private var codec: MediaCodec? = null
    private var displayId = -1
    private lateinit var injector: Injector

    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper() // first: the shell context below needs it
        log("starting ${args.joinToString(" ")}")
        if (args.firstOrNull() == "probe") {
            for (name in listOf("android.hardware.display.DisplayManagerGlobal", "android.hardware.display.IDisplayManager", "android.view.IWindowManager")) {
                runCatching { Class.forName(name).methods.filter { m -> listOf("Power", "Decor", "Home", "Ime").any { it in m.name } }
                    .forEach { println("$name.${it.name}(${it.parameterTypes.joinToString { t -> t.simpleName }})") } }
            }
            return
        }
        // 0 means "the phone's own": its screen, with the height trimmed to what the encoder takes (a multiple of 16).
        val physical = Regex("""(\d+)x(\d+)""").find(Shell.output("wm", "size").orEmpty().lineSequence().first())?.destructured
        val width = args.getOrNull(0)?.toIntOrNull()?.takeIf { it > 0 } ?: physical?.component1()?.toInt() ?: 1080
        val height = args.getOrNull(1)?.toIntOrNull()?.takeIf { it > 0 } ?: physical?.component2()?.toInt()?.let { it / 16 * 16 } ?: 2336
        val dpi = args.getOrNull(2)?.toIntOrNull()?.takeIf { it > 0 }
            ?: Regex("""(\d+)""").find(Shell.output("wm", "density").orEmpty().lineSequence().first())?.value?.toInt() ?: 450
        val bitrate = args.getOrNull(3)?.toIntOrNull() ?: 12_000_000
        // A fresh socket name each session (from the Mac), so no other app can find the server and send it input.
        val socket = args.getOrNull(4)?.takeIf { it.startsWith("islet-mirror") } ?: SOCKET
        val macName = args.drop(5).joinToString(" ").ifBlank { "your Mac" }
        // A failure on any thread winds down cleanly (display removed, phone locked) instead of killing the process.
        Thread.setDefaultUncaughtExceptionHandler { t, error -> log("${t.name} failed: $error"); running = false; Control.interrupt() }
        System.setProperty("islet.mirror", "1")
        Shell.prepare()

        val server = LocalServerSocket(socket)
        var video: LocalSocket? = null
        var control: LocalSocket? = null
        try {
            video = server.accept()
            // Hello (status 2) at once: the Mac opens the input connection only once it hears the phone.
            video.outputStream.write(byteArrayOf(0, 0, 0, 2)); video.outputStream.flush()
            control = server.accept()
            injector = Injector()
            start(width, height, dpi, bitrate, DataOutputStream(video.outputStream.buffered(256 shl 10)), macName)
            val input = DataInputStream(control.inputStream.buffered())
            thread(name = "keyguard") { watchUnlock() }
            while (running) {
                if (!Control.read(input, injector, displayId)) break
            }
        } catch (error: Throwable) {
            log("ended: $error")
        } finally {
            running = false
            stop()
            runCatching { video?.close() }
            runCatching { control?.close() }
            runCatching { server.close() }
            log("stopped")
            exitProcess(0)
        }
    }

    fun requestStop() { running = false }

    private var stayOn: String? = null

    private fun start(width: Int, height: Int, dpi: Int, bitrate: Int, out: DataOutputStream, macName: String) {
        // A locked phone can't be mirrored (see above): wait for it to be unlocked.
        while (running && Shell.keyguardLocked() == true) {
            out.writeInt(0); out.flush()
            SystemClock.sleep(500)
        }
        out.writeInt(1)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 10)
            // A still screen still sends frames, so the Mac never waits on a stale picture.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()
        this.codec = codec

        var flags = FLAG_PUBLIC or FLAG_PRESENTATION or FLAG_OWN_CONTENT_ONLY or FLAG_SUPPORTS_TOUCH or FLAG_ROTATES_WITH_CONTENT
        if (System.getenv("ISLET_DECOR") == "1") flags = flags or FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS
        if (Build.VERSION.SDK_INT >= 33) flags = flags or FLAG_TRUSTED or FLAG_OWN_DISPLAY_GROUP or FLAG_ALWAYS_UNLOCKED or FLAG_TOUCH_FEEDBACK_DISABLED
        if (Build.VERSION.SDK_INT >= 34) flags = flags or FLAG_OWN_FOCUS or FLAG_DEVICE_DISPLAY_GROUP
        display = Shell.createDisplay(DISPLAY_NAME, width, height, dpi, surface, flags)
        displayId = display!!.display.displayId
        injector.size(width, height)
        Shell.hideKeyboard(displayId)
        log("display $displayId ${width}x$height@$dpi")

        out.writeInt(width)
        out.writeInt(height)
        out.flush()
        thread(name = "encode") { encode(codec, out) }

        // Plugged in over USB, the phone stays awake for the session (restored at the end), so it
        // never times out into the lock screen; its own screen just goes dark.
        stayOn = Shell.output("settings", "get", "global", "stay_on_while_plugged_in")
        Shell.run("settings", "put", "global", "stay_on_while_plugged_in", "7")
        // The mirrored phone opens on its own home screen; the real one shows that it's in use.
        Shell.run("am", "start", "--display", "$displayId", "-n", "local.islet.link/.mirror.MirrorHome")
        Shell.run("am", "start", "--display", "0", "-n", "local.islet.link/.mirror.MirrorLockActivity", "--es", "mac", macName)

    }

    private fun encode(codec: MediaCodec, out: DataOutputStream) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val index = codec.dequeueOutputBuffer(info, 100_000)
                if (index < 0) continue
                val buffer = codec.getOutputBuffer(index)!!
                var flags = 0
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) flags = flags or 1
                if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) flags = flags or 2
                val bytes = ByteArray(info.size)
                buffer.position(info.offset)
                buffer.get(bytes)
                codec.releaseOutputBuffer(index, false)
                out.writeLong(info.presentationTimeUs)
                out.writeInt(flags)
                out.writeInt(bytes.size)
                out.write(bytes)
                out.flush()
            }
        } catch (error: Throwable) {
            log("video ended: $error")
        } finally {
            running = false
            // Unblock the control reader so the whole server winds down.
            Control.interrupt()
        }
    }

    /**
     * Using the phone ends mirroring: the power button (the lock screen would lock the mirror
     * anyway), or leaving the "Phone in use" page, which writes [STOP_FILE] even when the Mac
     * can't be reached.
     */
    private fun watchUnlock() {
        val started = System.currentTimeMillis()
        val stopFile = java.io.File(STOP_FILE)
        while (running) {
            SystemClock.sleep(400)
            if (Shell.keyguardLocked() == true) { log("phone locked"); running = false; Control.interrupt() }
            if (stopFile.exists() && stopFile.lastModified() >= started) { log("phone used"); running = false; Control.interrupt() }
        }
    }

    /** In the app's own external files, which the shell can read. */
    const val STOP_FILE = "/sdcard/Android/data/local.islet.link/files/mirror-stop"

    private fun stop() {
        Control.done()
        Thread.interrupted() // a stop can arrive as an interrupt; don't let it cancel the clean-up commands
        runCatching { display?.release() }
        display = null
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        codec = null
        stayOn?.let { Shell.run("settings", "put", "global", "stay_on_while_plugged_in", it.ifBlank { "0" }) }
        Shell.run("am", "start", "--display", "0", "-n", "local.islet.link/.mirror.MirrorLockActivity", "--ez", "done", "true")
        // Mirroring ends with the phone locked.
        Shell.displayPower(0, true)
        if (::injector.isInitialized && Shell.keyguardLocked() != true) runCatching { injector.key(KeyEvent.KEYCODE_SLEEP, 0) }
    }

    fun log(message: String) = android.util.Log.i(TAG, message)
}

/** Messages from the Mac. */
object Control {
    const val TOUCH = 1
    const val SCROLL = 2
    const val KEY = 3
    const val TEXT = 4
    const val HOME = 5
    const val BACK = 6
    const val STOP = 7

    @Volatile private var reader: Thread? = null

    fun interrupt() { reader?.interrupt(); Server.requestStop() }

    /** Clean-up has begun: later interrupts must not cut its commands short. */
    fun done() { reader = null }

    fun read(input: DataInputStream, injector: Injector, display: Int): Boolean {
        reader = Thread.currentThread()
        val type = try { input.readUnsignedByte() } catch (error: IOException) { return false }
        when (type) {
            TOUCH -> { val action = input.readUnsignedByte(); injector.touch(action, input.readFloat(), input.readFloat(), display) }
            SCROLL -> injector.scroll(input.readFloat(), input.readFloat(), input.readFloat(), input.readFloat(), display)
            KEY -> { val action = input.readUnsignedByte(); injector.keyEvent(action, input.readInt(), input.readInt(), display) }
            TEXT -> { val bytes = ByteArray(input.readUnsignedShort()); input.readFully(bytes); injector.text(String(bytes), display) }
            HOME -> Shell.run("am", "start", "--display", "$display", "-n", "local.islet.link/.mirror.MirrorHome")
            BACK -> injector.key(KeyEvent.KEYCODE_BACK, display)
            STOP -> return false
            else -> return false
        }
        return true
    }
}

/** Taps, scrolls and keys into the mirrored display, through the shell's INJECT_EVENTS. */
class Injector {
    private val manager: Any = Shell.context.getSystemService(Context.INPUT_SERVICE)!!
    private val inject = manager.javaClass.getMethod("injectInputEvent", InputEvent::class.java, Int::class.javaPrimitiveType)
    private val setDisplay = InputEvent::class.java.getMethod("setDisplayId", Int::class.javaPrimitiveType)
    private var width = 1f
    private var height = 1f
    private var downTime = 0L
    private val properties = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
    private val coords = arrayOf(MotionEvent.PointerCoords().apply { pressure = 1f; size = 1f })

    fun size(w: Int, h: Int) { width = w.toFloat(); height = h.toFloat() }

    private fun send(event: InputEvent, display: Int) {
        setDisplay.invoke(event, display)
        inject.invoke(manager, event, 0) // INJECT_INPUT_EVENT_MODE_ASYNC
    }

    fun touch(action: Int, x: Float, y: Float, display: Int) {
        val now = SystemClock.uptimeMillis()
        val motion = when (action) { 0 -> { downTime = now; MotionEvent.ACTION_DOWN }; 1 -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_MOVE }
        coords[0].x = x * width
        coords[0].y = y * height
        val event = MotionEvent.obtain(downTime, now, motion, 1, properties, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
        send(event, display)
        event.recycle()
    }

    fun scroll(x: Float, y: Float, h: Float, v: Float, display: Int) {
        val now = SystemClock.uptimeMillis()
        val point = MotionEvent.PointerCoords().apply {
            this.x = x * width; this.y = y * height
            setAxisValue(MotionEvent.AXIS_HSCROLL, h)
            setAxisValue(MotionEvent.AXIS_VSCROLL, v)
        }
        val props = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_MOUSE })
        val event = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1, props, arrayOf(point), 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0)
        send(event, display)
        event.recycle()
    }

    fun keyEvent(action: Int, code: Int, meta: Int, display: Int) {
        val now = SystemClock.uptimeMillis()
        send(KeyEvent(now, now, if (action == 0) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP, code, 0, meta,
                      KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD), display)
    }

    fun key(code: Int, display: Int) {
        keyEvent(0, code, 0, display)
        keyEvent(1, code, 0, display)
    }

    /** shortcut: characters the virtual keyboard map can't type (emoji, most non-Latin) are skipped. */
    fun text(text: String, display: Int) {
        val map = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
        for (char in text) {
            map.getEvents(charArrayOf(char))?.forEach { send(it, display) }
        }
    }
}

/**
 * Being "the shell" from app_process: a system context that says it is com.android.shell,
 * so framework services accept the shell's permissions. After scrcpy's FakeContext.
 */
@SuppressLint("PrivateApi", "DiscouragedPrivateApi", "BlockedPrivateApi", "SoonBlockedPrivateApi")
object Shell {
    private const val PACKAGE = "com.android.shell"
    private val activityThreadClass = Class.forName("android.app.ActivityThread")
    private val activityThread: Any = activityThreadClass.getDeclaredConstructor().apply { isAccessible = true }.newInstance().also { thread ->
        activityThreadClass.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, thread)
        activityThreadClass.getDeclaredField("mSystemThread").apply { isAccessible = true }.setBoolean(thread, true)
    }

    lateinit var context: Context
        private set

    fun prepare() {
        // Some Samsung builds read the configuration through this while creating displays.
        runCatching {
            val controller = Class.forName("android.app.ConfigurationController")
            val internal = Class.forName("android.app.ActivityThreadInternal")
            val instance = controller.getDeclaredConstructor(internal).apply { isAccessible = true }.newInstance(activityThread)
            activityThreadClass.getDeclaredField("mConfigurationController").apply { isAccessible = true }.set(activityThread, instance)
        }
        runCatching {
            val bindData = Class.forName("android.app.ActivityThread\$AppBindData")
            val data = bindData.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
            bindData.getDeclaredField("appInfo").apply { isAccessible = true }.set(data, ApplicationInfo().apply { packageName = PACKAGE })
            activityThreadClass.getDeclaredField("mBoundApplication").apply { isAccessible = true }.set(activityThread, data)
        }
        val system = activityThreadClass.getDeclaredMethod("getSystemContext").invoke(activityThread) as Context
        context = ShellContext(system)
        runCatching {
            val app = Instrumentation.newApplication(Application::class.java, context)
            activityThreadClass.getDeclaredField("mInitialApplication").apply { isAccessible = true }.set(activityThread, app)
        }
    }

    fun createDisplay(name: String, width: Int, height: Int, dpi: Int, surface: Surface, flags: Int): VirtualDisplay {
        val constructor = android.hardware.display.DisplayManager::class.java.getDeclaredConstructor(Context::class.java)
        constructor.isAccessible = true
        return constructor.newInstance(context).createVirtualDisplay(name, width, height, dpi, surface, flags)
    }

    /** IWindowManager.isKeyguardLocked(), straight from the service (KeyguardManager can't be made here). */
    fun keyguardLocked(): Boolean? = runCatching {
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, "window")
        val wm = Class.forName("android.view.IWindowManager\$Stub").getMethod("asInterface", android.os.IBinder::class.java).invoke(null, binder)!!
        wm.javaClass.getMethod("isKeyguardLocked").invoke(wm) as Boolean
    }.getOrNull()

    /** Turns a physical display's panel on or off without sleeping the phone (Android 15+). */
    fun displayPower(id: Int, on: Boolean) {
        if (Build.VERSION.SDK_INT < 35) return
        runCatching {
            val global = Class.forName("android.hardware.display.DisplayManagerGlobal")
            val instance = global.getDeclaredMethod("getInstance").invoke(null)
            // Android 17 takes a Display.STATE_* (1 off, 2 on); 15 and 16 took a boolean.
            runCatching { global.getMethod("requestDisplayPower", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).invoke(instance, id, if (on) 2 else 1) }
                .getOrElse { global.getMethod("requestDisplayPower", Int::class.javaPrimitiveType, Boolean::class.javaPrimitiveType).invoke(instance, id, on) }
        }.onFailure { Server.log("display power: $it") }
    }

    /** You type with the Mac's keyboard, so the phone's own keyboard stays hidden on the mirror (WindowManager.DISPLAY_IME_POLICY_HIDE). */
    fun hideKeyboard(display: Int) = runCatching {
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, "window")
        val wm = Class.forName("android.view.IWindowManager\$Stub").getMethod("asInterface", android.os.IBinder::class.java).invoke(null, binder)!!
        wm.javaClass.getMethod("setDisplayImePolicy", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).invoke(wm, display, 2)
    }.onFailure { Server.log("keyboard policy: $it") }

    fun output(vararg command: String): String? = runCatching {
        val process = ProcessBuilder(*command).redirectErrorStream(true).start()
        process.inputStream.bufferedReader().readText().trim().also { process.waitFor() }
    }.getOrNull()?.takeIf { it != "null" }

    fun run(vararg command: String) {
        runCatching { ProcessBuilder(*command).redirectErrorStream(true).start().waitFor() }
            .onFailure { Server.log("${command.joinToString(" ")} failed: $it") }
    }

    private class ShellContext(base: Context) : ContextWrapper(base) {
        override fun getPackageName() = PACKAGE
        override fun getOpPackageName() = PACKAGE
        override fun getAttributionSource(): AttributionSource =
            AttributionSource.Builder(Process.SHELL_UID).setPackageName(PACKAGE).build()
        override fun getApplicationContext(): Context = this
    }
}
