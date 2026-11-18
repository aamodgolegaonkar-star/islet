package local.islet.link.ui

import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.automirrored.rounded.VolumeDown
import androidx.compose.material.icons.automirrored.rounded.VolumeMute
import androidx.compose.material.icons.automirrored.rounded.VolumeOff
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.BrightnessHigh
import androidx.compose.material.icons.rounded.BrightnessLow
import androidx.compose.material.icons.rounded.BrightnessMedium
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PhotoLibrary
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Screenshot
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material.icons.rounded.TravelExplore
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.math.abs
import kotlin.math.sqrt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import local.islet.link.features.Features
import local.islet.link.link.LinkManager
import local.islet.link.link.LinkState
import local.islet.link.link.MacMedia
import local.islet.link.link.Transport
import local.islet.link.wire.Message

private val screenPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 130.dp)

@Composable
private fun ScreenTitle(text: String, detail: String? = null) {
    Column(Modifier.padding(start = 4.dp, top = 28.dp, bottom = 8.dp).entrance(0)) {
        Text(text, style = Islet.title)
        if (detail != null) Text(detail, style = Islet.caption, modifier = Modifier.padding(top = 4.dp))
    }
}

// MARK: Mac

@Composable
fun MacScreen(link: LinkManager) {
    val state by link.state.collectAsStateWithLifecycle()
    val mac by link.mac.collectAsStateWithLifecycle()
    val media by link.media.collectAsStateWithLifecycle()
    val shortcuts by link.shortcuts.collectAsStateWithLifecycle()
    val needs = rememberNeeds().filterNot { it.granted }
    val context = LocalContext.current
    val connected = state is LinkState.Connected

    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = screenPadding) {
        item { Header(state, mac.battery, mac.charging) }
        if (needs.isNotEmpty()) item { SetupCard(needs, Modifier.entrance(1)) }
        item {
            Box(Modifier.entrance(2)) {
                AnimatedContent(media, contentKey = { it != null }, transitionSpec = { fadeIn(tween(300)) togetherWith fadeOut(tween(150)) }, label = "media") { current ->
                    if (current != null) NowPlaying(current, link) else Card(Modifier.fillMaxWidth()) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.MusicNote, null, tint = Islet.tertiary, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(14.dp))
                            Text(if (connected) "Nothing playing on ${mac.name}" else "Waiting for your Mac", style = Islet.body.copy(color = Islet.secondary))
                        }
                    }
                }
            }
        }
        item {
            SectionTitle("Sound and screen", Modifier.entrance(3))
            Column(Modifier.entrance(3)) {
                LevelControl(mac.volume, connected, icon = { volumeIcon(it) }, description = "Mac volume") { link.setMacVolume(it) }
                mac.brightness?.let { brightness ->
                    Spacer(Modifier.height(10.dp))
                    LevelControl(brightness, connected, icon = { brightnessIcon(it) }, description = "Mac brightness") { link.setMacBrightness(it) }
                }
            }
        }
        item {
            SectionTitle("Quick actions", Modifier.entrance(4))
            Card(Modifier.fillMaxWidth().entrance(4), padding = 12.dp) {
                val actions: List<Triple<ImageVector, String, () -> Unit>> = listOf(
                    Triple(Icons.Rounded.ContentPaste, "Clipboard") {
                        Toast.makeText(context, if (Features.sendClipboard(context)) "Clipboard sent" else "Clipboard is empty", Toast.LENGTH_SHORT).show()
                    },
                    Triple(Icons.Rounded.TravelExplore, "Find Mac") { link.send(Message.of("find")) },
                    Triple(Icons.Rounded.Lock, "Lock") { link.macCommand("lock") },
                    Triple(Icons.Rounded.Bedtime, "Sleep") { link.macCommand("sleep") },
                    Triple(Icons.Rounded.Screenshot, "Screenshot") { link.macCommand("screenshot") },
                    Triple(Icons.Rounded.Search, "Spotlight") { link.input("key", "key" to "space", "mods" to listOf("cmd")) },
                    Triple(Icons.Rounded.GridView, "Spaces") { link.input("key", "key" to "up", "mods" to listOf("ctrl")) },
                    Triple(Icons.Rounded.SwapHoriz, "Switch App") { link.input("key", "key" to "tab", "mods" to listOf("cmd")) },
                )
                actions.chunked(4).forEach { row ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                        row.forEach { (icon, label, run) -> ActionTile(icon, label, Modifier.weight(1f), onClick = run) }
                    }
                }
            }
        }
        if (shortcuts.isNotEmpty()) {
            item {
                SectionTitle("Shortcuts on your Mac", Modifier.entrance(5))
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.entrance(5)) {
                    items(shortcuts) { name ->
                        Text(name, style = Islet.body.copy(fontSize = 15.sp), maxLines = 1,
                             modifier = Modifier.pressable {
                                 link.macCommand("shortcut", name = name)
                                 Toast.makeText(context, "Running $name", Toast.LENGTH_SHORT).show()
                             }.clip(RoundedCornerShape(14.dp)).background(Islet.card).border(1.dp, Islet.stroke, RoundedCornerShape(14.dp))
                                 .padding(horizontal = 18.dp, vertical = 14.dp))
                    }
                }
            }
        }
    }
}

