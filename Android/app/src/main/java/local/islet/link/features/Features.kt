package local.islet.link.features

import android.app.ActivityOptions
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.VibratorManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Patterns
import androidx.core.content.ContextCompat
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap
import local.islet.link.R
import local.islet.link.dot.DotFeed
import local.islet.link.link.IncomingSink
import local.islet.link.link.LinkManager
import local.islet.link.link.LinkService
import local.islet.link.link.OutgoingFile
import local.islet.link.ui.FindActivity
import local.islet.link.wire.Message

/** Everything the phone shares with the Mac, besides the connection itself. */
object Features {
    fun prefs(context: Context): SharedPreferences = context.getSharedPreferences("features", Context.MODE_PRIVATE)

    /** Sent each time a link comes up: status, what's playing, recent notifications. */
    fun onConnected(context: Context, link: LinkManager) {
        sentIcons.clear()
        link.send(status(context))
        PhoneMedia.resend(context)
        NotificationMirror.instance?.let { mirror ->
            runCatching { mirror.activeNotifications }.getOrNull()
                ?.sortedBy { it.postTime }?.takeLast(10)
                ?.forEach { posted(context, it, quiet = true) }
        }
    }

    fun handle(context: Context, link: LinkManager, message: Message) {
        val json = message.json
        when (message.type) {
            "notif.act" -> act(context, json.optString("key"), json.optInt("i"), json.optString("reply").takeIf { json.has("reply") })
            "notif.dismiss" -> runCatching { NotificationMirror.instance?.cancelNotification(json.optString("key")) }
            "media.cmd" -> PhoneMedia.command(json.optString("action"), json.optDouble("value", 0.0))
            "clip" -> if (prefs(context).getBoolean("clipboard", true)) setClipboard(context, json.optString("text"))
            "text" -> receivedText(context, json.optString("text"))
            "find" -> FindPhone.start(context)
            "find.stop" -> Handler(Looper.getMainLooper()).post { FindPhone.stop(context) }
            "settings" -> prefs(context).edit().putBoolean("macRemote", json.optBoolean("remote", true)).apply()
        }
    }

    // MARK: Status

    fun status(context: Context): Message {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.let { it.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) * 100 / it.getIntExtra(BatteryManager.EXTRA_SCALE, 100) } ?: -1
        val plugged = (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val caps = manager.getNetworkCapabilities(manager.activeNetwork)
        val network = when {
            caps == null -> "none"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cell"
            else -> "other"
        }
        return Message.of("status", mapOf("battery" to level, "charging" to plugged, "network" to network))
    }

