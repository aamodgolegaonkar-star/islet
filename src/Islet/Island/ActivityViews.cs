using Path = System.Windows.Shapes.Path;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Islet.Settings;

namespace Islet.Island;

/// Shared layout for the pill activities: a leading glyph, a label, and trailing content.
internal static class Pill
{
    public static Grid Row(double width, double height, double padding = 14)
    {
        var grid = new Grid { Width = width, Height = height, Margin = new Thickness(0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(padding) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(7) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(padding) });
        return grid;
    }

    public static T At<T>(this T element, int column) where T : UIElement
    {
        Grid.SetColumn(element, column);
        return element;
    }
}

/// Volume or brightness: an icon and a level bar you can drag, like the iPhone's.
public sealed class LevelView : Grid
{
    private readonly IslandModel _model;
    private readonly TextBlock _icon;
    private readonly Border _fill, _track;
    private readonly Spring _value;
    private readonly Action<LevelKind, double> _drag;

    public LevelView(IslandModel model, Action<LevelKind, double> drag)
    {
        _model = model;
        _drag = drag;
        var m = model.Metrics;
        Width = m.ChargingWidth;
        Height = m.CompactHeight;
        var row = Pill.Row(Width, Height, 13);
        _icon = Ui.Glyph(Ui.Volume, 14).At(1);
        _icon.Width = 18;
        _track = new Border { Height = 6, CornerRadius = new CornerRadius(3), Background = Ui.Track, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 4, 0) };
        Grid.SetColumn(_track, 3);
        Grid.SetColumnSpan(_track, 2);
        _fill = new Border { CornerRadius = new CornerRadius(3), Background = Ui.White, HorizontalAlignment = HorizontalAlignment.Left };
        _track.Child = _fill;
        row.Children.Add(_icon);
        row.Children.Add(_track);
        Children.Add(row);
        Background = Ui.Clear;
        _value = new Spring(model.Level.Value);
        _value.Moved += Draw;
        _track.SizeChanged += (_, _) => Draw();
        model.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(IslandModel.Level)) Update(); };
        MouseLeftButtonDown += (_, e) => { CaptureMouse(); model.IsInteracting = true; DragTo(e.GetPosition(_track).X); e.Handled = true; };
        MouseMove += (_, e) => { if (IsMouseCaptured) DragTo(e.GetPosition(_track).X); };
        MouseLeftButtonUp += (_, _) => { ReleaseMouseCapture(); model.IsInteracting = false; };
        Update();
    }

    private void DragTo(double x) => _drag(_model.Level.Kind, Math.Clamp(x / Math.Max(_track.ActualWidth, 1), 0, 1));

    private void Update()
    {
        var level = _model.Level;
        _icon.Text = level.Kind == LevelKind.Brightness ? Ui.Brightness
            : level.Muted || level.Value <= 0 ? Ui.Mute
            : level.Value < 0.34 ? Ui.Volume1 : level.Value < 0.67 ? Ui.Volume2 : Ui.Volume3;
        _fill.Opacity = level.Muted ? 0.35 : 1;
        _value.To(level.Muted ? 0 : level.Value, IslandMotion.Quick);
    }

    private void Draw() => _fill.Width = Math.Max(0, _track.ActualWidth * Math.Clamp(_value.Value, 0, 1));
}

/// "Charging" with a bolt, the percentage and a battery that fills up.
public sealed class ChargingView : Grid
{
    public ChargingView(IslandMetrics m, BatteryState battery, BatteryIconStyle style)
    {
        Width = m.ChargingWidth;
        Height = m.CompactHeight;
        var row = Pill.Row(Width, Height);
        var bolt = Ui.Glyph(Ui.Bolt, 13, Ui.Green).At(1);
        var label = Ui.Label("Charging", 13, FontWeights.SemiBold).At(3);
        var percent = Ui.Label($"{Math.Round(battery.Level * 100)}%", 13, FontWeights.SemiBold, Ui.Green, digits: true);
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Children = { percent } }.At(4);
        row.Children.Add(bolt);
        row.Children.Add(label);
        row.Children.Add(trailing);
        Children.Add(row);
        if (style == BatteryIconStyle.Percent) return;
        var fill = new Spring(0);
        if (style == BatteryIconStyle.Ring)
        {
            var ring = new ChargeRing { Margin = new Thickness(7, 0, 0, 0) };
            trailing.Children.Add(ring);
            fill.Moved += () => ring.Level = fill.Value;
        }
        else
        {
            var glyph = new BatteryGlyph { Margin = new Thickness(7, 0, 0, 0) };
            trailing.Children.Add(glyph);
            fill.Moved += () => glyph.Level = fill.Value;
        }
        fill.To(battery.Level, new SpringSpec(0.9, 0), 0.15);
    }
}

