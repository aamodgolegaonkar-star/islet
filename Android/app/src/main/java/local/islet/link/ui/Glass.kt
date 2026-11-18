package local.islet.link.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.tanh
import kotlinx.coroutines.launch

/**
 * A row of choices with a glass lens over the chosen one, like iOS 26's tab bar. Tap to
 * jump, or press and slide: the lens follows the finger, stretches with speed, ticks as it
 * crosses each choice, and settles on release with a soft spring (flicks carry it on).
 */
@Composable
fun <T> LiquidSelector(
    items: List<T>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    height: Dp = 64.dp,
    inset: Dp = 6.dp,
    content: @Composable (item: T, highlight: Float) -> Unit,
) {
    val view = LocalView.current
    val reduced = LocalReducedMotion.current
    val scope = rememberCoroutineScope()
    val lens = remember { Animatable(selected.toFloat()) }
    val stretch = remember { Animatable(1f) }
    val lift = remember { Animatable(1f) }
    var dragging by remember { mutableStateOf(false) }
    val select by rememberUpdatedState(onSelect)
    val current by rememberUpdatedState(selected)

    LaunchedEffect(selected) {
        if (!dragging) { if (reduced) lens.snapTo(selected.toFloat()) else lens.animateTo(selected.toFloat(), Motion.lens()) }
    }

    BoxWithConstraints(modifier.height(height).glass(CircleShape).padding(inset)) {
        val density = LocalDensity.current
        val widthPx = with(density) { maxWidth.toPx() }
        val segment = widthPx / items.size
        val last = items.size - 1f

        // The lens.
        Box(
            Modifier
                .width(maxWidth / items.size)
                .fillMaxHeight()
                .graphicsLayer {
                    translationX = lens.value * segment
                    scaleX = lift.value * stretch.value
                    scaleY = lift.value * (2f - stretch.value).coerceIn(0.9f, 1f)
                }
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.12f))
                .border(1.dp, androidx.compose.ui.graphics.Brush.verticalGradient(
                    listOf(Color.White.copy(alpha = 0.32f), Color.White.copy(alpha = 0.06f))), CircleShape),
        )

        Row(
            Modifier.fillMaxSize().pointerInput(items.size) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    val tracker = VelocityTracker()
                    tracker.addPosition(down.uptimeMillis, down.position)
                    var moved = false
                    var lastIndex = current
                    if (!reduced) scope.launch { lift.animateTo(1.08f, Motion.press()) }
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                        tracker.addPosition(change.uptimeMillis, change.position)
                        if (!moved && abs(change.position.x - down.position.x) > viewConfiguration.touchSlop) {
                            moved = true
                            dragging = true
                            Haptic.gestureStart(view)
                        }
                        if (moved) {
                            val target = (change.position.x / segment - 0.5f).coerceIn(-0.3f, last + 0.3f)
                            val speed = tracker.calculateVelocity().x / segment
                            scope.launch {
                                lens.snapTo(target)
                                if (!reduced) stretch.snapTo(1f + (abs(speed) / 14f).coerceAtMost(0.22f))
                            }
                            val index = target.roundToInt().coerceIn(0, items.size - 1)
                            if (index != lastIndex) { Haptic.tick(view); lastIndex = index }
                            change.consume()
                        }
                    }
                    val velocity = tracker.calculateVelocity().x / segment
                    val final = if (moved) (lens.value + velocity * 0.12f).roundToInt().coerceIn(0, items.size - 1)
                                else (down.position.x / segment).toInt().coerceIn(0, items.size - 1)
                    dragging = false
                    if (final != current) { Haptic.step(view); select(final) } else Haptic.release(view)
                    scope.launch {
                        if (reduced) lens.snapTo(final.toFloat())
                        else lens.animateTo(final.toFloat(), Motion.lens(), initialVelocity = velocity)
                    }
                    scope.launch { stretch.animateTo(1f, Motion.lens()) }
                    scope.launch { lift.animateTo(1f, Motion.lens()) }
                }
            },
        ) {
            items.forEachIndexed { index, item ->
                val highlight = (1f - abs(lens.value - index)).coerceIn(0f, 1f)
                Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) { content(item, highlight) }
            }
        }
    }
}

/**
 * Volume or brightness, like Control Center: a thick bar you drag anywhere (it moves by
 * how far you slide, not where you touch). It swells a touch while held, rubber-bands
 * past either end, and ticks every sixteenth with a firmer bump at 0 and 100 %.
 */