    fun watchBattery(context: Context, link: LinkManager): BroadcastReceiver {
        var last = ""
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val key = "$level/${intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0}"
                if (key != last) {
                    last = key
                    link.send(status(context))
                }
            }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
        return receiver
    }

    // MARK: Notifications

    private val sentText = ConcurrentHashMap<String, String>()
    private val sentIcons = ConcurrentHashMap.newKeySet<String>()

    fun posted(context: Context, sbn: StatusBarNotification, quiet: Boolean = false) {
        val prefs = prefs(context)
        if (!prefs.getBoolean("notifications", true)) return
        val notification = sbn.notification
        val extras = notification.extras
        val isCall = notification.category == Notification.CATEGORY_CALL
        if (sbn.packageName == context.packageName) return
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (sbn.isOngoing && !isCall) return
        if (extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) return
        if (sbn.packageName in muted(context)) return
        rememberApp(context, sbn.packageName)

        var title = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        var text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        // Chats: the latest message, and who sent it in a group.
        @Suppress("DEPRECATION")
        val messages = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (messages != null && messages.isNotEmpty()) {
            Notification.MessagingStyle.Message.getMessagesFromBundleArray(messages).lastOrNull()?.let { last ->
                text = last.text?.toString() ?: text
                val sender = last.senderPerson?.name?.toString()
                if (extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE) != null && sender != null) text = "$sender: $text"
                else if (title.isBlank() && sender != null) title = sender
            }
        }
        if (title.isBlank() && text.isBlank()) return

        val previous = sentText.put(sbn.key, title + text)
        val alertOnce = notification.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0
        val alert = !quiet && (previous == null || (previous != title + text && !alertOnce))
        val actions = notification.actions.orEmpty().mapIndexedNotNull { index, action ->
            val name = action.title?.toString() ?: return@mapIndexedNotNull null
            mapOf("i" to index, "title" to name, "reply" to (action.remoteInputs?.any { it.allowFreeFormInput } == true))
        }
        val icon = if (sentIcons.add(sbn.packageName)) appIcon(context, sbn.packageName) else ByteArray(0)
        LinkManager.get(context).send(Message.of("notif.post", mapOf(
            "key" to sbn.key, "pkg" to sbn.packageName, "app" to appName(context, sbn.packageName),
            "title" to title, "text" to text.take(1200), "time" to sbn.postTime, "call" to isCall,
            "alert" to alert, "actions" to actions,
        ), icon))
    }

    fun removed(context: Context, sbn: StatusBarNotification) {
        if (sentText.remove(sbn.key) != null) LinkManager.get(context).send(Message.of("notif.remove", mapOf("key" to sbn.key)))
    }

    internal fun act(context: Context, key: String, index: Int, reply: String?) {
        val sbn = runCatching { NotificationMirror.instance?.activeNotifications }.getOrNull()?.firstOrNull { it.key == key } ?: return
        val action = sbn.notification.actions?.getOrNull(index) ?: return
        val options = if (Build.VERSION.SDK_INT >= 34) {
            ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED).toBundle()
        } else null
        val inputs = action.remoteInputs
        val fill = if (reply != null && inputs != null) {
            Intent().also { intent ->
                val results = Bundle()
                inputs.forEach { results.putCharSequence(it.resultKey, reply) }
                RemoteInput.addResultsToIntent(inputs, intent, results)
            }
        } else null
        runCatching { action.actionIntent.send(context, 0, fill, null, null, null, options) }
    }

    fun muted(context: Context): Set<String> = prefs(context).getStringSet("muted", emptySet()) ?: emptySet()

    fun setMuted(context: Context, pkg: String, mute: Boolean) {
        val next = muted(context).toMutableSet().apply { if (mute) add(pkg) else remove(pkg) }
        prefs(context).edit().putStringSet("muted", next).apply()
    }

    /** Apps that have posted, for the mute list in Settings. */
    fun seenApps(context: Context): List<String> = prefs(context).getStringSet("seen", emptySet())?.sorted() ?: emptyList()

    private fun rememberApp(context: Context, pkg: String) {
        val seen = prefs(context).getStringSet("seen", emptySet()) ?: emptySet()
        if (pkg !in seen) prefs(context).edit().putStringSet("seen", seen + pkg).apply()
    }

    fun appName(context: Context, pkg: String): String = runCatching {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    }.getOrDefault(pkg.substringAfterLast('.'))

    fun appIcon(context: Context, pkg: String, size: Int = 96): ByteArray = runCatching {
        val drawable = context.packageManager.getApplicationIcon(pkg)
        val bitmap = (drawable as? BitmapDrawable)?.bitmap?.let { Bitmap.createScaledBitmap(it, size, size, true) }
            ?: Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also { bitmap ->
                drawable.setBounds(0, 0, size, size)
                drawable.draw(Canvas(bitmap))
            }
        ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }.getOrDefault(ByteArray(0))

    // MARK: Clipboard

    private const val FROM_MAC = "Islet · from Mac"

    fun setClipboard(context: Context, text: String) {
        Handler(Looper.getMainLooper()).post {
            context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(FROM_MAC, text))
        }
    }

    /** Reads the clipboard (only works while an Islet window has focus) and sends it. */
    fun sendClipboard(context: Context): Boolean {
        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip ?: return false
        if (clip.description.label == FROM_MAC) return false
        val text = clip.getItemAt(0)?.coerceToText(context)?.toString()?.takeIf { it.isNotEmpty() } ?: return false
        LinkManager.get(context).send(Message.of("clip", mapOf("text" to text)))
        return true
    }

    private fun receivedText(context: Context, text: String) {
        setClipboard(context, text)
        val link = Patterns.WEB_URL.matcher(text).takeIf { it.matches() }?.let { Uri.parse(if (text.contains("://")) text else "https://$text") }
        val open = PendingIntent.getActivity(context, text.hashCode(),
            if (link != null) Intent(Intent.ACTION_VIEW, link) else context.packageManager.getLaunchIntentForPackage(context.packageName),
            PendingIntent.FLAG_IMMUTABLE)
        notify(context, text.hashCode(), Notification.Builder(context, LinkService.CHANNEL_FILES)
            .setSmallIcon(R.drawable.ic_island)
            .setContentTitle(if (link != null) "Link from your Mac" else "Text from your Mac")
            .setContentText(if (link != null) "${link.host} · Copied" else text.take(120))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build())
    }

    // MARK: Files

    /** Files from the Mac land in Pictures, Movies, Music or Download / Islet, byte for byte. */
    fun openIncoming(context: Context, name: String, size: Long, mime: String): IncomingSink? {
        val resolver = context.contentResolver
        val (collection, folder) = when {
            mime.startsWith("image/") -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to "Pictures/Islet"
            mime.startsWith("video/") -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to "Movies/Islet"
            mime.startsWith("audio/") -> MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to "Music/Islet"
            else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to "Download/Islet"
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = runCatching { resolver.insert(collection, values) }.getOrNull() ?: return null
        val stream = resolver.openOutputStream(uri) ?: return null
        return object : IncomingSink {
            override val output: OutputStream = BufferedOutputStream(stream, 1 shl 20)
            override fun finish(ok: Boolean) {
                runCatching { output.close() }
                if (ok) {
                    resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
                    received(context, name, uri, mime)
                } else {
                    runCatching { resolver.delete(uri, null, null) }
                }
                context.getSystemService(NotificationManager::class.java).cancel(TRANSFER_ID)
            }
        }
    }

    private fun received(context: Context, name: String, uri: Uri, mime: String) {
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        notify(context, uri.hashCode(), Notification.Builder(context, LinkService.CHANNEL_FILES)
            .setSmallIcon(R.drawable.ic_island)
            .setContentTitle(name)
            .setContentText("From your Mac · Saved to Islet")
            .setContentIntent(PendingIntent.getActivity(context, uri.hashCode(), view, PendingIntent.FLAG_IMMUTABLE))
            .setAutoCancel(true)
            .build())
    }

    private const val TRANSFER_ID = 2
    private var lastProgress = 0L

    fun transferProgress(context: Context, name: String, done: Long, total: Long, incoming: Boolean) {
        val now = System.currentTimeMillis()
        if (done < total && now - lastProgress < 400) return
        lastProgress = now
        if (done >= total || total <= 0) {
            context.getSystemService(NotificationManager::class.java).cancel(TRANSFER_ID)
            return
        }
        notify(context, TRANSFER_ID, Notification.Builder(context, LinkService.CHANNEL_FILES)
            .setSmallIcon(if (incoming) android.R.drawable.stat_sys_download else android.R.drawable.stat_sys_upload)
            .setContentTitle(name)
            .setContentText(if (incoming) "Receiving from your Mac" else "Sending to your Mac")
            .setProgress(1000, (done * 1000 / total).toInt(), false)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build())
    }

    /** Files picked or shared on the phone, read straight from their original source. */
    fun sendUris(context: Context, uris: List<Uri>): Int {
        val link = LinkManager.get(context)
        var count = 0
        for (uri in uris) {
            // Photos keep their location data (needs ACCESS_MEDIA_LOCATION).
            val source = if (uri.authority == MediaStore.AUTHORITY && Build.VERSION.SDK_INT >= 29) {
                runCatching { MediaStore.setRequireOriginal(uri) }.getOrDefault(uri)
            } else uri
            var name = "File"
            var size = 0L
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    name = cursor.getString(0) ?: name
                    size = cursor.getLong(1)
                }
            }
            val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
            val file = OutgoingFile(name, size, mime) {
                runCatching { context.contentResolver.openInputStream(source) }.getOrNull()
                    ?: context.contentResolver.openInputStream(uri)!!
            }
            val queued = link.send(file)
            android.util.Log.i("IsletLink", "send $name ($size bytes, $mime): ${if (queued) "queued" else "not connected"}")
            if (queued) count++
        }
        return count
    }

    private fun notify(context: Context, id: Int, notification: Notification) {
        runCatching { context.getSystemService(NotificationManager::class.java).notify(id, notification) }
    }
}

