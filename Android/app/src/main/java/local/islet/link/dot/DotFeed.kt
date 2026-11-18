package local.islet.link.dot

import android.app.ActivityOptions
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.BitmapDrawable
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.PlaybackState
import android.os.Build
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.core.graphics.createBitmap
import androidx.core.graphics.scale
import kotlinx.coroutines.flow.MutableStateFlow
import local.islet.link.features.Features
import local.islet.link.features.NotificationMirror
import local.islet.link.features.PhoneMedia

/**
 * What the Dynamic Dot shows, fed by the notification listener and the media session
 * Islet already watches for the Mac. Nothing here polls: every value changes only when
 * Android reports a change, and nothing is decoded while the dot is off.
 */
object DotFeed {
    data class Media(
        val title: String, val artist: String, val art: Bitmap?, val tint: Int,
        val playing: Boolean, val position: Long, val updatedAt: Long, val speed: Float, val duration: Long,
        val pkg: String, val open: PendingIntent?,
    ) {
        /** Where playback is now, without asking the player again. */
        fun positionAt(now: Long): Long {
            val moved = if (playing) ((now - updatedAt) * speed).toLong() else 0
            val at = position + moved
            return if (duration > 0) at.coerceIn(0, duration) else at.coerceAtLeast(0)
        }
    }

    data class Alert(val key: String, val pkg: String, val title: String, val text: String, val icon: Bitmap?,
                     val open: PendingIntent?, val stamp: Long = SystemClock.uptimeMillis())

    data class Call(val key: String, val pkg: String, val name: String, val incoming: Boolean, val since: Long?,
                    val icon: Bitmap?, val actions: List<String>)

    /** The dot's size and place, as the four slider values (0…1) in Settings. */
    data class Tune(val x: Float = 0.5f, val y: Float = 0f, val width: Float = WIDTH, val height: Float = HEIGHT) {
        val offsetX: Float get() = (x - 0.5f) * 240f
        val offsetY: Float get() = y * 40f
        val widthScale: Float get() = 0.75f + width * 0.85f
        val heightScale: Float get() = 0.8f + height * 0.7f

        companion object {
            const val WIDTH = 0.25f / 0.85f
            const val HEIGHT = 0.2f / 0.7f
        }
    }

    val tune = MutableStateFlow(Tune())
    /** When a slider last moved, so the dot shows itself while you adjust it. */
    val preview = MutableStateFlow(0L)

    fun loadTune(context: Context) {
        val p = Features.prefs(context)
        tune.value = Tune(p.getFloat("dot_x", 0.5f), p.getFloat("dot_y", 0f), p.getFloat("dot_w", Tune.WIDTH), p.getFloat("dot_h", Tune.HEIGHT))
    }

    fun setTune(context: Context, next: Tune) {
        tune.value = next
        preview.value = SystemClock.uptimeMillis()
        Features.prefs(context).edit().putFloat("dot_x", next.x).putFloat("dot_y", next.y)
            .putFloat("dot_w", next.width).putFloat("dot_h", next.height).apply()
    }

    val media = MutableStateFlow<Media?>(null)
    val alert = MutableStateFlow<Alert?>(null)
    val call = MutableStateFlow<Call?>(null)

    private val alerted = HashSet<String>()

    fun on(context: Context, what: String) = Features.prefs(context).getBoolean("dot_$what", true)

    fun setOn(context: Context, what: String, on: Boolean) {
        Features.prefs(context).edit().putBoolean("dot_$what", on).apply()
        when (what) {
            "music" -> media(context, PhoneMedia.current)
            "notifications" -> if (!on) alert.value = null
        }
    }

    // MARK: Music