public sealed class BatteryGlyph : StackPanel
{
    private readonly Border _fill;

    public BatteryGlyph()
    {
        Orientation = Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center;
        var body = new Border
        {
            Width = 29, Height = 14, CornerRadius = new CornerRadius(4.5), BorderThickness = new Thickness(1.2),
            BorderBrush = Ui.Frozen(Color.FromArgb(115, 255, 255, 255)), Padding = new Thickness(1.3),
        };
        _fill = new Border
        {
            Height = 9, Width = 2, CornerRadius = new CornerRadius(2.5), HorizontalAlignment = HorizontalAlignment.Left,
            Background = new LinearGradientBrush(Color.FromRgb(88, 230, 120), Color.FromRgb(40, 190, 80), 90),
        };
        body.Child = _fill;
        Children.Add(body);
        Children.Add(new Border { Width = 2, Height = 5, CornerRadius = new CornerRadius(1), Background = Ui.Frozen(Color.FromArgb(115, 255, 255, 255)), Margin = new Thickness(1.5, 0, 0, 0) });
    }

    public double Level { set => _fill.Width = Math.Max(2, 24 * Math.Clamp(value, 0, 1)); }
}

public sealed class ChargeRing : Grid
{
    private readonly Path _arc = new() { Stroke = Ui.Green, StrokeThickness = 3, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };

    public ChargeRing()
    {
        Width = Height = 17;
        Children.Add(new Ellipse { Stroke = Ui.Frozen(Color.FromArgb(51, 255, 255, 255)), StrokeThickness = 3 });
        Children.Add(_arc);
    }

    public double Level
    {
        set
        {
            var v = Math.Clamp(value, 0, 0.9999);
            const double r = 7;
            var angle = v * 2 * Math.PI;
            var end = new Point(8.5 + r * Math.Sin(angle), 8.5 - r * Math.Cos(angle));
            _arc.Data = new PathGeometry([new PathFigure(new Point(8.5, 1.5), [new ArcSegment(end, new Size(r, r), 0, v > 0.5, SweepDirection.Clockwise, true)], false)]);
        }
    }
}

/// The unlock moment: the fingerprint is read (red), recognised (green), then turns into an
/// open padlock as "Unlocked" fades in.
public sealed class UnlockView : Grid
{
    public UnlockView(IslandMetrics m)
    {
        Width = m.UnlockedWidth;
        Height = m.CompactHeight;
        var row = Pill.Row(Width, Height, 12);
        var finger = Ui.Glyph(Ui.Fingerprint, 17, Ui.Red);
        var open = Ui.Glyph(Ui.Unlock, 15);
        var icons = new Grid { Width = 24, Children = { finger, open } }.At(1);
        var label = Ui.Label("Unlocked", 13, FontWeights.SemiBold).At(4);
        row.Children.Add(icons);
        row.Children.Add(label);
        Children.Add(row);
        open.Opacity = 0;
        label.Opacity = 0;
        var openScale = new ScaleTransform(0.5, 0.5);
        var fingerScale = new ScaleTransform(1, 1);
        var labelShift = new TranslateTransform(6, 0);
        open.RenderTransformOrigin = finger.RenderTransformOrigin = new Point(0.5, 0.5);
        open.RenderTransform = openScale;
        finger.RenderTransform = fingerScale;
        label.RenderTransform = labelShift;
        var phase = new Spring(0);
        phase.Moved += () =>
        {
            var p = Math.Clamp(phase.Value, 0, 1.2);
            finger.Opacity = Math.Clamp(1 - p, 0, 1);
            fingerScale.ScaleX = fingerScale.ScaleY = 1 - 0.5 * Math.Min(p, 1);
            open.Opacity = Math.Clamp(p, 0, 1);
            openScale.ScaleX = openScale.ScaleY = 0.5 + 0.5 * p;
            label.Opacity = Math.Clamp(p, 0, 1);
            labelShift.X = 6 * (1 - Math.Min(p, 1));
        };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
        var step = 0;
        timer.Tick += (_, _) =>
        {
            if (step++ == 0)
            {
                finger.Foreground = Ui.Green;
                var bounce = new Spring(1.18);
                bounce.Moved += () => fingerScale.ScaleX = fingerScale.ScaleY = bounce.Value;
                bounce.To(1, IslandMotion.Quick);
                timer.Interval = TimeSpan.FromMilliseconds(520);
            }
            else
            {
                timer.Stop();
                phase.To(1, IslandMotion.Playful);
            }
        };
        timer.Start();
    }
}