@Composable
fun LevelControl(
    value: Float,
    enabled: Boolean,
    icon: (Float) -> ImageVector,
    description: String,
    onChange: (Float) -> Unit,
) {
    val view = LocalView.current
    val reduced = LocalReducedMotion.current
    val scope = rememberCoroutineScope()
    var held by remember { mutableStateOf(false) }
    var local by remember { mutableFloatStateOf(value) }
    val stretch = remember { Animatable(0f) }
    val shown = if (held) local else value
    val fill by animateFloatAsState(shown, if (held || reduced) snap() else Motion.gentle(), label = "level")
    val swell by animateFloatAsState(if (held) 1f else 0f, if (reduced) snap() else Motion.press(), label = "swell")
    val change by rememberUpdatedState(onChange)

    Box(
        Modifier
            .fillMaxWidth()
            .height(58.dp)
            .graphicsLayer {
                val over = stretch.value
                scaleX = 1f + abs(over) * 0.05f + swell * 0.015f
                scaleY = 1f - abs(over) * 0.04f + swell * 0.04f
                transformOrigin = TransformOrigin(if (over < 0) 1f else if (over > 0) 0f else 0.5f, 0.5f)
                alpha = if (enabled) 1f else 0.45f
            }
            .clip(RoundedCornerShape(19.dp))
            .background(Islet.cardHigh)
            .drawBehind {
                drawRoundRect(Islet.fill, size = Size(size.width * fill.coerceIn(0f, 1f), size.height), cornerRadius = CornerRadius(0f))
            }
            .border(1.dp, Islet.stroke, RoundedCornerShape(19.dp))
            .semantics {
                contentDescription = description
                progressBarRangeInfo = androidx.compose.ui.semantics.ProgressBarRangeInfo(shown, 0f..1f)
                setProgress { target -> change(target.coerceIn(0f, 1f)); true }
            }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                awaitEachGesture {
                    val down = awaitFirstDown()
                    held = true
                    local = value
                    var raw = value
                    var lastStep = (value * 16).toInt()
                    Haptic.gestureStart(view)
                    while (true) {
                        val event = awaitPointerEvent()
                        val pointer = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!pointer.pressed) break
                        raw += (pointer.position.x - pointer.previousPosition.x) / size.width
                        val clamped = raw.coerceIn(0f, 1f)
                        val over = raw - clamped
                        scope.launch { stretch.snapTo(if (reduced) 0f else tanh(over * 4f)) }
                        if (clamped != local) {
                            val step = (clamped * 16).toInt()
                            if ((clamped == 0f || clamped == 1f) && local != clamped) Haptic.edge(view)
                            else if (step != lastStep) Haptic.tick(view)
                            lastStep = step
                            local = clamped
                            change(clamped)
                        }
                        // Keep the overshoot bounded so reversing direction responds at once.
                        raw = raw.coerceIn(-0.25f, 1.25f)
                        pointer.consume()
                    }
                    held = false
                    Haptic.release(view)
                    scope.launch { stretch.animateTo(0f, Motion.lens()) }
                }
            },
    ) {
        Row(Modifier.fillMaxSize().padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon(shown), null, tint = if (fill > 0.08f) Islet.background else Islet.text, modifier = Modifier.size(22.dp))
            Spacer(Modifier.weight(1f))
            Text("${(shown * 100).roundToInt()}", style = Islet.number,
                 color = if (fill > 0.9f) Islet.background else Islet.secondary,
                 modifier = Modifier.graphicsLayer { alpha = 0.55f + swell * 0.45f })
        }
    }
}

/**
 * The song's position. A hairline at rest; under the finger it thickens and follows it,
 * then seeks once on release (one command, not a stream of them).
 */
@Composable
fun Scrubber(fraction: Float, enabled: Boolean, onSeek: (Float) -> Unit, modifier: Modifier = Modifier) {
    val view = LocalView.current
    val reduced = LocalReducedMotion.current
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    val thick by animateFloatAsState(if (scrubbing != null) 1f else 0f, if (reduced) snap() else Motion.press(), label = "thick")
    val seek by rememberUpdatedState(onSeek)
    Box(
        modifier
            .fillMaxWidth()
            .height(32.dp)
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                awaitEachGesture {
                    val down = awaitFirstDown()
                    scrubbing = (down.position.x / size.width).coerceIn(0f, 1f)
                    Haptic.gestureStart(view)
                    while (true) {
                        val event = awaitPointerEvent()
                        val pointer = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!pointer.pressed) break
                        scrubbing = (pointer.position.x / size.width).coerceIn(0f, 1f)
                        pointer.consume()
                    }
                    scrubbing?.let { seek(it) }
                    scrubbing = null
                    Haptic.release(view)
                }
            }
            .drawBehind {
                val height = (4.dp.toPx() + thick * 6.dp.toPx())
                val top = (size.height - height) / 2
                val value = (scrubbing ?: fraction).coerceIn(0f, 1f)
                drawRoundRect(Color.White.copy(alpha = 0.18f), Offset(0f, top), Size(size.width, height), CornerRadius(height / 2))
                drawRoundRect(Color.White.copy(alpha = 0.92f), Offset(0f, top), Size(size.width * value, height), CornerRadius(height / 2))
            },
    )
}
