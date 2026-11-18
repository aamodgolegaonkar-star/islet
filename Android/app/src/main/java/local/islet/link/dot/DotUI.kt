package local.islet.link.dot

import android.os.SystemClock
import android.provider.Settings
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.EnterExitState
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.animateDp
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.CallEnd
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.BlurredEdgeTreatment
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.max
import androidx.compose.ui.unit.min
import androidx.compose.ui.unit.sp
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.roundToInt
import kotlin.math.sign
import kotlin.random.Random
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import local.islet.link.features.PhoneMedia
import local.islet.link.ui.Haptic
import local.islet.link.ui.Islet
import local.islet.link.ui.LocalReducedMotion
import local.islet.link.ui.Motion
import local.islet.link.ui.pressable

/** What the dot is doing; [rank] orders sizes, so growing and shrinking get their own springs. */
private enum class Scene(val rank: Int) { Hidden(0), Preview(1), Music(1), Alert(2), Charging(2), Call(2), MusicOpen(3), CallOpen(3) }

/** Where the black shape sits, in dp; [shift] moves it off the camera's centre when the camera is near an edge. */
private data class Frame(val width: Dp, val height: Dp, val top: Dp, val shift: Dp, val radius: Dp, val contentTop: Dp)

private val Answer = Color(0xFF3FBF5F)
private val Decline = Color(0xFFEB5545)
private val Charge = Color(0xFF6FD08C)
private val Raised = Color(0xFF262624)

private fun frameFor(scene: Scene, g: DotService.Geometry, tune: DotFeed.Tune): Frame {
    val d = g.density
    val hole = (g.holeSize / d).dp
    val holeTop = (g.holeTop / d).dp
    val holeX = (g.holeX / d).dp
    val screen = (g.screenWidth / d).dp
    val compact = max(hole + 16.dp, 34.dp) * tune.heightScale
    val top = max(holeTop + hole / 2 - compact / 2, 4.dp) + tune.offsetY.dp
    // Open layouts start below the camera.
    val contentTop = max(20.dp, holeTop + hole - top + 10.dp)
    fun at(width: Dp, height: Dp, radius: Dp = height / 2): Frame {
        val half = width / 2
        val low = half + 8.dp
        val high = screen - half - 8.dp
        val center = if (low <= high) (holeX + tune.offsetX.dp).coerceIn(low, high) else screen / 2
        return Frame(width, height, top, center - holeX, radius, contentTop)
    }
    val wide = min(screen - 16.dp, 380.dp * tune.widthScale)
    val open = min(screen - 16.dp, 420.dp)
    return when (scene) {
        Scene.Hidden -> Frame(hole, hole, holeTop + tune.offsetY.dp, tune.offsetX.dp, hole / 2, contentTop)
        Scene.Music, Scene.Preview -> at(min(screen - 16.dp, max(168.dp, hole + 128.dp) * tune.widthScale), compact)
        Scene.Alert, Scene.Charging, Scene.Call -> at(wide, compact)
        Scene.MusicOpen -> at(open, contentTop + 176.dp, 40.dp)
        Scene.CallOpen -> at(open, contentTop + 158.dp, 40.dp)
    }
}

/** The rounded shape, drawn inside a window a little larger than it. */
private class PillShape(val width: Float, val height: Float, val top: Float, val center: Float, val radius: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val left = center - width / 2
        return Outline.Rounded(RoundRect(left, top, left + width, top + height, CornerRadius(radius.coerceAtMost(height / 2))))
    }
}