/// The battery fell to 20% or 10%: a red pill, the charging card in reverse.
public sealed class LowBatteryView : Grid
{
    public LowBatteryView(IslandMetrics m, int percent)
    {
        Width = m.ChargingWidth;
        Height = m.CompactHeight;
        var row = Pill.Row(Width, Height);
        row.Children.Add(Ui.Glyph(Ui.Battery, 14, Ui.Red).At(1));
        row.Children.Add(Ui.Label("Low Battery", 13, FontWeights.SemiBold).At(3));
        row.Children.Add(Ui.Label($"{percent}%", 13, FontWeights.SemiBold, Ui.Red, digits: true).At(4));
        Children.Add(row);
    }
}

/// A running timer: the countdown in orange, ticking once a second.
public sealed class TimerCompactView : Grid
{
    public TimerCompactView(IslandMetrics m, DateTime end)
    {
        Width = m.TimerWidth;
        Height = m.CompactHeight;
        var row = Pill.Row(Width, Height, 12);
        var label = Ui.Label("", 13, FontWeights.SemiBold, Ui.Orange, digits: true).At(4);
        row.Children.Add(Ui.Glyph(Ui.Timer, 13, Ui.Orange).At(1));
        row.Children.Add(label);
        Children.Add(row);
        var timer = new DispatcherTimer(DispatcherPriority.Render);
        void Tick()
        {
            var left = Math.Max(0, (end - DateTime.UtcNow).TotalSeconds);
            label.Text = Core.TimeText.Format(Math.Ceiling(left));
            var fraction = left - Math.Floor(left);
            timer.Interval = TimeSpan.FromMilliseconds(Math.Max(fraction * 1000 + 5, 50));
        }
        timer.Tick += (_, _) => Tick();
        IsVisibleChanged += (_, _) => { if (IsVisible) { Tick(); timer.Start(); } else timer.Stop(); };
        Tick();
    }
}

public sealed class SimplePillView : Grid
{
    public SimplePillView(double width, double height, string glyph, Brush glyphBrush, string text, string? trailing = null, Brush? trailingBrush = null)
    {
        Width = width;
        Height = height;
        var row = Pill.Row(width, height);
        row.Children.Add(Ui.Glyph(glyph, 14, glyphBrush).At(1));
        row.Children.Add(Ui.Label(text, 13, FontWeights.SemiBold).At(3));
        if (trailing is not null) row.Children.Add(Ui.Label(trailing, 13, FontWeights.SemiBold, trailingBrush ?? Ui.Secondary).At(4));
        Children.Add(row);
    }
}

/// The resting island's clock (Settings → Island), updated on the minute.
public sealed class IdleClockView : Grid
{
    public IdleClockView(IslandMetrics m)
    {
        Width = m.TimerWidth;
        Height = m.CompactHeight;
        var label = Ui.Label("", 13, FontWeights.SemiBold, digits: true);
        label.HorizontalAlignment = HorizontalAlignment.Center;
        Children.Add(label);
        Background = Ui.Clear;
        var timer = new DispatcherTimer(DispatcherPriority.Background);
        void Tick()
        {
            var now = DateTime.Now;
            label.Text = now.ToString("t");
            timer.Interval = TimeSpan.FromSeconds(60 - now.Second) - TimeSpan.FromMilliseconds(now.Millisecond) + TimeSpan.FromMilliseconds(20);
        }
        timer.Tick += (_, _) => Tick();
        IsVisibleChanged += (_, _) => { if (IsVisible) { Tick(); timer.Start(); } else timer.Stop(); };
        Tick();
    }
}

/// A card: icon tile, two lines of text, optional trailing content.
public sealed class CardView : Grid
{
    public CardView(double width, double height, string glyph, Brush tint, string title, string detail, UIElement? trailing = null, Action? click = null)
    {
        Width = width;
        Height = height;
        var row = new Grid { Margin = new Thickness(18, 0, 18, 0), VerticalAlignment = VerticalAlignment.Center };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(12), Background = Ui.Frozen(Color.FromArgb(38, 255, 255, 255)), Child = Ui.Glyph(glyph, 20, tint) };
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Ui.Label(title, 14, FontWeights.SemiBold));
        var second = Ui.Label(detail, 12, FontWeights.Normal, Ui.Secondary);
        second.TextWrapping = TextWrapping.Wrap;
        second.MaxHeight = 34;
        texts.Children.Add(second);
        row.Children.Add(tile.At(0));
        row.Children.Add(texts.At(2));
        if (trailing is not null) { Grid.SetColumn(trailing, 3); row.Children.Add(trailing); }
        Children.Add(row);
        Background = Ui.Clear;
        if (click is not null)
        {
            Cursor = Cursors.Hand;
            MouseLeftButtonUp += (_, _) => click();
        }
    }
}
