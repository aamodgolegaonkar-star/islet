using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Islet.Media;
using Islet.Services;

namespace Islet.Island;

/// A slider in the island's style: a thin track that thickens under the pointer, a white
/// fill, and a round thumb. Drags hold the island open.
public sealed class IslandSlider : Grid
{
    private readonly Border _track, _fill, _thumb;
    private readonly Spring _thickness = new(4);
    private double _value;
    public event Action<double>? ValueChanged;
    public event Action<bool>? Editing;

    public IslandSlider(Brush tint)
    {
        Height = 22;
        Background = Ui.Clear;
        _track = new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = Ui.Track, VerticalAlignment = VerticalAlignment.Center };
        _fill = new Border { CornerRadius = new CornerRadius(2), Background = tint, HorizontalAlignment = HorizontalAlignment.Left };
        _track.Child = _fill;
        _thumb = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = Ui.White, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        Children.Add(_track);
        Children.Add(_thumb);
        _thickness.Moved += () => { _track.Height = _thickness.Value; _track.CornerRadius = _fill.CornerRadius = new CornerRadius(_thickness.Value / 2); };
        MouseEnter += (_, _) => _thickness.To(6, IslandMotion.Quick);
        MouseLeave += (_, _) => { if (!IsMouseCaptured) _thickness.To(4, IslandMotion.Quick); };
        MouseLeftButtonDown += (_, e) => { CaptureMouse(); Editing?.Invoke(true); Drag(e.GetPosition(this).X); e.Handled = true; };
        MouseMove += (_, e) => { if (IsMouseCaptured) Drag(e.GetPosition(this).X); };
        MouseLeftButtonUp += (_, _) => { ReleaseMouseCapture(); if (!IsMouseOver) _thickness.To(4, IslandMotion.Quick); Editing?.Invoke(false); };
        SizeChanged += (_, _) => Draw();
    }

    public double Value { get => _value; set { _value = Math.Clamp(value, 0, 1); Draw(); } }

    private void Drag(double x)
    {
        Value = (x - 7) / Math.Max(ActualWidth - 14, 1);
        ValueChanged?.Invoke(_value);
    }

    private void Draw()
    {
        var width = Math.Max(ActualWidth - 14, 0);
        _fill.Width = 7 + width * _value;
        _thumb.Margin = new Thickness(width * _value, 0, 0, 0);
    }
}