@Composable
fun DynamicDot(service: DotService) {
    val geometry by service.geometry.collectAsState()
    val g = geometry ?: return
    val media by DotFeed.media.collectAsState()
    val alert by DotFeed.alert.collectAsState()
    val call by DotFeed.call.collectAsState()
    val foreground by service.foreground.collectAsState()
    val screenOn by service.screenOn.collectAsState()
    val charge by service.charge.collectAsState()
    val tune by DotFeed.tune.collectAsState()
    val previewStamp by DotFeed.preview.collectAsState()
    var previewing by remember { mutableStateOf(false) }
    LaunchedEffect(previewStamp) {
        val left = previewStamp + 2_500 - SystemClock.uptimeMillis()
        previewing = previewStamp > 0 && left > 0
        if (previewing) { delay(left); previewing = false }
    }
    val context = LocalContext.current
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    val reduced = remember { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }

    var expanded by remember { mutableStateOf(false) }
    var poke by remember { mutableIntStateOf(0) }
    var shownAlert by remember { mutableStateOf<DotFeed.Alert?>(null) }
    var shownCharge by remember { mutableStateOf<DotService.Charge?>(null) }
    var musicAsleep by remember { mutableStateOf(false) }

    LaunchedEffect(alert) {
        shownAlert = alert
        if (alert != null) { expanded = false; delay(4_500); shownAlert = null }
    }
    LaunchedEffect(charge) {
        shownCharge = charge
        if (charge != null) { delay(2_800); shownCharge = null }
    }
    // Paused music stays a while, like Apple Music's Live Activity, then the dot rests.
    LaunchedEffect(media?.playing, media?.title) {
        musicAsleep = false
        if (media?.playing == false) { delay(90_000); musicAsleep = true }
    }
    LaunchedEffect(call == null) { expanded = false }
    LaunchedEffect(Unit) { service.outside.collect { expanded = false } }
    LaunchedEffect(expanded, poke) { if (expanded) { delay(9_000); expanded = false } }

    // Leaving the app that's playing (or the call screen) sends it into the dot, like on iPhone:
    // its art shrinks up into the camera and the dot swells as it takes it in.
    var absorb by remember { mutableStateOf<Absorb?>(null) }
    val swell = remember { Animatable(0f) }
    val left = remember { object { var pkg: String? = null } }
    LaunchedEffect(foreground) {
        val from = left.pkg
        left.pkg = foreground
        if (reduced || g.landscape || from == null || foreground == null || from == foreground || !screenOn) return@LaunchedEffect
        val c = call
        val m = media
        absorb = when {
            c != null && from == c.pkg -> Absorb(c.icon, round = true)
            m != null && from == m.pkg && !musicAsleep -> Absorb(m.art, round = false)
            else -> return@LaunchedEffect
        }
        launch { delay(300); swell.animateTo(1f, tween(110)); swell.animateTo(0f, spring(0.42f, 360f)) }
    }

    val showMusic = media != null && !musicAsleep && foreground != media?.pkg
    val scene = when {
        g.landscape -> Scene.Hidden
        call != null -> if (expanded) Scene.CallOpen else Scene.Call
        shownAlert != null -> Scene.Alert
        shownCharge != null -> Scene.Charging
        showMusic -> if (expanded) Scene.MusicOpen else Scene.Music
        previewing -> Scene.Preview
        else -> Scene.Hidden
    }

    val target = frameFor(scene, g, tune)
    val holeX = (g.holeX / g.density).dp
    val last = remember { object { var scene = Scene.Hidden } }
    val growing = scene.rank >= last.scene.rank
    SideEffect { last.scene = scene }
    // Growing overshoots a touch, like the island; shrinking settles without a bounce.
    val spec: AnimationSpec<Float> = when {
        reduced -> snap()
        growing -> spring(dampingRatio = 0.72f, stiffness = 340f)
        else -> spring(dampingRatio = 0.9f, stiffness = 520f)
    }
    val width by animateFloatAsState(target.width.value, spec, label = "w")
    val height by animateFloatAsState(target.height.value, spec, label = "h")
    val top by animateFloatAsState(target.top.value, spec, label = "top")
    val shift by animateFloatAsState(target.shift.value, spec, label = "shift")
    val radius by animateFloatAsState(target.radius.value, spec, label = "r")
    // Into the camera first, then gone; out of nowhere quickly.
    val shown by animateFloatAsState(if (scene == Scene.Hidden) 0f else 1f,
        if (reduced) tween(120) else if (scene == Scene.Hidden) tween(160, delayMillis = 140) else tween(90), label = "shown")
    val pull = remember { Animatable(0f) }

    // Drawing happens in a window that never moves; it's only shrunk while nothing shows.
    // Touches go to an invisible window sized to where the dot is going.
    LaunchedEffect(scene == Scene.Hidden && absorb == null, g, tune) {
        fun px(dp: Dp) = (dp.value * g.density).roundToInt()
        val open = maxOf(frameFor(Scene.MusicOpen, g, tune).let { it.top + it.height }, frameFor(Scene.CallOpen, g, tune).let { it.top + it.height })
        if (scene == Scene.Hidden && absorb == null) { delay(700); service.canvas(px(frameFor(Scene.Hidden, g, tune).let { it.top + it.height } + 4.dp)) }
        else service.canvas(px(maxOf(open, Absorb.START + Absorb.SIZE / 2) + 28.dp))
    }
    LaunchedEffect(target, scene, absorb) {
        fun px(dp: Dp) = (dp.value * g.density).roundToInt()
        val left = px(holeX + target.shift - target.width / 2 - 2.dp)
        service.touch(android.graphics.Rect(left, px(target.top - 2.dp), left + px(target.width + 4.dp), px(target.top + target.height + 4.dp)),
                      scene != Scene.Hidden && absorb == null)
    }

    fun tap(s: Scene) {
        when (s) {
            Scene.Music, Scene.Call -> expanded = true
            Scene.Alert -> { DotFeed.open(context, shownAlert?.open); shownAlert = null }
            Scene.Charging -> shownCharge = null
            Scene.MusicOpen, Scene.CallOpen -> poke++
            Scene.Hidden, Scene.Preview -> Unit
        }
    }

    fun swipe(s: Scene, distance: Float) {
        when {
            distance > 28f && (s == Scene.Music || s == Scene.Call) -> { Haptic.step(view); expanded = true }
            distance < -20f -> when (s) {
                Scene.MusicOpen, Scene.CallOpen -> { Haptic.step(view); expanded = false }
                Scene.Alert -> shownAlert = null
                Scene.Charging -> shownCharge = null
                else -> Unit
            }
        }
    }

    CompositionLocalProvider(LocalReducedMotion provides reduced) {
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer {
                    // Read here, these animate the shape in the draw phase only: nothing re-lays out per frame.
                    val stretch = rubber(pull.value)
                    val gulp = swell.value
                    alpha = shown
                    clip = true
                    shape = PillShape(
                        (width + maxOf(stretch, 0f) * 0.4f + gulp * 22f).dp.toPx(), (height + stretch * 0.6f + gulp * 7f).coerceAtLeast(4f).dp.toPx(),
                        (top - gulp * 1.5f).dp.toPx(), holeX.toPx() + shift.dp.toPx(), (radius + gulp * 3.5f).dp.toPx(),
                    )
                }
                .background(Color.Black)
        ) {
            AnimatedContent(
                targetState = scene,
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.TopStart,
                transitionSpec = {
                    val origin = TransformOrigin(g.holeX.toFloat() / g.screenWidth, 0f)
                    if (reduced) fadeIn(tween(140)) togetherWith fadeOut(tween(90)) using null
                    else (fadeIn(tween(230, delayMillis = 90, easing = Motion.easeOutExpo)) +
                        scaleIn(tween(340, delayMillis = 50, easing = Motion.easeOutExpo), initialScale = 0.94f, transformOrigin = origin)) togetherWith
                        (fadeOut(tween(90)) + scaleOut(tween(140), targetScale = 0.97f, transformOrigin = origin)) using null
                },
                label = "dot",
            ) { s ->
                val f = frameFor(s, g, tune)
                val blur by transition.animateDp({ tween(260, easing = Motion.easeOutExpo) }, label = "blur") {
                    if (it == EnterExitState.Visible || reduced) 0.dp else 6.dp
                }
                Box(Modifier.fillMaxSize()) {
                    Box(
                        Modifier
                            .offset(holeX + f.shift - f.width / 2, f.top)
                            .size(f.width, f.height)
                            .then(if (blur > 0.2.dp) Modifier.blur(blur, BlurredEdgeTreatment.Unbounded) else Modifier)
                            .pointerInput(s) {
                                detectTapGestures(
                                    onTap = { tap(s) },
                                    onLongPress = {
                                        if (s == Scene.Music || s == Scene.MusicOpen) {
                                            Haptic.heavy(view)
                                            DotFeed.open(context, media?.open)
                                            expanded = false
                                        }
                                    },
                                )
                            }
                            .pointerInput(s) {
                                var total = 0f
                                detectVerticalDragGestures(
                                    onDragStart = { total = 0f },
                                    onDragEnd = {
                                        swipe(s, total / density)
                                        scope.launch { pull.animateTo(0f, if (reduced) snap() else spring(0.6f, 500f)) }
                                    },
                                    onDragCancel = { scope.launch { pull.animateTo(0f) } },
                                ) { change, dy ->
                                    change.consume()
                                    total += dy
                                    scope.launch { pull.snapTo(total / density) }
                                }
                            },
                    ) {
                        when (s) {
                            Scene.Hidden, Scene.Preview -> Unit
                            Scene.Music -> media?.let { m ->
                                AroundHole(f, g, left = { Art(m.art, f.height - 12.dp, 7.dp) },
                                    right = { Bars(m.playing, Color(m.tint), screenOn, reduced) })
                            }
                            Scene.MusicOpen -> media?.let { m -> MusicOpen(m, f, screenOn, reduced) { poke++ } }
                            Scene.Alert -> shownAlert?.let { a ->
                                AroundHole(f, g,
                                    left = {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            AppIcon(a.icon, 22.dp)
                                            Spacer(Modifier.width(8.dp))
                                            Text(a.title, style = small.copy(fontWeight = FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        }
                                    },
                                    right = { Text(a.text, style = small.copy(color = Islet.secondary), maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.End) })
                            }
                            Scene.Charging -> shownCharge?.let { c ->
                                AroundHole(f, g,
                                    left = {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Icon(Icons.Rounded.Bolt, null, tint = Charge, modifier = Modifier.size(16.dp))
                                            Spacer(Modifier.width(4.dp))
                                            Text("Charging", style = small)
                                        }
                                    },
                                    right = {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Text("${c.level}%", style = small.copy(color = Charge, fontFamily = Islet.mono))
                                            Spacer(Modifier.width(6.dp))
                                            BatteryGlyph(c.level, reduced)
                                        }
                                    })
                            }
                            Scene.Call -> call?.let { c ->
                                AroundHole(f, g,
                                    left = {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Box(Modifier.size(20.dp).background(Answer, CircleShape), contentAlignment = Alignment.Center) {
                                                Icon(Icons.Rounded.Call, null, tint = Color.Black, modifier = Modifier.size(12.dp))
                                            }
                                            Spacer(Modifier.width(8.dp))
                                            Text(c.name, style = small.copy(fontWeight = FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        }
                                    },
                                    right = { Text(rememberCallStatus(c, screenOn), style = small.copy(color = Answer, fontFamily = Islet.mono), maxLines = 1) })
                            }
                            Scene.CallOpen -> call?.let { c -> CallOpen(c, f) { index -> DotFeed.act(context, c.key, index); expanded = false } }
                        }
                    }
                }
            }
        }
        absorb?.let { a ->
            AbsorbFlight(a, target.top + target.height / 2, target.height - 10.dp, holeX + target.shift) { if (absorb === a) absorb = null }
        }
    }
}