    fun media(context: Context, controller: MediaController?) {
        if (DotService.instance == null) return
        val metadata = controller?.metadata
        val title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)
        if (controller == null || metadata == null || title.isNullOrBlank() || !on(context, "music")) {
            media.value = null
            return
        }
        val previous = media.value
        val sameTrack = previous != null && previous.title == title && previous.pkg == controller.packageName
        val art = if (sameTrack && previous.art != null) previous.art else thumbnail(metadata)
        val state = controller.playbackState
        media.value = Media(
            title = title,
            artist = metadata.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: metadata.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: "",
            art = art,
            tint = if (sameTrack && previous.art === art) previous.tint else tintOf(art),
            playing = state?.state == PlaybackState.STATE_PLAYING,
            position = state?.position ?: 0,
            updatedAt = state?.lastPositionUpdateTime?.takeIf { it > 0 } ?: SystemClock.elapsedRealtime(),
            speed = state?.playbackSpeed?.takeIf { it > 0 } ?: 1f,
            duration = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION),
            pkg = controller.packageName,
            open = controller.sessionActivity,
        )
    }

    /** Small enough to draw for free; decoded once per track. */
    private fun thumbnail(metadata: MediaMetadata): Bitmap? {
        val bitmap = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON) ?: return null
        val scale = 192f / maxOf(bitmap.width, bitmap.height)
        return if (scale < 1) bitmap.scale((bitmap.width * scale).toInt().coerceAtLeast(1), (bitmap.height * scale).toInt().coerceAtLeast(1)) else bitmap
    }

    /** The art's average colour, lifted so the level bars read on black (Apple Music tints them the same way). */
    internal fun tintOf(art: Bitmap?): Int {
        art ?: return DEFAULT_TINT
        val pixel = runCatching { art.scale(1, 1).getPixel(0, 0) }.getOrNull() ?: return DEFAULT_TINT
        val hsv = FloatArray(3)
        Color.colorToHSV(pixel, hsv)
        if (hsv[1] < 0.12f) return DEFAULT_TINT
        hsv[1] = hsv[1].coerceIn(0.25f, 0.6f)
        hsv[2] = hsv[2].coerceAtLeast(0.88f)
        return Color.HSVToColor(hsv)
    }

    private const val DEFAULT_TINT = 0xFFEDEBE6.toInt()

    // MARK: Notifications and calls

    fun posted(context: Context, sbn: StatusBarNotification, ranking: NotificationListenerService.RankingMap?) {
        if (DotService.instance == null) return
        val notification = sbn.notification
        val extras = notification.extras
        if (sbn.packageName == context.packageName) return
        if (notification.category == Notification.CATEGORY_CALL) {
            val callType = extras.getInt("android.callType", 0)
            val incoming = if (callType != 0) callType == 1 else !extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER)
            call.value = Call(
                key = sbn.key, pkg = sbn.packageName,
                name = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.takeIf { it.isNotBlank() } ?: "Call",
                incoming = incoming,
                since = if (incoming) null else notification.`when`.takeIf { it > 0 },
                icon = call.value?.takeIf { it.key == sbn.key }?.icon ?: icon(context, sbn.packageName),
                actions = notification.actions.orEmpty().map { it.title?.toString() ?: "" },
            )
            return
        }
        if (!on(context, "notifications")) return
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (sbn.isOngoing || extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) return
        // Updates to something already shown (progress, edits) don't pop the dot again.
        val firstTime = alerted.add(sbn.key)
        if (!firstTime && notification.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0) return
        val rank = NotificationListenerService.Ranking()
        if (ranking?.getRanking(sbn.key, rank) == true) {
            if (!rank.matchesInterruptionFilter() || rank.importance < NotificationManager.IMPORTANCE_DEFAULT) return
            if (Build.VERSION.SDK_INT < 34 && rank.isAmbient) return
        }
        var title = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        var text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        @Suppress("DEPRECATION")
        extras.getParcelableArray(Notification.EXTRA_MESSAGES)?.takeIf { it.isNotEmpty() }?.let { messages ->
            Notification.MessagingStyle.Message.getMessagesFromBundleArray(messages).lastOrNull()?.let { last ->
                text = last.text?.toString() ?: text
                if (title.isBlank()) title = last.senderPerson?.name?.toString() ?: title
            }
        }
        if (title.isBlank() && text.isBlank()) return
        if (title.isBlank()) title = Features.appName(context, sbn.packageName)
        alert.value = Alert(sbn.key, sbn.packageName, title, text.replace('\n', ' '), icon(context, sbn.packageName), notification.contentIntent)
    }

    fun removed(sbn: StatusBarNotification) {
        alerted.remove(sbn.key)
        if (call.value?.key == sbn.key) call.value = null
        if (alert.value?.key == sbn.key) alert.value = null
    }

    /** Picks up a call already ringing when the dot is switched on. */
    fun seed(context: Context) {
        loadTune(context)
        media(context, PhoneMedia.current)
        runCatching { NotificationMirror.instance?.activeNotifications }.getOrNull()
            ?.firstOrNull { it.notification.category == Notification.CATEGORY_CALL }
            ?.let { posted(context, it, null) }
    }

    fun act(context: Context, key: String, index: Int) = Features.act(context, key, index, null)

    fun open(context: Context, intent: PendingIntent?) {
        intent ?: return
        val options = if (Build.VERSION.SDK_INT >= 34) {
            ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED).toBundle()
        } else null
        runCatching { intent.send(context, 0, null, null, null, null, options) }
    }

    private val icons = HashMap<String, Bitmap>()

    private fun icon(context: Context, pkg: String): Bitmap? = icons[pkg] ?: runCatching {
        val drawable = context.packageManager.getApplicationIcon(pkg)
        val size = 72
        ((drawable as? BitmapDrawable)?.bitmap?.scale(size, size)
            ?: createBitmap(size, size).also { bitmap ->
                drawable.setBounds(0, 0, size, size)
                drawable.draw(android.graphics.Canvas(bitmap))
            })
    }.getOrNull()?.also { icons[pkg] = it }
}
