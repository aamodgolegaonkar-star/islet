package local.islet.link.ui

import android.os.Build
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Islet's look on Android: warm near-black, off-white type, hairline edges. Colour is
 * kept for meaning only (connected, charging, low battery); glass only where things
 * float (the tab bar and its lens).
 */
object Islet {
    val background = Color(0xFF0B0B0A)
    val card = Color(0xFF141413)
    val cardHigh = Color(0xFF1C1C1A)
    val stroke = Color(0x14FFFFFF)
    val text = Color(0xFFEDEBE6)
    val secondary = Color(0xFFA19E96)
    val tertiary = Color(0xFF6B6963)
    val fill = Color(0xFFEDEBE6)
    /** Semantic accents, desaturated so they sit quietly on the dark canvas. */
    val green = Color(0xFF9CC79A)
    val red = Color(0xFFE59A93)
    val blue = Color(0xFF9DBEDD)
    val amber = Color(0xFFDDC48E)

    val serif = FontFamily.Serif
    val mono = FontFamily.Monospace

    val title = TextStyle(fontFamily = serif, fontSize = 34.sp, fontWeight = FontWeight.Normal, letterSpacing = (-0.8).sp, lineHeight = 38.sp, color = text)
    val heading = TextStyle(fontFamily = serif, fontSize = 22.sp, fontWeight = FontWeight.Normal, letterSpacing = (-0.4).sp, color = text)
    val body = TextStyle(fontSize = 16.sp, lineHeight = 23.sp, color = text)
    val caption = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, color = secondary)
    val label = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, letterSpacing = 1.2.sp, color = tertiary)
    val number = TextStyle(fontFamily = mono, fontSize = 13.sp, color = secondary)
}

/** Motion tokens: smooth no-bounce springs by default; the tab lens is the playful one. */
object Motion {
    val easeOutExpo = CubicBezierEasing(0.16f, 1f, 0.3f, 1f)
    fun <T> gentle(): AnimationSpec<T> = spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 420f)
    fun <T> press(): AnimationSpec<T> = spring(dampingRatio = 0.62f, stiffness = 900f)
    fun <T> lens(): AnimationSpec<T> = spring(dampingRatio = 0.74f, stiffness = 360f)
}

/** True when the user turned animations off (Developer options or Accessibility). */
val LocalReducedMotion = staticCompositionLocalOf { false }

@Composable
fun IsletTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val reduced = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Islet.fill, onPrimary = Islet.background, secondary = Islet.secondary,
            background = Islet.background, surface = Islet.card, onSurface = Islet.text,
            surfaceVariant = Islet.cardHigh, onSurfaceVariant = Islet.secondary,
        ),
    ) {
        CompositionLocalProvider(LocalReducedMotion provides reduced, content = content)
    }
}

/** The phone's haptic engine, by intent. Every control speaks through these. */
object Haptic {
    fun tick(view: View) = view.perform(if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.SEGMENT_FREQUENT_TICK else HapticFeedbackConstants.CLOCK_TICK)
    fun step(view: View) = view.perform(if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.SEGMENT_TICK else HapticFeedbackConstants.CLOCK_TICK)
    fun press(view: View) = view.perform(HapticFeedbackConstants.VIRTUAL_KEY)
    fun release(view: View) = view.perform(HapticFeedbackConstants.VIRTUAL_KEY_RELEASE)
    fun edge(view: View) = view.perform(HapticFeedbackConstants.CONFIRM)
    fun heavy(view: View) = view.perform(HapticFeedbackConstants.LONG_PRESS)
    fun gestureStart(view: View) = view.perform(HapticFeedbackConstants.GESTURE_START)

    private fun View.perform(constant: Int) {
        performHapticFeedback(constant)
    }
}

/**
 * Press feedback for any tappable surface: a quick spring down to 96 %, a haptic on
 * touch-down, and the action on release. Bounds never change, so nothing around it moves.
 */
fun Modifier.pressable(scale: Float = 0.96f, haptics: Boolean = true, onClick: () -> Unit): Modifier = composed {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val view = LocalView.current
    val reduced = LocalReducedMotion.current
    LaunchedEffect(pressed) { if (pressed && haptics) Haptic.press(view) }
    val amount by animateFloatAsState(if (pressed) scale else 1f, if (reduced) snap() else Motion.press(), label = "press")
    this
        .graphicsLayer { scaleX = amount; scaleY = amount }
        .clickable(interaction, indication = null, role = Role.Button, onClick = onClick)
}