/** An app on its way into the dot. */
private data class Absorb(val image: android.graphics.Bitmap?, val round: Boolean, val stamp: Long = System.nanoTime()) {
    companion object {
        val SIZE = 150.dp
        /** Where the flight starts: the centre of the art, from the top of the screen. */
        val START = 150.dp
    }
}

/** The art falls up into the camera, shrinking and rounding as it goes, and is gone as the dot swells. */
@Composable
private fun AbsorbFlight(absorb: Absorb, endCenter: Dp, endSize: Dp, centerX: Dp, done: () -> Unit) {
    val progress = remember(absorb) { Animatable(0f) }
    LaunchedEffect(absorb) {
        progress.animateTo(1f, tween(440, easing = androidx.compose.animation.core.CubicBezierEasing(0.4f, 0f, 0.2f, 1f)))
        done()
    }
    val image = remember(absorb) { absorb.image?.asImageBitmap() }
    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier
                .offset(x = centerX - Absorb.SIZE / 2)
                .size(Absorb.SIZE)
                .graphicsLayer {
                    val p = progress.value
                    val scale = 1f + (endSize / Absorb.SIZE - 1f) * p
                    scaleX = scale
                    scaleY = scale
                    translationY = (Absorb.START + (endCenter - Absorb.START) * p - Absorb.SIZE / 2).toPx()
                    alpha = when {
                        p < 0.1f -> p / 0.1f
                        p > 0.78f -> (1f - p) / 0.22f
                        else -> 1f
                    }
                    clip = true
                    shape = RoundedCornerShape(if (absorb.round) 50 else (18 + 32 * p).toInt())
                }
                .background(Raised),
            contentAlignment = Alignment.Center,
        ) {
            if (image != null) Image(image, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else Icon(Icons.Rounded.MusicNote, null, tint = Islet.secondary, modifier = Modifier.size(72.dp))
        }
    }
}