private fun volumeIcon(value: Float) = when {
    value <= 0.001f -> Icons.AutoMirrored.Rounded.VolumeOff
    value < 0.34f -> Icons.AutoMirrored.Rounded.VolumeMute
    value < 0.67f -> Icons.AutoMirrored.Rounded.VolumeDown
    else -> Icons.AutoMirrored.Rounded.VolumeUp
}

private fun brightnessIcon(value: Float) = when {
    value < 0.34f -> Icons.Rounded.BrightnessLow
    value < 0.67f -> Icons.Rounded.BrightnessMedium
    else -> Icons.Rounded.BrightnessHigh
}

@Composable
private fun Header(state: LinkState, battery: Int?, charging: Boolean) {
    val (name, detail, live) = when (state) {
        is LinkState.Connected -> Triple(state.macName, "Connected over ${state.transport.label}", true)
        is LinkState.Searching -> Triple(state.macName, "Looking for your Mac", false)
        is LinkState.Pairing -> Triple(state.macName, "Pairing", false)
        LinkState.Unpaired -> Triple("Islet", "Not paired", false)
    }
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, top = 28.dp, bottom = 18.dp).entrance(0), verticalAlignment = Alignment.Bottom) {
        Column(Modifier.weight(1f)) {
            Text(name, style = Islet.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(if (live) Islet.green else Islet.tertiary))
                Spacer(Modifier.width(8.dp))
                Text(detail, style = Islet.caption)
            }
        }
        if (battery != null && live) {
            Spacer(Modifier.width(16.dp))
            BatteryRing(battery, charging)
        }
    }
}

@Composable
fun BatteryRing(level: Int, charging: Boolean, size: Int = 54) {
    val reduced = LocalReducedMotion.current
    val sweep by animateFloatAsState(level / 100f, if (reduced) snap() else Motion.gentle(), label = "battery")
    val color = when { charging -> Islet.green; level <= 20 -> Islet.red; else -> Islet.text }
    Box(Modifier.size(size.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = androidx.compose.ui.graphics.drawscope.Stroke(width = 3.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round)
            drawArc(Color.White.copy(alpha = 0.1f), 0f, 360f, false, style = stroke)
            drawArc(color, -90f, 360f * sweep, false, style = stroke)
        }
        Text("$level", style = Islet.number.copy(color = Islet.text, fontSize = 14.sp))
    }
}

@Composable
private fun SetupCard(needs: List<Need>, modifier: Modifier) {
    Card(modifier.fillMaxWidth().padding(bottom = 14.dp), padding = 0.dp) {
        Text("Finish setting up", style = Islet.heading, modifier = Modifier.padding(start = 20.dp, top = 18.dp, bottom = 6.dp))
        needs.forEachIndexed { index, need ->
            if (index > 0) HorizontalDivider(color = Islet.stroke, modifier = Modifier.padding(start = 20.dp))
            Row(Modifier.fillMaxWidth().pressable(0.98f, onClick = need.fix).padding(horizontal = 20.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(need.title, style = Islet.body.copy(fontWeight = FontWeight.Medium))
                    Text(need.detail, style = Islet.caption)
                }
                Spacer(Modifier.width(12.dp))
                Text("Allow", color = Islet.blue, fontWeight = FontWeight.Medium)
            }
        }
    }
}

