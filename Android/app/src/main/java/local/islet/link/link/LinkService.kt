package local.islet.link.link

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat
import local.islet.link.R
import local.islet.link.features.Features
import local.islet.link.ui.MainActivity

/**
 * Keeps Islet Link running while a Mac is paired. Its one notification is also the
 * Mac's music: a real media session, so the Mac's song sits in the phone's quick
 * settings media player and on the lock screen, with play/pause, skip and seeking.
 */
class LinkService : Service() {
    private lateinit var session: MediaSession
    private val link by lazy { LinkManager.get(this) }
    private var battery: BroadcastReceiver? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        channels(this)
        session = MediaSession(this, "IsletMac").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = link.macCommand("play")
                override fun onPause() = link.macCommand("pause")
                override fun onSkipToNext() = link.macCommand("next")
                override fun onSkipToPrevious() = link.macCommand("previous")
                override fun onSeekTo(pos: Long) = link.macCommand("seek", pos / 1000.0)
            })
        }
        current = this
        battery = Features.watchBattery(this, link)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(ID, notification)
        }
        when (intent?.action) {
            ACTION_TOGGLE -> link.macCommand("toggle")
            ACTION_NEXT -> link.macCommand("next")
            ACTION_PREVIOUS -> link.macCommand("previous")
        }
        link.run()
        return START_STICKY
    }

    override fun onDestroy() {
        battery?.let { unregisterReceiver(it) }
        session.release()
        if (current === this) current = null
        super.onDestroy()
    }

    private fun update() {
        getSystemService(NotificationManager::class.java).notify(ID, build())
    }

    private fun build(): Notification {
        val state = link.state.value
        val media = link.media.value
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
                                             PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = Notification.Builder(this, if (media != null) CHANNEL_MEDIA else CHANNEL_LINK)
            .setSmallIcon(R.drawable.ic_island)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)

        if (media != null && state is LinkState.Connected) {
            session.setMetadata(MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, media.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, media.artist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, media.album)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, media.durationMs)
                .apply { media.art?.let { putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) } }
                .build())
            session.setPlaybackState(PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_SEEK_TO)
                .setState(if (media.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                          media.positionAt(System.currentTimeMillis()), if (media.playing) 1f else 0f)
                .build())
            session.isActive = true
            builder
                .setContentTitle(media.title)
                .setContentText(listOf(media.artist, media.app).filter { it.isNotBlank() }.joinToString(" · "))
                .setSubText("On ${state.macName}")
                .setLargeIcon(media.art)
                .addAction(action(R.drawable.ic_previous, "Previous", ACTION_PREVIOUS))
                .addAction(action(if (media.playing) R.drawable.ic_pause else R.drawable.ic_play,
                                  if (media.playing) "Pause" else "Play", ACTION_TOGGLE))
                .addAction(action(R.drawable.ic_next, "Next", ACTION_NEXT))
                .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1, 2))
                .setVisibility(Notification.VISIBILITY_PUBLIC)
        } else {
            session.isActive = false
            val (title, text) = when (state) {
                is LinkState.Connected -> "Connected to ${state.macName}" to "Over ${state.transport.label}"
                is LinkState.Searching -> "Looking for ${state.macName}" to "Connects over Wi-Fi, USB or Bluetooth"
                is LinkState.Pairing -> "Pairing with ${state.macName}" to (state.code?.let { "Code $it" } ?: "Waiting for the Mac")
                LinkState.Unpaired -> "Not paired" to "Open Islet to pair with your Mac"
            }
            builder.setContentTitle(title).setContentText(text)
        }
        return builder.build()
    }

    private fun action(icon: Int, title: String, action: String): Notification.Action {
        val intent = PendingIntent.getService(this, action.hashCode(), Intent(this, LinkService::class.java).setAction(action),
                                              PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Action.Builder(Icon.createWithResource(this, icon), title, intent).build()
    }

    companion object {
        const val ID = 1
        const val CHANNEL_LINK = "link"
        const val CHANNEL_MEDIA = "mac-music"
        const val CHANNEL_ALERTS = "alerts"
        const val CHANNEL_FILES = "files"
        private const val ACTION_TOGGLE = "toggle"
        private const val ACTION_NEXT = "next"
        private const val ACTION_PREVIOUS = "previous"
        @Volatile private var current: LinkService? = null

        fun start(context: Context) {
            if (LinkManager.get(context).pairedMacId == null) return
            runCatching { ContextCompat.startForegroundService(context, Intent(context, LinkService::class.java)) }
        }

        /** Redraws the notification (connection or Mac music changed). */
        fun refresh(context: Context) {
            current?.let { service -> android.os.Handler(service.mainLooper).post { service.update() } }
        }

        fun channels(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannels(listOf(
                NotificationChannel(CHANNEL_LINK, "Connection", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Shows that Islet is connected to your Mac"
                    setShowBadge(false)
                },
                NotificationChannel(CHANNEL_MEDIA, "Mac music", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "What your Mac is playing, with controls"
                    setShowBadge(false)
                },
                NotificationChannel(CHANNEL_ALERTS, "Find my phone", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Rings when your Mac looks for this phone"
                },
                NotificationChannel(CHANNEL_FILES, "Files from your Mac", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "Files, links and text your Mac sends"
                },
            ))
        }
    }
}

/** Starts the link after a reboot or an app update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        LinkService.start(context)
    }
}