private val small = TextStyle(fontSize = 13.sp, color = Islet.text)

/** Drag gives way less the further it goes. */
private fun rubber(distance: Float): Float = sign(distance) * 26f * (1f - exp(-abs(distance) / 90f))

/** Compact layouts: one thing left of the camera, one thing right of it. */
@Composable
private fun AroundHole(f: Frame, g: DotService.Geometry, left: @Composable () -> Unit, right: @Composable () -> Unit) {
    val hole = (g.holeSize / g.density).dp
    val inset = (f.height - 22.dp) / 2
    // Moved away from the camera in Settings, there's no hole to leave room for.
    val around = abs(f.shift.value) < (f.width / 2 - hole / 2 - 12.dp).value
    val gap = if (around) hole + 16.dp else 12.dp
    val leftWidth = if (around) (f.width / 2 - f.shift - hole / 2 - 8.dp).coerceAtLeast(0.dp) else (f.width - gap) / 2
    Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(leftWidth).fillMaxHeight().padding(start = inset, end = 4.dp), contentAlignment = Alignment.CenterStart) { left() }
        Spacer(Modifier.width(gap))
        Box(Modifier.weight(1f).fillMaxHeight().padding(start = 4.dp, end = inset), contentAlignment = Alignment.CenterEnd) { right() }
    }
}