/// Control Center in the island: Wi-Fi, Bluetooth, dark mode and keep-awake switches; volume
/// and brightness; lock, screenshot, the shelf and Now Playing.
internal sealed class ControlCenterView : Grid
{
    public ControlCenterView(SystemControls controls, SystemVolume volume, IslandModel model, PlayerStore store,
                             Action showMusic, Action? showShelf, Action startTimer)
    {
        var stack = new StackPanel { Margin = new Thickness(20, 14, 20, 12) };
        var toggles = new UniformGrid4();
        Toggle Make(string title, string glyph, Func<bool> on, Action<bool> set, Brush tint)
        {
            var toggle = new Toggle(title, glyph, tint);
            toggle.Set(on());
            toggle.Click += () => { var next = !on(); toggle.Set(next); set(next); };
            Action changed = () => Dispatcher.BeginInvoke(() => toggle.Set(on()));
            this.WhileLoaded(() => controls.Changed += changed, () => controls.Changed -= changed);
            return toggle;
        }
        if (controls.HasWifi) toggles.Children.Add(Make("Wi-Fi", Ui.Wifi, () => controls.WifiOn, on => _ = controls.SetWifi(on), Ui.Frozen(Color.FromRgb(10, 132, 255))));
        if (controls.HasBluetooth) toggles.Children.Add(Make("Bluetooth", Ui.Bluetooth, () => controls.BluetoothOn, on => _ = controls.SetBluetooth(on), Ui.Frozen(Color.FromRgb(10, 132, 255))));
        toggles.Children.Add(Make("Dark", Ui.Moon, () => controls.DarkMode, on => controls.DarkMode = on, Ui.Frozen(Color.FromRgb(94, 92, 230))));
        toggles.Children.Add(Make("Awake", Ui.Sun, () => controls.KeepAwake, on => controls.KeepAwake = on, Ui.Orange));
        stack.Children.Add(toggles);

        var volumeSlider = new IslandSlider(Ui.White) { Value = volume.Muted ? 0 : volume.Level };
        volumeSlider.ValueChanged += v => { if (volume.Muted) volume.SetMuted(false); volume.SetLevel(v); };
        volumeSlider.Editing += on => model.IsInteracting = on;
        Action volumeChanged = () => { if (!volumeSlider.IsMouseCaptured) volumeSlider.Value = volume.Muted ? 0 : volume.Level; };
        this.WhileLoaded(() => volume.Changed += volumeChanged, () => volume.Changed -= volumeChanged);
        stack.Children.Add(Level(Ui.Volume, volumeSlider));
        if (controls.Brightness is double brightness)
        {
            var brightnessSlider = new IslandSlider(Ui.Frozen(Color.FromRgb(255, 214, 10))) { Value = brightness };
            brightnessSlider.ValueChanged += controls.SetBrightness;
            brightnessSlider.Editing += on => model.IsInteracting = on;
            Action<double> brightnessChanged = v => Dispatcher.BeginInvoke(() => { if (!brightnessSlider.IsMouseCaptured) brightnessSlider.Value = v; });
            this.WhileLoaded(() => controls.BrightnessChanged += brightnessChanged, () => controls.BrightnessChanged -= brightnessChanged);
            stack.Children.Add(Level(Ui.Sun, brightnessSlider));
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
        void Action(string glyph, string help, Action run)
        {
            var button = new GlyphButton(glyph, 14, 32, help) { Margin = new Thickness(5, 0, 5, 0) };
            button.Click += run;
            actions.Children.Add(button);
        }
        Action(Ui.Lock, "Lock", controls.Lock);
        Action(Ui.Camera, "Screenshot", controls.Screenshot);
        Action(Ui.Timer, "Timer (5 minutes)", startTimer);
        if (showShelf is not null) Action(Ui.Tray, "Shelf", showShelf);
        if (store.HasTrack) Action(Ui.Music, "Now Playing", showMusic);
        stack.Children.Add(actions);
        Children.Add(stack);
    }

    private static Grid Level(string glyph, IslandSlider slider)
    {
        var row = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(Ui.Glyph(glyph, 13, Ui.Secondary));
        Grid.SetColumn(slider, 1);
        row.Children.Add(slider);
        return row;
    }

    /// Four equal columns.
    private sealed class UniformGrid4 : System.Windows.Controls.Primitives.UniformGrid
    {
        public UniformGrid4() { Rows = 1; }
    }

    private sealed class Toggle : StackPanel
    {
        private readonly Border _circle;
        private readonly Brush _tint;
        private readonly Spring _press = new(1);
        public event Action? Click;

        public Toggle(string title, string glyph, Brush tint)
        {
            _tint = tint;
            HorizontalAlignment = HorizontalAlignment.Center;
            _circle = new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(18), Child = Ui.Glyph(glyph, 15), Cursor = Cursors.Arrow };
            var scale = new ScaleTransform(1, 1);
            _circle.RenderTransformOrigin = new Point(0.5, 0.5);
            _circle.RenderTransform = scale;
            _press.Moved += () => scale.ScaleX = scale.ScaleY = _press.Value;
            Children.Add(_circle);
            var label = Ui.Label(title, 10, FontWeights.SemiBold, Ui.Secondary);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            label.Margin = new Thickness(0, 3, 0, 0);
            Children.Add(label);
            _circle.MouseLeftButtonDown += (_, e) => { _press.To(0.88, IslandMotion.Quick); e.Handled = true; };
            _circle.MouseLeftButtonUp += (_, e) => { _press.To(1, IslandMotion.Quick); Click?.Invoke(); e.Handled = true; };
            _circle.MouseLeave += (_, _) => _press.To(1, IslandMotion.Quick);
        }

        public void Set(bool on) => _circle.Background = on ? _tint : Ui.Frozen(Color.FromArgb(46, 255, 255, 255));
    }
}