/** The Mac's song: artwork softly lit behind, a live position, big calm controls. */
@Composable
private fun NowPlaying(media: MacMedia, link: LinkManager) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(media.playing, media.stampMs) {
        while (media.playing) { now = System.currentTimeMillis(); delay(500) }
        now = System.currentTimeMillis()
    }
    val fraction = if (media.durationMs > 0) media.positionAt(now).toFloat() / media.durationMs else 0f
    Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(26.dp)).background(Islet.card).border(1.dp, Islet.stroke, RoundedCornerShape(26.dp))) {
        media.art?.let { art ->
            Image(art.asImageBitmap(), null, contentScale = ContentScale.Crop,
                  modifier = Modifier.matchParentSize().graphicsLayer { alpha = 0.55f }
                      .then(if (Build.VERSION.SDK_INT >= 31) Modifier.blur(70.dp) else Modifier))
            Box(Modifier.matchParentSize().background(Brush.verticalGradient(listOf(Islet.background.copy(alpha = 0.45f), Islet.background.copy(alpha = 0.82f)))))
        }
        Column(Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AnimatedContent(media.art, transitionSpec = { fadeIn(tween(350)) togetherWith fadeOut(tween(200)) }, label = "art") { art ->
                    Box(Modifier.size(84.dp).clip(RoundedCornerShape(16.dp)).background(Islet.cardHigh), contentAlignment = Alignment.Center) {
                        if (art != null) Image(art.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                        else Icon(Icons.Rounded.MusicNote, null, tint = Islet.secondary, modifier = Modifier.size(30.dp))
                    }
                }
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f)) {
                    Text(media.title, style = Islet.heading.copy(fontSize = 21.sp), maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(media.artist, style = Islet.body.copy(color = Islet.secondary), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (media.app.isNotBlank()) Text(media.app.uppercase(), style = Islet.label.copy(fontSize = 10.sp), modifier = Modifier.padding(top = 4.dp))
                }
            }
            Spacer(Modifier.height(14.dp))
            Scrubber(fraction, media.durationMs > 0, onSeek = { link.macCommand("seek", it * media.durationMs / 1000.0) })
            Row(Modifier.fillMaxWidth()) {
                Text(time((fraction * media.durationMs).toLong()), style = Islet.number.copy(fontSize = 11.sp))
                Spacer(Modifier.weight(1f))
                Text("-" + time(media.durationMs - (fraction * media.durationMs).toLong()), style = Islet.number.copy(fontSize = 11.sp))
            }
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                TransportButton(Icons.Rounded.SkipPrevious, "Previous") { link.macCommand("previous") }
                Box(Modifier.size(68.dp).pressable(0.92f) { link.macCommand("toggle") }.clip(CircleShape).background(Islet.fill),
                    contentAlignment = Alignment.Center) {
                    // The icon swaps with a quick fade and scale, so the change is seen, not snapped.
                    AnimatedContent(media.playing, transitionSpec = {
                        (fadeIn(tween(160)) + scaleIn(tween(200), initialScale = 0.7f)) togetherWith
                            (fadeOut(tween(100)) + scaleOut(tween(120), targetScale = 0.7f))
                    }, label = "play") { playing ->
                        Icon(if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                             if (playing) "Pause" else "Play", tint = Islet.background, modifier = Modifier.size(36.dp))
                    }
                }
                TransportButton(Icons.Rounded.SkipNext, "Next") { link.macCommand("next") }
            }
        }
    }
}

@Composable
private fun TransportButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(60.dp).pressable(0.86f, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = Islet.text, modifier = Modifier.size(36.dp))
    }
}

private fun time(ms: Long): String {
    val seconds = (ms.coerceAtLeast(0) / 1000).toInt()
    return "%d:%02d".format(seconds / 60, seconds % 60)
}

// MARK: Remote

private enum class RemoteMode(val label: String) { Trackpad("Trackpad"), Keyboard("Keyboard"), Slides("Slides") }