@Composable
private fun Art(art: android.graphics.Bitmap?, size: Dp, corner: Dp, modifier: Modifier = Modifier) {
    val image = remember(art) { art?.asImageBitmap() }
    Box(modifier.size(size).clip(RoundedCornerShape(corner)).background(Raised), contentAlignment = Alignment.Center) {
        if (image != null) Image(image, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Icon(Icons.Rounded.MusicNote, null, tint = Islet.secondary, modifier = Modifier.size(size * 0.5f))
    }
}

@Composable
private fun AppIcon(icon: android.graphics.Bitmap?, size: Dp) {
    val image = remember(icon) { icon?.asImageBitmap() }
    if (image != null) Image(image, null, Modifier.size(size).clip(CircleShape))
    else Box(Modifier.size(size).background(Raised, CircleShape))
}

/**
 * Apple Music's level bars, tinted from the art. They step at 12 frames a second (not the
 * screen's 120), easing toward new heights so the steps read as motion, and stop whenever
 * nothing is playing, the screen is off, or animations are off.
 */
@Composable
private fun Bars(playing: Boolean, color: Color, screenOn: Boolean, reduced: Boolean, modifier: Modifier = Modifier) {
    val levels = remember { floatArrayOf(0.45f, 0.8f, 0.6f, 0.35f) }
    var frame by remember { mutableIntStateOf(0) }
    val moving = playing && screenOn && !reduced
    LaunchedEffect(moving, playing) {
        if (!moving) {
            levels.fill(if (playing) 0.55f else 0.22f)
            frame++
            return@LaunchedEffect
        }
        val goals = FloatArray(levels.size)
        var step = 0
        while (true) {
            if (step % 4 == 0) for (i in goals.indices) goals[i] = 0.25f + Random.nextFloat() * 0.75f
            for (i in levels.indices) levels[i] += (goals[i] - levels[i]) * 0.45f
            frame++
            step++
            delay(83)
        }
    }
    Canvas(modifier.size(20.dp, 16.dp)) {
        @Suppress("UNUSED_EXPRESSION") frame
        val bar = size.width / 7f
        for (i in levels.indices) {
            val h = size.height * levels[i]
            drawRoundRect(color, Offset(i * 2 * bar, (size.height - h) / 2), Size(bar, h), CornerRadius(bar / 2))
        }
    }
}

@Composable
private fun BatteryGlyph(level: Int, reduced: Boolean) {
    val fill = remember { Animatable(if (reduced) level / 100f else 0f) }
    LaunchedEffect(level) { if (!reduced) fill.animateTo(level / 100f, tween(700, delayMillis = 120, easing = Motion.easeOutExpo)) }
    Canvas(Modifier.size(26.dp, 13.dp)) {
        val body = Size(size.width - 3.dp.toPx(), size.height)
        val r = CornerRadius(3.5.dp.toPx())
        drawRoundRect(Color.White.copy(alpha = 0.4f), size = body, cornerRadius = r, style = Stroke(1.dp.toPx()))
        drawRoundRect(Color.White.copy(alpha = 0.4f), Offset(body.width + 1.dp.toPx(), size.height * 0.32f), Size(2.dp.toPx(), size.height * 0.36f), CornerRadius(1.dp.toPx()))
        val inset = 2.dp.toPx()
        drawRoundRect(Charge, Offset(inset, inset), Size((body.width - inset * 2) * fill.value, body.height - inset * 2), CornerRadius(2.dp.toPx()))
    }
}

private fun callStatus(call: DotFeed.Call, now: Long = System.currentTimeMillis()): String {
    val since = call.since ?: return if (call.incoming) "Incoming" else "Call"
    val seconds = ((now - since) / 1000).coerceAtLeast(0)
    return "%d:%02d".format(seconds / 60, seconds % 60)
}

@Composable
private fun rememberCallStatus(call: DotFeed.Call, screenOn: Boolean = true): String {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(call.since, screenOn) {
        now = System.currentTimeMillis()
        while (call.since != null && screenOn) { delay(1000); now = System.currentTimeMillis() }
    }
    return callStatus(call, now)
}

@Composable
private fun MusicOpen(media: DotFeed.Media, f: Frame, screenOn: Boolean, reduced: Boolean, touched: () -> Unit) {
    val context = LocalContext.current
    Column(Modifier.fillMaxSize().padding(start = 22.dp, end = 22.dp, top = f.contentTop, bottom = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Art(media.art, 58.dp, 13.dp, Modifier.pressable(0.94f) { DotFeed.open(context, media.open) })
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(media.title, style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Islet.text), maxLines = 1,
                     modifier = if (reduced) Modifier else Modifier.basicMarquee(iterations = 1, initialDelayMillis = 1400))
                Text(media.artist, style = TextStyle(fontSize = 14.sp, color = Islet.secondary), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.width(10.dp))
            Bars(media.playing, Color(media.tint), screenOn, reduced)
        }
        Spacer(Modifier.height(14.dp))
        Progress(media, reduced) { touched() }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
            Control(Icons.Rounded.SkipPrevious, 30.dp, "Previous") { touched(); PhoneMedia.command("previous", 0.0) }
            Control(if (media.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, 42.dp, if (media.playing) "Pause" else "Play") {
                touched(); PhoneMedia.command("toggle", 0.0)
            }
            Control(Icons.Rounded.SkipNext, 30.dp, "Next") { touched(); PhoneMedia.command("next", 0.0) }
        }
    }
}