/** Mirrors notifications to the Mac, and is the key to the phone's media sessions. */
class NotificationMirror : NotificationListenerService() {
    override fun onListenerConnected() {
        instance = this
        LinkService.start(this)
        PhoneMedia.start(this)
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification, rankingMap: RankingMap?) {
        Features.posted(this, sbn)
        DotFeed.posted(this, sbn, rankingMap)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        Features.removed(this, sbn)
        DotFeed.removed(sbn)
    }

    companion object {
        @Volatile var instance: NotificationMirror? = null

        fun allowed(context: Context): Boolean =
            android.provider.Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
                ?.contains(ComponentName(context, NotificationMirror::class.java).flattenToString()) == true
    }
}

/** What the phone plays (Spotify, YouTube Music…), shown on the Mac with controls. */
object PhoneMedia {
    private var manager: MediaSessionManager? = null
    private var controller: MediaController? = null
    val current: MediaController? get() = controller
    private var appContext: Context? = null
    private var lastArtTitle: String? = null

    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = send()
        override fun onPlaybackStateChanged(state: PlaybackState?) = send()
        override fun onSessionDestroyed() { pick() }
    }

    private val sessionsChanged = MediaSessionManager.OnActiveSessionsChangedListener { pick() }

    fun start(context: Context) {
        if (manager != null) return
        appContext = context.applicationContext
        val manager = context.getSystemService(MediaSessionManager::class.java)
        this.manager = manager
        runCatching {
            manager.addOnActiveSessionsChangedListener(sessionsChanged, ComponentName(context, NotificationMirror::class.java),
                                                       Handler(Looper.getMainLooper()))
        }
        pick()
    }

    private fun pick() {
        val context = appContext ?: return
        val sessions = runCatching {
            manager?.getActiveSessions(ComponentName(context, NotificationMirror::class.java))
        }.getOrNull().orEmpty().filter { it.packageName != context.packageName }
        val next = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: sessions.firstOrNull()
        if (next?.sessionToken == controller?.sessionToken) return
        controller?.unregisterCallback(callback)
        controller = next
        lastArtTitle = null
        next?.registerCallback(callback, Handler(Looper.getMainLooper()))
        send()
    }

    fun resend(context: Context) {
        appContext = appContext ?: context.applicationContext
        lastArtTitle = null
        send()
    }

    private fun send() {
        val context = appContext ?: return
        DotFeed.media(context, controller)
        if (!Features.prefs(context).getBoolean("media", true)) return
        val link = LinkManager.get(context)
        val controller = controller
        val metadata = controller?.metadata
        if (controller == null || metadata == null) {
            link.send(Message.of("media.clear"))
            return
        }
        val title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        val state = controller.playbackState
        var art = ByteArray(0)
        if (title != lastArtTitle) {
            val bitmap = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_ART)
            if (bitmap != null) {
                lastArtTitle = title
                val scale = 512f / maxOf(bitmap.width, bitmap.height)
                val small = if (scale < 1) Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt(), (bitmap.height * scale).toInt(), true) else bitmap
                art = ByteArrayOutputStream().also { small.compress(Bitmap.CompressFormat.JPEG, 86, it) }.toByteArray()
            }
        }
        val elapsed = state?.let {
            val moved = if (it.state == PlaybackState.STATE_PLAYING) ((android.os.SystemClock.elapsedRealtime() - it.lastPositionUpdateTime) * it.playbackSpeed).toLong() else 0
            it.position + moved
        } ?: 0
        link.send(Message.of("media.state", mapOf(
            "title" to title,
            "artist" to (metadata.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: metadata.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""),
            "duration" to metadata.getLong(MediaMetadata.METADATA_KEY_DURATION),
            "position" to elapsed,
            "playing" to (state?.state == PlaybackState.STATE_PLAYING),
            "app" to Features.appName(context, controller.packageName),
        ), art))
    }

    fun command(action: String, value: Double) {
        val controls = controller?.transportControls ?: return
        when (action) {
            "toggle" -> if (controller?.playbackState?.state == PlaybackState.STATE_PLAYING) controls.pause() else controls.play()
            "play" -> controls.play()
            "pause" -> controls.pause()
            "next" -> controls.skipToNext()
            "previous" -> controls.skipToPrevious()
            "seek" -> controls.seekTo((value * 1000).toLong())
        }
    }
}

