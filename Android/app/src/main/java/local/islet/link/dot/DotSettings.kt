package local.islet.link.dot

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Height
import androidx.compose.material.icons.rounded.SettingsEthernet
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import local.islet.link.ui.LevelControl
import local.islet.link.ui.pressable
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import local.islet.link.features.NotificationMirror
import local.islet.link.ui.Button
import local.islet.link.ui.Card
import local.islet.link.ui.Islet
import local.islet.link.ui.ToggleRow
import local.islet.link.ui.openListenerSettings

/** Where the dot sits and how big it is; the dot shows itself on screen while a slider moves. */
@Composable
private fun DotShape() {
    val context = LocalContext.current
    val tune by DotFeed.tune.collectAsState()
    LaunchedEffect(Unit) { DotFeed.loadTune(context) }
    fun set(next: DotFeed.Tune) = DotFeed.setTune(context, next)
    Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Size and position", style = Islet.body.copy(fontWeight = FontWeight.Medium), modifier = Modifier.weight(1f))
            if (tune != DotFeed.Tune()) {
                Text("Reset", color = Islet.blue, fontWeight = FontWeight.Medium,
                     modifier = Modifier.pressable { set(DotFeed.Tune()) }.padding(vertical = 6.dp, horizontal = 4.dp))
            }
        }
        Text("Watch the dot at the top of the screen as you drag.", style = Islet.caption)
        Shape("Left and right", Icons.Rounded.SwapHoriz, tune.x) { set(tune.copy(x = it)) }
        Shape("Down from the top", Icons.Rounded.SwapVert, tune.y) { set(tune.copy(y = it)) }
        Shape("Width", Icons.Rounded.SettingsEthernet, tune.width) { set(tune.copy(width = it)) }
        Shape("Height", Icons.Rounded.Height, tune.height) { set(tune.copy(height = it)) }
    }
}

@Composable
private fun Shape(label: String, icon: ImageVector, value: Float, onChange: (Float) -> Unit) {
    Text(label, style = Islet.caption, modifier = Modifier.padding(top = 16.dp, bottom = 8.dp))
    LevelControl(value, enabled = true, icon = { icon }, description = label, onChange = onChange)
}

/** Settings → Dynamic Dot: switch it on, and choose what it shows. */
@Composable
fun DotCard(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var on by remember { mutableStateOf(DotService.enabled(context)) }
    var listener by remember { mutableStateOf(NotificationMirror.allowed(context)) }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) { on = DotService.enabled(context); listener = NotificationMirror.allowed(context) }
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    var music by remember { mutableStateOf(DotFeed.on(context, "music")) }
    var notifications by remember { mutableStateOf(DotFeed.on(context, "notifications")) }
    var charging by remember { mutableStateOf(DotFeed.on(context, "charging")) }

    Card(modifier.fillMaxWidth(), padding = 0.dp) {
        Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 18.dp)) {
            Text(if (on) "On" else "Your camera, as an island", style = Islet.heading)
            Text("Music, calls, notifications and charging grow out of the front camera. Tap it to open, swipe up to close, hold it to go to the app.",
                 style = Islet.caption, modifier = Modifier.padding(top = 4.dp))
            Spacer(Modifier.height(16.dp))
            when {
                !listener -> {
                    Text("It needs notification access first.", style = Islet.caption)
                    Spacer(Modifier.height(10.dp))
                    Button("Allow Notification Access") { openListenerSettings(context) }
                }
                !on -> {
                    Button("Turn On Dynamic Dot") { DotService.openSettings(context) }
                    Text("Turn on \"Islet Dynamic Dot\" on the next screen. If Android says it's restricted: App info → ⋮ → Allow restricted settings, then try again.",
                         style = Islet.caption, modifier = Modifier.padding(top = 10.dp))
                }
                else -> Button("Turn Off", primary = false) { DotService.openSettings(context) }
            }
        }
        if (on && listener) {
            HorizontalDivider(color = Islet.stroke)
            Column(Modifier.padding(horizontal = 20.dp)) {
                ToggleRow("Music", "Art and level bars; tap for controls", music) { music = it; DotFeed.setOn(context, "music", it) }
                HorizontalDivider(color = Islet.stroke)
                ToggleRow("Notifications", "Who and what, for a few seconds", notifications) { notifications = it; DotFeed.setOn(context, "notifications", it) }
                HorizontalDivider(color = Islet.stroke)
                ToggleRow("Charging", "When you plug in", charging) { charging = it; DotFeed.setOn(context, "charging", it) }
            }
            HorizontalDivider(color = Islet.stroke)
            DotShape()
        }
    }
}