@Composable
fun RemoteScreen(link: LinkManager) {
    var mode by remember { mutableStateOf(RemoteMode.Trackpad) }
    DisposableEffect(mode) {
        MainActivity.slidesMode = mode == RemoteMode.Slides
        onDispose { MainActivity.slidesMode = false }
    }
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(start = 20.dp, end = 20.dp, bottom = 96.dp)) {
        ScreenTitle("Remote")
        LiquidSelector(RemoteMode.entries, mode.ordinal, { mode = RemoteMode.entries[it] },
                       Modifier.fillMaxWidth().padding(top = 10.dp).entrance(1), height = 50.dp, inset = 4.dp) { item, highlight ->
            Text(item.label, color = lerp(Islet.tertiary, Islet.text, highlight), fontWeight = FontWeight.Medium, fontSize = 14.sp)
        }
        Spacer(Modifier.height(16.dp))
        Box(Modifier.weight(1f).entrance(2)) {
            when (mode) {
                RemoteMode.Trackpad -> Trackpad(link)
                RemoteMode.Keyboard -> Keyboard(link)
                RemoteMode.Slides -> Slides(link)
            }
        }
    }
}

/**
 * One finger moves (faster swipes go further), a tap clicks, two fingers scroll, a
 * two-finger tap right-clicks, press-and-hold then move drags. A soft light follows
 * the finger so you can see where you're touching.
 */
@Composable
private fun Trackpad(link: LinkManager) {
    val view = LocalView.current
    val reduced = LocalReducedMotion.current
    val scope = rememberCoroutineScope()
    var touch by remember { mutableStateOf<Offset?>(null) }
    val glow = remember { Animatable(0f) }
    var hint by remember { mutableStateOf(true) }
    Column(Modifier.fillMaxSize()) {
        Box(
            Modifier.fillMaxWidth().weight(1f).clip(RoundedCornerShape(28.dp)).background(Islet.card)
                .border(1.dp, Islet.stroke, RoundedCornerShape(28.dp))
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val first = awaitFirstDown(requireUnconsumed = false)
                        hint = false
                        touch = first.position
                        scope.launch { if (reduced) glow.snapTo(1f) else glow.animateTo(1f, tween(140)) }
                        val start = System.currentTimeMillis()
                        var maxPointers = 1
                        var travelled = 0f
                        var dragging = false
                        var last = first.position
                        while (true) {
                            val event = awaitPointerEvent(PointerEventPass.Main)
                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.isEmpty()) break
                            maxPointers = maxOf(maxPointers, pressed.size)
                            touch = pressed.first().position
                            if (pressed.size >= 2) {
                                val dx = pressed.map { it.position.x - it.previousPosition.x }.average().toFloat()
                                val dy = pressed.map { it.position.y - it.previousPosition.y }.average().toFloat()
                                travelled += abs(dx) + abs(dy)
                                if (abs(dx) + abs(dy) > 0.5f) link.input("scroll", "dx" to dx * 1.6, "dy" to dy * 1.6)
                            } else {
                                val change = pressed.first()
                                val dx = change.position.x - last.x
                                val dy = change.position.y - last.y
                                last = change.position
                                travelled += abs(dx) + abs(dy)
                                if (!dragging && maxPointers == 1 && travelled < 12 && System.currentTimeMillis() - start > 450) {
                                    dragging = true
                                    Haptic.heavy(view)
                                    link.input("drag", "state" to "down")
                                }
                                val speed = sqrt(dx * dx + dy * dy)
                                val gain = 0.9f + (speed / 18f).coerceAtMost(2.2f)
                                if (speed > 0.2f) link.input("move", "dx" to (dx * gain).toDouble(), "dy" to (dy * gain).toDouble())
                            }
                            event.changes.forEach { it.consume() }
                        }
                        if (dragging) {
                            link.input("drag", "state" to "up")
                            Haptic.release(view)
                        } else if (travelled < 14 && System.currentTimeMillis() - start < 300) {
                            if (maxPointers >= 2) Haptic.heavy(view) else Haptic.press(view)
                            link.input("click", "button" to if (maxPointers >= 2) "right" else "left", "count" to 1)
                        }
                        scope.launch { if (reduced) glow.snapTo(0f) else glow.animateTo(0f, tween(260)) }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Canvas(Modifier.fillMaxSize()) {
                touch?.let { point ->
                    drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.14f * glow.value), Color.Transparent), point, 90.dp.toPx()),
                               90.dp.toPx(), point)
                }
            }
            androidx.compose.animation.AnimatedVisibility(hint, enter = fadeIn(), exit = fadeOut(tween(400))) {
                Text("Move  ·  tap to click  ·  two fingers to scroll\nTwo-finger tap to right-click  ·  hold to drag",
                     style = Islet.caption.copy(color = Islet.tertiary), textAlign = TextAlign.Center)
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button("Click", Modifier.weight(1f), primary = false) { link.input("click", "button" to "left", "count" to 1) }
            Button("Right Click", Modifier.weight(1f), primary = false) { link.input("click", "button" to "right", "count" to 1) }
        }
    }
}