@Composable
private fun Control(icon: ImageVector, size: Dp, label: String, onClick: () -> Unit) {
    Box(Modifier.size(56.dp).clip(CircleShape).pressable(0.86f, onClick = onClick), contentAlignment = Alignment.Center) {
        Crossfade(icon, animationSpec = tween(140), label = label) { Icon(it, label, tint = Islet.text, modifier = Modifier.size(size)) }
    }
}

/** A thin line that thickens under the finger; time updates once a second while it plays. */
@Composable
private fun Progress(media: DotFeed.Media, reduced: Boolean, touched: () -> Unit) {
    val view = LocalView.current
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    LaunchedEffect(media.playing, media.updatedAt) {
        now = SystemClock.elapsedRealtime()
        while (media.playing) { delay(1000); now = SystemClock.elapsedRealtime() }
    }
    var scrub by remember { mutableStateOf<Float?>(null) }
    val duration = media.duration
    val position = media.positionAt(now)
    val fraction = scrub ?: if (duration > 0) position.toFloat() / duration else 0f
    val thick by animateFloatAsState(if (scrub != null) 1f else 0f, if (reduced) snap() else Motion.press(), label = "thick")
    val fillColor by animateColorAsState(if (scrub != null) Color.White else Islet.text.copy(alpha = 0.8f), tween(150), label = "fill")
    fun seek(to: Float) = PhoneMedia.command("seek", (to * duration) / 1000.0)
    Column {
        Box(
            Modifier
                .fillMaxWidth()
                .height(22.dp)
                .pointerInput(duration) {
                    if (duration <= 0) return@pointerInput
                    detectHorizontalDragGestures(
                        onDragStart = { touched(); Haptic.gestureStart(view); scrub = (it.x / size.width).coerceIn(0f, 1f) },
                        onDragEnd = { scrub?.let { seek(it) }; scrub = null },
                        onDragCancel = { scrub = null },
                    ) { change, _ ->
                        change.consume()
                        scrub = (change.position.x / size.width).coerceIn(0f, 1f)
                    }
                }
                .pointerInput(duration) {
                    if (duration <= 0) return@pointerInput
                    detectTapGestures { touched(); Haptic.tick(view); seek((it.x / size.width).coerceIn(0f, 1f)) }
                }
                .drawBehind {
                    val line = (4f + 4f * thick).dp.toPx()
                    val y = (size.height - line) / 2
                    drawRoundRect(Color.White.copy(alpha = 0.16f), Offset(0f, y), Size(size.width, line), CornerRadius(line / 2))
                    drawRoundRect(fillColor, Offset(0f, y), Size(size.width * fraction, line), CornerRadius(line / 2))
                },
        )
        Row(Modifier.fillMaxWidth()) {
            val shownAt = scrub?.let { (it * duration).toLong() } ?: position
            Text(clock(shownAt), style = Islet.number.copy(fontSize = 11.sp, color = Islet.tertiary))
            Spacer(Modifier.weight(1f))
            Text(if (duration > 0) "-" + clock(duration - shownAt) else "", style = Islet.number.copy(fontSize = 11.sp, color = Islet.tertiary))
        }
    }
}

