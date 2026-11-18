package local.islet.link.ui

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.IntentCompat
import local.islet.link.features.Features
import local.islet.link.features.FindPhone
import local.islet.link.link.LinkManager
import local.islet.link.wire.Message

/** "Share → Islet" from any app: files go to the Mac as they are; text and links too. */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val link = LinkManager.get(this)
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE -> IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> emptyList()
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val message = when {
            !link.connected -> "Not connected to ${link.pairedMacName}"
            uris.isNotEmpty() -> "Sending ${Features.sendUris(this, uris)} to ${link.pairedMacName}"
            !text.isNullOrBlank() -> { link.send(Message.of("text", mapOf("text" to text))); "Sent to ${link.pairedMacName}" }
            else -> "Nothing to send"
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        finish()
    }
}

/**
 * Android only lets the focused app read the clipboard, so the quick settings tile opens
 * this invisible window for a moment, reads it, sends it, and closes.
 */
class ClipboardActivity : ComponentActivity() {
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        val sent = LinkManager.get(this).connected && Features.sendClipboard(this)
        Toast.makeText(this, if (sent) "Clipboard sent to your Mac" else "Nothing sent", Toast.LENGTH_SHORT).show()
        finish()
    }
}

class ClipboardTile : TileService() {
    override fun onClick() {
        val intent = Intent(this, ClipboardActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated") startActivityAndCollapse(intent)
        }
    }
}

/** Find My Phone, full screen over the lock screen: a pulsing phone and a big Stop. */
class FindActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        setContent {
            IsletTheme {
                val pulse = rememberInfiniteTransition(label = "find")
                val reduced = LocalReducedMotion.current
                val animated by pulse.animateFloat(1f, 1.6f, infiniteRepeatable(tween(1100), RepeatMode.Restart), label = "ring")
                val scale = if (reduced) 1.3f else animated
                Box(Modifier.fillMaxSize().background(Islet.background), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(32.dp)) {
                        Box(contentAlignment = Alignment.Center) {
                            Box(Modifier.size(150.dp).graphicsLayer { scaleX = scale; scaleY = scale; alpha = 1.6f - scale }
                                .border(2.dp, Islet.text, CircleShape))
                            Box(Modifier.size(150.dp).background(Islet.fill, CircleShape), contentAlignment = Alignment.Center) {
                                Icon(Icons.Rounded.PhoneAndroid, null, tint = Islet.background, modifier = Modifier.size(72.dp))
                            }
                        }
                        Spacer(Modifier.height(40.dp))
                        Text("Here I am", style = Islet.title)
                        Text("Your Mac is looking for this phone.", color = Islet.secondary, fontSize = 17.sp, textAlign = TextAlign.Center)
                        Spacer(Modifier.height(40.dp))
                        Button("Stop") {
                            FindPhone.stop(this@FindActivity)
                            finish()
                        }
                    }
                }
            }
        }
    }
}