/** Types as you go; special keys below, drawn like keycaps. */
@Composable
private fun Keyboard(link: LinkManager) {
    var text by remember { mutableStateOf("") }
    Column {
        TextField(
            value = text,
            onValueChange = { next ->
                when {
                    next.startsWith(text) -> next.removePrefix(text).takeIf { it.isNotEmpty() }?.let { link.input("text", "text" to it) }
                    text.startsWith(next) -> repeat(text.length - next.length) { link.input("key", "key" to "delete", "mods" to emptyList<String>()) }
                    else -> {
                        repeat(text.length) { link.input("key", "key" to "delete", "mods" to emptyList<String>()) }
                        link.input("text", "text" to next)
                    }
                }
                text = if (next.length > 200) "" else next
            },
            placeholder = { Text("Type on your Mac", color = Islet.tertiary) },
            modifier = Modifier.fillMaxWidth().border(1.dp, Islet.stroke, RoundedCornerShape(18.dp)),
            shape = RoundedCornerShape(18.dp),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = {
                link.input("key", "key" to "return", "mods" to emptyList<String>())
                text = ""
            }),
            colors = TextFieldDefaults.colors(focusedContainerColor = Islet.card, unfocusedContainerColor = Islet.card,
                                              focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                                              cursorColor = Islet.text),
        )
        SectionTitle("Keys")
        val keys = listOf(
            "esc" to ("escape" to emptyList()), "tab" to ("tab" to emptyList()), "⌫" to ("delete" to emptyList()), "⏎" to ("return" to emptyList()),
            "←" to ("left" to emptyList()), "↑" to ("up" to emptyList()), "↓" to ("down" to emptyList()), "→" to ("right" to emptyList()),
            "⌘C" to ("c" to listOf("cmd")), "⌘V" to ("v" to listOf("cmd")), "⌘Z" to ("z" to listOf("cmd")), "⌘A" to ("a" to listOf("cmd")),
            "⌘⇥" to ("tab" to listOf("cmd")), "⌘␣" to ("space" to listOf("cmd")), "⌘W" to ("w" to listOf("cmd")), "⌘Q" to ("q" to listOf("cmd")),
        )
        keys.chunked(4).forEach { row ->
            Row(Modifier.fillMaxWidth().padding(bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { (label, key) ->
                    Box(Modifier.weight(1f).height(54.dp)
                        .pressable(0.92f) { link.input("key", "key" to key.first, "mods" to key.second) }
                        .clip(RoundedCornerShape(12.dp)).background(Islet.cardHigh)
                        .border(1.dp, Islet.stroke, RoundedCornerShape(12.dp)),
                        contentAlignment = Alignment.Center) {
                        Text(label, fontFamily = Islet.mono, color = Islet.text, fontSize = 16.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun Slides(link: LinkManager) {
    fun key(name: String) = link.input("key", "key" to name, "mods" to emptyList<String>())
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.fillMaxWidth().weight(1f).pressable(0.98f) { key("right") }.clip(RoundedCornerShape(28.dp)).background(Islet.fill),
            contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.AutoMirrored.Rounded.ArrowForward, null, tint = Islet.background, modifier = Modifier.size(56.dp))
                Text("Next", style = Islet.heading.copy(color = Islet.background))
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.weight(1f).height(92.dp).pressable(0.96f) { key("left") }.clip(RoundedCornerShape(24.dp)).background(Islet.cardHigh)
                .border(1.dp, Islet.stroke, RoundedCornerShape(24.dp)), contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Previous", tint = Islet.text, modifier = Modifier.size(34.dp))
            }
            Box(Modifier.weight(1f).height(92.dp).pressable(0.96f) { key("escape") }.clip(RoundedCornerShape(24.dp)).background(Islet.cardHigh)
                .border(1.dp, Islet.stroke, RoundedCornerShape(24.dp)), contentAlignment = Alignment.Center) {
                Text("End", style = Islet.body.copy(fontWeight = FontWeight.Medium))
            }
        }
        Text("The volume buttons change slides too.", style = Islet.caption.copy(color = Islet.tertiary),
             textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
}

// MARK: Files

@Composable
fun FilesScreen(link: LinkManager) {
    val context = LocalContext.current
    val transfer by link.transfer.collectAsStateWithLifecycle()
    val state by link.state.collectAsStateWithLifecycle()
    fun sent(count: Int) {
        Toast.makeText(context, if (count > 0) "Sending $count to your Mac" else "Not connected to your Mac", Toast.LENGTH_SHORT).show()
    }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(50)) { uris ->
        if (uris.isNotEmpty()) sent(Features.sendUris(context, uris))
    }
    val documents = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) sent(Features.sendUris(context, uris))
    }
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = screenPadding) {
        item { ScreenTitle("Files", "Originals, byte for byte. Nothing is compressed.") }
        item {
            Row(Modifier.padding(top = 18.dp).entrance(1), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FileTile(Icons.Rounded.PhotoLibrary, "Photos and videos", Modifier.weight(1f)) {
                    photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                }
                FileTile(Icons.Rounded.Description, "Files", Modifier.weight(1f)) { documents.launch(arrayOf("*/*")) }
            }
        }
        item {
            AnimatedVisibility(transfer != null, enter = fadeIn(tween(250)), exit = fadeOut(tween(200))) {
                transfer?.let { current ->
                    val progress = if (current.total > 0) current.done.toFloat() / current.total else 0f
                    Card(Modifier.fillMaxWidth().padding(top = 14.dp)) {
                        Text(if (current.incoming) "Receiving from your Mac" else "Sending to your Mac", style = Islet.caption)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(current.name, style = Islet.body.copy(fontWeight = FontWeight.Medium), maxLines = 1,
                                 overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Text("${(progress * 100).toInt()}%", style = Islet.number)
                        }
                        Spacer(Modifier.height(12.dp))
                        Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.1f))) {
                            Box(Modifier.fillMaxWidth(progress).height(4.dp).clip(CircleShape).background(Islet.fill))
                        }
                    }
                }
            }
        }
        item {
            SectionTitle("How it works", Modifier.entrance(2))
            Card(Modifier.fillMaxWidth().entrance(2), padding = 0.dp) {
                val lines = listOf(
                    "Share anything to Islet from any app's Share menu.",
                    "On the Mac, drag files to the screen's right edge, or use the phone page in the island.",
                    "Files from your Mac land in Pictures, Movies or Download, in an Islet folder.",
                    if ((state as? LinkState.Connected)?.transport == Transport.BLUETOOTH)
                        "You're on Bluetooth right now. Big files are much faster over Wi-Fi or USB."
                    else "USB is fastest, then Wi-Fi. Bluetooth is fine for small things.",
                )
                lines.forEachIndexed { index, line ->
                    if (index > 0) HorizontalDivider(color = Islet.stroke, modifier = Modifier.padding(start = 52.dp))
                    Row(Modifier.padding(horizontal = 20.dp, vertical = 14.dp)) {
                        Icon(Icons.Rounded.Check, null, tint = Islet.secondary, modifier = Modifier.size(18.dp).offset(y = 2.dp))
                        Spacer(Modifier.width(14.dp))
                        Text(line, style = Islet.body.copy(fontSize = 15.sp, color = Islet.secondary))
                    }
                }
            }
        }
    }
}