/** Find My Phone: rings at alarm volume (even on silent) until stopped. */
object FindPhone {
    private var player: MediaPlayer? = null
    private var previousVolume = -1
    const val NOTIFICATION = 3

    private var vibrator: android.os.Vibrator? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { appContext?.let { stop(it) } }
    private var appContext: Context? = null

    fun start(context: Context) {
        if (player != null || vibrator != null) return
        appContext = context.applicationContext
        val audio = context.getSystemService(AudioManager::class.java)
        // Silent mode or Do Not Disturb can refuse volume changes; ringing must not depend on it.
        runCatching {
            previousVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
            audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        }.onFailure { previousVolume = -1 }
        player = runCatching {
            MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setDataSource(context, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM))
                isLooping = true
                prepare()
                start()
            }
        }.getOrNull()
        if (Build.VERSION.SDK_INT >= 31) {
            vibrator = context.getSystemService(VibratorManager::class.java).defaultVibrator.also {
                runCatching { it.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 600, 400), 0)) }
            }
        }
        // Never rings forever, even if every way to stop it is missed.
        handler.postDelayed(timeout, 60_000)
        val full = PendingIntent.getActivity(context, 7, Intent(context, FindActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                             PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getBroadcast(context, 8, Intent(context, StopRingReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
        runCatching {
            context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION,
                Notification.Builder(context, LinkService.CHANNEL_ALERTS)
                    .setSmallIcon(R.drawable.ic_island)
                    .setContentTitle("Your Mac is looking for this phone")
                    .setContentText("Tap to stop")
                    .setCategory(Notification.CATEGORY_ALARM)
                    .setFullScreenIntent(full, true)
                    .setContentIntent(stop)
                    .setDeleteIntent(stop)
                    .addAction(Notification.Action.Builder(null, "Stop", stop).build())
                    .setOngoing(true)
                    .build())
        }
    }

    /** Each step on its own, so one refusal (volume in silent mode) can't leave it ringing. */
    fun stop(context: Context) {
        handler.removeCallbacks(timeout)
        vibrator?.let { runCatching { it.cancel() } }
        vibrator = null
        player?.let { runCatching { it.stop() }; runCatching { it.release() } }
        player = null
        runCatching { context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION) }
        if (previousVolume >= 0) {
            runCatching { context.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, previousVolume, 0) }
            previousVolume = -1
        }
    }

    val ringing: Boolean get() = player != null || vibrator != null
}

class StopRingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = FindPhone.stop(context)
}
