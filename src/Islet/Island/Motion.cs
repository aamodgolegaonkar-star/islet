using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Islet.Settings;

namespace Islet.Island;

/// One spring, parameterised like SwiftUI's `.spring(duration:bounce:)` so the island moves
/// exactly like the Mac's: stiffness (2π/duration)², damping 4π(1−bounce)/duration.
public readonly record struct SpringSpec(double Duration, double Bounce)
{
    public double Stiffness => Math.Pow(2 * Math.PI / Duration, 2);
    public double Damping => 4 * Math.PI * (1 - Bounce) / Duration;
}

/// The island's motion vocabulary, the same tokens as the Mac's IslandMotion.
public static class IslandMotion
{
    /// Windows' "Animation effects" off (or Islet's own Reduce Motion): short, bounce-free fades.
    public static bool Reduced => AppSettings.Shared.ReduceMotion || !SystemParameters.ClientAreaAnimation;

    private static SpringSpec Respecting(SpringSpec full) => Reduced ? new SpringSpec(0.16, 0) : full;

    /// Opening: quick, with a small overshoot as the island settles at full size.
    public static SpringSpec Open => Respecting(new(0.46, 0.24));
    /// Closing: a touch faster and without bounce, so it tucks away cleanly.
    public static SpringSpec Close => Respecting(new(0.38, 0.04));
    /// Live activities arriving, changing and leaving.
    public static SpringSpec Activity => Respecting(new(0.48, 0.28));
    /// Small state changes inside the island (hover lift, tuck, style).
    public static SpringSpec Subtle => Respecting(new(0.34, 0.16));
    /// Presses, hovers, toggles, HUD values.
    public static SpringSpec Quick => Respecting(new(0.24, 0.08));
    /// Rare, happy moments (unlocking, a Portal drop): a livelier bounce.
    public static SpringSpec Playful => Respecting(new(0.6, 0.36));
}

/// A value that springs toward its target. Driven by `SpringDriver`, which only listens to
/// WPF's frame clock while something is actually moving: an island at rest costs no frames.
public sealed class Spring
{
    public double Value { get; private set; }
    public double Target { get; private set; }
    private double _velocity;
    private SpringSpec _spec = new(0.4, 0);
    private double _delay;
    public event Action? Moved;
    public bool IsMoving { get; private set; }

    public Spring(double value) { Value = Target = value; }

    public void To(double target, SpringSpec spec, double delay = 0)
    {
        if (target == Target && (IsMoving || Value == target)) { _spec = spec; return; }
        Target = target;
        _spec = spec;
        _delay = delay;
        if (!IsMoving)
        {
            IsMoving = true;
            SpringDriver.Add(this);
        }
    }

    /// Jumps there with no motion (first layout, Reduce Motion snaps).
    public void Snap(double value)
    {
        Value = Target = value;
        _velocity = 0;
        Moved?.Invoke();
    }

    /// Advances by `dt` seconds; false once settled.
    internal bool Step(double dt)
    {
        if (_delay > 0)
        {
            _delay -= dt;
            if (_delay > 0) return true;
            dt = -_delay;
            _delay = 0;
        }
        // Semi-implicit Euler in small steps: stable for the stiffest spring used (0.16 s).
        const double h = 1 / 480.0;
        for (var t = 0.0; t < dt; t += h)
        {
            var step = Math.Min(h, dt - t);
            var force = -_spec.Stiffness * (Value - Target) - _spec.Damping * _velocity;
            _velocity += force * step;
            Value += _velocity * step;
        }
        var scale = Math.Max(Math.Abs(Target), 1);
        if (Math.Abs(Value - Target) < 0.0005 * scale && Math.Abs(_velocity) < 0.005 * scale)
        {
            Value = Target;
            _velocity = 0;
            IsMoving = false;
        }
        if (!double.IsFinite(Value)) { Value = Target; _velocity = 0; IsMoving = false; }
        Moved?.Invoke();
        return IsMoving;
    }
}