@Composable
private fun FileTile(icon: ImageVector, label: String, modifier: Modifier, onClick: () -> Unit) {
    Column(
        modifier.aspectRatio(0.95f).pressable(0.96f, onClick = onClick).clip(RoundedCornerShape(24.dp)).background(Islet.card)
            .border(1.dp, Islet.stroke, RoundedCornerShape(24.dp)).padding(20.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Icon(icon, null, tint = Islet.text, modifier = Modifier.size(30.dp))
        Text(label, style = Islet.heading.copy(fontSize = 20.sp))
    }
}

// MARK: Settings

@Composable
fun SettingsScreen(link: LinkManager) {
    val context = LocalContext.current
    val state by link.state.collectAsStateWithLifecycle()
    val prefs = remember { Features.prefs(context) }
    var notifications by remember { mutableStateOf(prefs.getBoolean("notifications", true)) }
    var media by remember { mutableStateOf(prefs.getBoolean("media", true)) }
    var clipboard by remember { mutableStateOf(prefs.getBoolean("clipboard", true)) }
    var bluetooth by remember { mutableStateOf(prefs.getBoolean("bluetooth", true)) }
    var showApps by remember { mutableStateOf(false) }
    var muted by remember { mutableStateOf(Features.muted(context)) }
    val needs = rememberNeeds()

    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = screenPadding) {
        item { ScreenTitle("Settings") }
        item {
            SectionTitle("Dynamic Dot", Modifier.entrance(1))
            local.islet.link.dot.DotCard(Modifier.entrance(1))
        }
        item {
            SectionTitle("Your Mac", Modifier.entrance(1))
            Card(Modifier.fillMaxWidth().entrance(1)) {
                Text(link.pairedMacName, style = Islet.heading)
                Text(when (val current = state) {
                    is LinkState.Connected -> "Connected over ${current.transport.label}"
                    else -> "Not connected"
                }, style = Islet.caption)
                Spacer(Modifier.height(16.dp))
                Button("Forget This Mac", primary = false) { link.forget() }
            }
        }
        item {
            SectionTitle("Sharing", Modifier.entrance(2))
            Card(Modifier.fillMaxWidth().entrance(2), padding = 0.dp) {
                Column(Modifier.padding(horizontal = 20.dp)) {
                    ToggleRow("Notifications on the Mac", "Reply from the island; answer or decline calls", notifications) {
                        notifications = it; prefs.edit().putBoolean("notifications", it).apply()
                    }
                    HorizontalDivider(color = Islet.stroke)
                    ToggleRow("Phone music on the Mac", "Control what plays here from the island", media) {
                        media = it; prefs.edit().putBoolean("media", it).apply()
                    }
                    HorizontalDivider(color = Islet.stroke)
                    ToggleRow("Shared clipboard", "What you copy on the Mac is ready to paste here", clipboard) {
                        clipboard = it; prefs.edit().putBoolean("clipboard", it).apply()
                    }
                    HorizontalDivider(color = Islet.stroke)
                    ToggleRow("Bluetooth when there's no Wi-Fi", "Slower, but keeps notifications and music going", bluetooth) {
                        bluetooth = it; prefs.edit().putBoolean("bluetooth", it).apply()
                    }
                }
            }
        }
        item {
            SectionTitle("Apps that can notify your Mac", Modifier.entrance(3))
            Card(Modifier.fillMaxWidth().entrance(3), padding = 0.dp) {
                Column(Modifier.padding(horizontal = 20.dp)) {
                    val apps = Features.seenApps(context)
                    if (apps.isEmpty()) Text("Apps appear here once they post a notification.", style = Islet.caption, modifier = Modifier.padding(vertical = 16.dp))
                    (if (showApps) apps else apps.take(5)).forEachIndexed { index, pkg ->
                        if (index > 0) HorizontalDivider(color = Islet.stroke)
                        ToggleRow(Features.appName(context, pkg), null, pkg !in muted) { on ->
                            Features.setMuted(context, pkg, !on)
                            muted = Features.muted(context)
                        }
                    }
                    if (apps.size > 5) {
                        Text(if (showApps) "Show fewer" else "Show all ${apps.size}", color = Islet.blue, fontWeight = FontWeight.Medium,
                             modifier = Modifier.pressable { showApps = !showApps }.padding(vertical = 16.dp))
                    }
                }
            }
        }
        item {
            SectionTitle("Permissions", Modifier.entrance(4))
            Card(Modifier.fillMaxWidth().entrance(4), padding = 0.dp) {
                needs.forEachIndexed { index, need ->
                    if (index > 0) HorizontalDivider(color = Islet.stroke, modifier = Modifier.padding(start = 20.dp))
                    Row(Modifier.fillMaxWidth().pressable(0.98f, onClick = need.fix).padding(horizontal = 20.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(need.title, style = Islet.body)
                            Text(need.detail, style = Islet.caption)
                        }
                        Spacer(Modifier.width(12.dp))
                        if (need.granted) Icon(Icons.Rounded.Check, "Allowed", tint = Islet.green, modifier = Modifier.size(20.dp))
                        else Text("Allow", color = Islet.blue, fontWeight = FontWeight.Medium)
                    }
                }
            }
        }
        item {
            SectionTitle("About", Modifier.entrance(5))
            Text("Everything stays between your phone and your Mac, encrypted end to end. No accounts, no cloud.",
                 style = Islet.caption, modifier = Modifier.padding(horizontal = 4.dp).entrance(5))
        }
    }
}