/**
 * First-appearance motion: up 14dp and in, staggered by [index]. Runs once per screen;
 * off when animations are off.
 */
fun Modifier.entrance(index: Int = 0): Modifier = composed {
    val reduced = LocalReducedMotion.current
    val progress = remember { Animatable(if (reduced) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (!reduced) progress.animateTo(1f, tween(520, delayMillis = 40 + index * 55, easing = Motion.easeOutExpo))
    }
    graphicsLayer {
        alpha = progress.value
        translationY = (1f - progress.value) * 14.dp.toPx()
    }
}

/** A flat card with a hairline edge. */
@Composable
fun Card(modifier: Modifier = Modifier, padding: Dp = 20.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier
            .clip(RoundedCornerShape(22.dp))
            .background(Islet.card)
            .border(1.dp, Islet.stroke, RoundedCornerShape(22.dp))
            .padding(padding),
        content = content,
    )
}

/** Floating glass: translucent fill, a brighter top edge like light catching a lens. */
fun Modifier.glass(shape: Shape, strength: Float = 1f): Modifier = this
    .clip(shape)
    .background(Color(0xFF242422).copy(alpha = 0.78f))
    .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.07f * strength), Color.Transparent)))
    .border(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.22f * strength), Color.White.copy(alpha = 0.04f))), shape)

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), modifier.padding(start = 4.dp, top = 30.dp, bottom = 12.dp), style = Islet.label)
}

/** A tile in the quick-actions grid: an icon in a soft square and a short name. */
@Composable
fun ActionTile(icon: ImageVector, label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Column(modifier.pressable(onClick = onClick).padding(vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.size(56.dp).clip(RoundedCornerShape(18.dp)).background(Islet.cardHigh)
                .border(1.dp, Islet.stroke, RoundedCornerShape(18.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = Islet.text, modifier = Modifier.size(24.dp))
        }
        Spacer(Modifier.height(8.dp))
        Text(label, style = Islet.caption.copy(fontSize = 12.sp), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Primary (light on dark) or quiet (hairline) button. 52dp tall, crisp corners. */
@Composable
fun Button(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, primary: Boolean = true, onClick: () -> Unit) {
    Row(
        modifier
            .defaultMinSize(minHeight = 52.dp)
            .pressable(onClick = onClick)
            .clip(RoundedCornerShape(14.dp))
            .background(if (primary) Islet.fill else Islet.cardHigh)
            .border(1.dp, if (primary) Color.Transparent else Islet.stroke, RoundedCornerShape(14.dp))
            .padding(horizontal = 22.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        val tint = if (primary) Islet.background else Islet.text
        if (icon != null) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, color = tint, fontWeight = FontWeight.Medium, fontSize = 16.sp)
    }
}

/** A row with a quiet switch that springs between states and ticks under the finger. */
@Composable
fun ToggleRow(title: String, detail: String? = null, checked: Boolean, onChange: (Boolean) -> Unit) {
    val view = LocalView.current
    val reduced = LocalReducedMotion.current
    val position by animateFloatAsState(if (checked) 1f else 0f, if (reduced) snap() else Motion.gentle(), label = "switch")
    Row(
        Modifier.fillMaxWidth()
            .clickable(role = Role.Switch) { Haptic.step(view); onChange(!checked) }
            .padding(vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = Islet.body)
            if (detail != null) Text(detail, style = Islet.caption)
        }
        Spacer(Modifier.width(16.dp))
        Box(
            Modifier.size(width = 50.dp, height = 30.dp).clip(CircleShape)
                .background(androidx.compose.ui.graphics.lerp(Islet.cardHigh, Islet.green, position))
                .border(1.dp, Islet.stroke, CircleShape),
        ) {
            Box(
                Modifier.padding(3.dp).offset(x = 20.dp * position).size(24.dp).clip(CircleShape)
                    .background(androidx.compose.ui.graphics.lerp(Islet.secondary, Color.White, position)),
            )
        }
    }
}