private fun clock(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

@Composable
private fun CallOpen(call: DotFeed.Call, f: Frame, act: (Int) -> Unit) {
    Column(Modifier.fillMaxSize().padding(start = 22.dp, end = 22.dp, top = f.contentTop, bottom = 14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AppIcon(call.icon, 44.dp)
            Spacer(Modifier.width(12.dp))
            Column {
                Text(call.name, style = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Islet.text), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(if (call.incoming) "Incoming call" else rememberCallStatus(call), style = TextStyle(fontSize = 13.sp, color = Islet.secondary, fontFamily = if (call.incoming) null else Islet.mono))
            }
        }
        Spacer(Modifier.height(18.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
            call.actions.take(3).forEachIndexed { index, title ->
                val name = title.lowercase()
                val (color, icon) = when {
                    listOf("decline", "reject", "hang", "end", "dismiss").any { it in name } -> Decline to Icons.Rounded.CallEnd
                    listOf("answer", "accept").any { it in name } -> Answer to Icons.Rounded.Call
                    else -> Raised to null
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.size(56.dp).clip(CircleShape).background(color).pressable(0.9f) { act(index) }, contentAlignment = Alignment.Center) {
                        if (icon != null) Icon(icon, title, tint = Color.White, modifier = Modifier.size(26.dp))
                        else Text(title.take(1).uppercase(), style = TextStyle(fontSize = 18.sp, color = Islet.text))
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(title, style = TextStyle(fontSize = 12.sp, color = Islet.secondary), maxLines = 1)
                }
            }
        }
    }
}