/// Steps every moving spring once per rendered frame, and unhooks from the frame clock the
/// moment the last one settles. While it's unhooked WPF renders nothing for the island.
public static class SpringDriver
{
    private static readonly List<Spring> Active = [];
    private static TimeSpan _last;
    private static bool _hooked;
    public static bool IsRunning => _hooked;
    /// Raised when motion starts and stops, so the app can leave EcoQoS while animating.
    public static event Action<bool>? Animating;
    /// Raised after every frame's springs have moved (one layout pass per frame, not per spring).
    public static event Action? Frame;

    internal static void Add(Spring spring)
    {
        if (!Active.Contains(spring)) Active.Add(spring);
        if (_hooked) return;
        _hooked = true;
        _last = TimeSpan.Zero;
        CompositionTarget.Rendering += OnRendering;
        Animating?.Invoke(true);
    }

    private static void OnRendering(object? sender, EventArgs e)
    {
        var now = ((RenderingEventArgs)e).RenderingTime;
        // The first frame, or a frame after a stall (sleep, a dragged window): one 60 Hz step.
        var dt = _last == TimeSpan.Zero || (now - _last).TotalSeconds > 0.1 ? 1 / 60.0 : (now - _last).TotalSeconds;
        if (now == _last) return;
        _last = now;
        for (var i = Active.Count - 1; i >= 0; i--)
            if (!Active[i].Step(dt)) Active.RemoveAt(i);
        Frame?.Invoke();
        if (Active.Count > 0) return;
        CompositionTarget.Rendering -= OnRendering;
        _hooked = false;
        Animating?.Invoke(false);
    }
}

/// Content arriving: it trails the shape slightly, then sharpens from a blur while growing into
/// place from the top. Leaving: it blurs out quickly before the shape closes over it.
/// The blur effect exists only during the transition, so resting content renders plainly.
public static class Materialize
{
    public static void In(FrameworkElement element, double delay = 0.06)
    {
        var scale = new ScaleTransform(0.92, 0.92);
        element.RenderTransformOrigin = new Point(0.5, 0);
        element.RenderTransform = scale;
        element.Opacity = 0;
        var reduced = IslandMotion.Reduced;
        var blur = reduced ? null : new System.Windows.Media.Effects.BlurEffect { Radius = 7, RenderingBias = System.Windows.Media.Effects.RenderingBias.Performance };
        element.Effect = blur;
        var amount = new Spring(1);
        amount.Moved += () =>
        {
            var a = Math.Max(amount.Value, 0);
            element.Opacity = Math.Clamp(1 - a, 0, 1);
            scale.ScaleX = scale.ScaleY = 1 - a * 0.08;
            if (blur is not null) blur.Radius = a * 7;
            if (!amount.IsMoving) { element.Effect = null; element.RenderTransform = Transform.Identity; }
        };
        amount.To(0, reduced ? new SpringSpec(0.16, 0) : new SpringSpec(0.4, 0.1), reduced ? 0 : delay);
    }

    public static void Out(FrameworkElement element, Action removed)
    {
        element.IsHitTestVisible = false;
        var reduced = IslandMotion.Reduced;
        var duration = new Duration(TimeSpan.FromSeconds(reduced ? 0.12 : 0.13));
        var fade = new DoubleAnimation(0, duration) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn } };
        fade.Completed += (_, _) => removed();
        if (!reduced)
        {
            element.Effect = new System.Windows.Media.Effects.BlurEffect { Radius = 0, RenderingBias = System.Windows.Media.Effects.RenderingBias.Performance };
            element.Effect.BeginAnimation(System.Windows.Media.Effects.BlurEffect.RadiusProperty, new DoubleAnimation(5, duration));
            var scale = new ScaleTransform(1, 1);
            element.RenderTransformOrigin = new Point(0.5, 0);
            element.RenderTransform = scale;
            var shrink = new DoubleAnimation(0.944, duration);
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, shrink);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, shrink);
        }
        element.BeginAnimation(UIElement.OpacityProperty, fade);
    }
}
