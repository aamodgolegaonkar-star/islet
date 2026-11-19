using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace Islet.Island;

/// Fonts and glyphs: Segoe UI Variable and Segoe Fluent Icons on Windows 11, with the
/// Windows 10 faces as fallbacks. These stand in for SF Pro and SF Symbols.
public static class Ui
{
    public static readonly FontFamily Text = new("Segoe UI Variable Text, Segoe UI");
    public static readonly FontFamily Display = new("Segoe UI Variable Display, Segoe UI");
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    public static readonly Brush White = Frozen(Colors.White);
    public static readonly Brush Secondary = Frozen(Color.FromArgb(158, 255, 255, 255));
    public static readonly Brush Tertiary = Frozen(Color.FromArgb(140, 255, 255, 255));
    public static readonly Brush Green = Frozen(Color.FromRgb(48, 209, 88));
    public static readonly Brush Red = Frozen(Color.FromRgb(255, 69, 58));
    public static readonly Brush Orange = Frozen(Color.FromRgb(255, 159, 10));
    public static readonly Brush Track = Frozen(Color.FromArgb(51, 255, 255, 255));
    public static readonly Brush Highlight = Frozen(Color.FromArgb(36, 255, 255, 255));
    public static readonly Brush IslandBlack = Frozen(Colors.Black);
    public static readonly Brush Clear = Frozen(Colors.Transparent);

    // Segoe Fluent Icons / MDL2 code points.
    public const string Play = "", Pause = "", Previous = "", Next = "";
    public const string PlayMdl = "", PauseMdl = "", PreviousMdl = "", NextMdl = "";
    public const string Volume = "", Volume1 = "", Volume2 = "", Volume3 = "", Mute = "";
    public const string Brightness = "", Bolt = "", Lock = "", Unlock = "", Fingerprint = "";
    public const string Headphones = "", Speakers = "", Settings = "", Music = "", Clock = "";
    public const string Timer = "", Shuffle = "", RepeatAll = "", RepeatOne = "", Phone = "";
    public const string Tray = "", Controls = "", Wifi = "", Bluetooth = "", Airplane = "";
    public const string Moon = "", Sun = "", Battery = "", Mic = "", Camera = "";
    public const string Close = "", Check = "", Terminal = "", Warning = "", Dismiss = "";

    public static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    public static TextBlock Label(string text, double size, FontWeight weight, Brush? brush = null, bool digits = false) => new()
    {
        Text = text,
        FontFamily = size >= 20 ? Display : Text,
        FontSize = size,
        FontWeight = weight,
        Foreground = brush ?? White,
        TextTrimming = TextTrimming.CharacterEllipsis,
        VerticalAlignment = VerticalAlignment.Center,
        // Monospaced digits so times and percentages don't jiggle as they change.
        Typography = { NumeralAlignment = digits ? FontNumeralAlignment.Tabular : FontNumeralAlignment.Normal },
    };

    public static TextBlock Glyph(string glyph, double size, Brush? brush = null) => new()
    {
        Text = glyph,
        FontFamily = Icons,
        FontSize = size,
        Foreground = brush ?? White,
        VerticalAlignment = VerticalAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
        TextAlignment = TextAlignment.Center,
    };

    // Filled transport shapes, drawn as vectors (in a 24×24 box) so they look the same on
    // Windows 10 and 11 and match the weight of the Mac's filled SF Symbols.
    public static readonly Geometry PlayShape = Shape("M7.2,3.6 C6.4,3.1 5.5,3.7 5.5,4.6 L5.5,19.4 C5.5,20.3 6.4,20.9 7.2,20.4 L19.6,13 C20.4,12.5 20.4,11.5 19.6,11 Z");
    public static readonly Geometry PauseShape = Shape("M6.5,4 h3.2 a1.3,1.3 0 0 1 1.3,1.3 v13.4 a1.3,1.3 0 0 1 -1.3,1.3 h-3.2 a1.3,1.3 0 0 1 -1.3,-1.3 v-13.4 a1.3,1.3 0 0 1 1.3,-1.3 Z M14.3,4 h3.2 a1.3,1.3 0 0 1 1.3,1.3 v13.4 a1.3,1.3 0 0 1 -1.3,1.3 h-3.2 a1.3,1.3 0 0 1 -1.3,-1.3 v-13.4 a1.3,1.3 0 0 1 1.3,-1.3 Z");
    public static readonly Geometry ForwardShape = Shape("M2.5,6.4 C2.5,5.6 3.4,5.1 4.1,5.6 L11.3,11 C11.9,11.5 11.9,12.5 11.3,13 L4.1,18.4 C3.4,18.9 2.5,18.4 2.5,17.6 Z M12.3,6.4 C12.3,5.6 13.2,5.1 13.9,5.6 L21.1,11 C21.7,11.5 21.7,12.5 21.1,13 L13.9,18.4 C13.2,18.9 12.3,18.4 12.3,17.6 Z");
    public static readonly Geometry BackwardShape = Mirrored(ForwardShape);

    private static Geometry Shape(string data)
    {
        var geometry = Geometry.Parse(data);
        geometry.Freeze();
        return geometry;
    }

    private static Geometry Mirrored(Geometry source)
    {
        var copy = source.Clone();
        copy.Transform = new MatrixTransform(-1, 0, 0, 1, 24, 0);
        var flat = copy.GetFlattenedPathGeometry();
        flat.Freeze();
        return flat;
    }

    public static System.Windows.Shapes.Path ShapeIcon(Geometry shape, double size, Brush? brush = null) => new()
    {
        Data = shape,
        Fill = brush ?? White,
        Width = size,
        Height = size,
        Stretch = Stretch.Uniform,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };
}

/// A round glyph button that highlights softly under the pointer and shrinks a touch when
/// pressed, like the Mac island's `.highlight` look. Works in a window that never activates.
public sealed class GlyphButton : Border
{
    private readonly TextBlock? _glyph;
    private readonly ScaleTransform _press = new(1, 1);
    private readonly Spring _hover = new(0), _pressSpring = new(1);
    public event Action? Click;

    public GlyphButton(string glyph, double glyphSize, double diameter, string? tooltip = null)
        : this(Ui.Glyph(glyph, glyphSize), diameter, tooltip) { }

    public GlyphButton(UIElement content, double diameter, string? tooltip = null)
    {
        Width = Height = diameter;
        CornerRadius = new CornerRadius(diameter / 2);
        Background = Ui.Clear;
        _glyph = content as TextBlock;
        Child = content;
        RenderTransformOrigin = new Point(0.5, 0.5);
        RenderTransform = _press;
        ToolTip = tooltip;
        Cursor = Cursors.Arrow;
        _hover.Moved += () => Background = new SolidColorBrush(Color.FromArgb((byte)(_hover.Value * 36), 255, 255, 255));
        _pressSpring.Moved += () => _press.ScaleX = _press.ScaleY = _pressSpring.Value;
        MouseEnter += (_, _) => _hover.To(1, IslandMotion.Quick);
        MouseLeave += (_, _) => { _hover.To(0, IslandMotion.Quick); _pressSpring.To(1, IslandMotion.Quick); };
        MouseLeftButtonDown += (_, e) => { _pressSpring.To(0.86, IslandMotion.Quick); CaptureMouse(); e.Handled = true; };
        MouseLeftButtonUp += (_, e) =>
        {
            var inside = IsMouseOver;
            ReleaseMouseCapture();
            _pressSpring.To(1, IslandMotion.Quick);
            if (inside) Click?.Invoke();
            e.Handled = true;
        };
    }

    public string Glyph { get => _glyph?.Text ?? ""; set { if (_glyph is not null) _glyph.Text = value; } }
}

/// The island's equalizer: four bars bouncing at unequal periods (so they never fall into
/// step) while music plays, resting otherwise. The loops are WPF timelines capped at 30 fps,
/// and they stop entirely whenever the island can't be seen or nothing plays.
public sealed class EqualizerBars : Grid
{
    private static readonly double[] Rest = [0.3, 0.5, 0.38, 0.26];
    private static readonly double[] Periods = [1.19, 0.89, 1.43, 1.01];
    private static readonly double[] Phases = [0, 1.9, 3.3, 4.6];
    private static readonly double[] Still = [0.55, 0.85, 0.65, 0.45];
    private readonly Rectangle[] _bars = new Rectangle[4];
    private readonly ScaleTransform[] _scales = new ScaleTransform[4];
    private bool _moving;

    public EqualizerBars(double width, double height)
    {
        Width = width;
        Height = height;
        var gap = width * 0.13;
        var barWidth = (width - gap * 3) / 4;
        for (var i = 0; i < 4; i++)
        {
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(barWidth) });
            if (i < 3) ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(gap) });
            _scales[i] = new ScaleTransform(1, Rest[i]);
            _bars[i] = new Rectangle
            {
                RadiusX = barWidth / 2, RadiusY = barWidth / 2, Height = height,
                RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = _scales[i],
            };
            SetColumn(_bars[i], i * 2);
            Children.Add(_bars[i]);
        }
        Color = Colors.White;
        IsVisibleChanged += (_, _) => Update();
    }

    public Color Color
    {
        set
        {
            var brush = new LinearGradientBrush(value, Color.FromArgb(255, (byte)(value.R * 0.8), (byte)(value.G * 0.8), (byte)(value.B * 0.8)), 90);
            brush.Freeze();
            foreach (var bar in _bars) bar.Fill = brush;
        }
    }

    private bool _playing;
    public bool IsPlaying { get => _playing; set { _playing = value; Update(); } }

    private void Update()
    {
        var move = _playing && IsVisible;
        if (move == _moving) return;
        _moving = move;
        for (var i = 0; i < 4; i++)
        {
            if (!move || IslandMotion.Reduced)
            {
                _scales[i].BeginAnimation(ScaleTransform.ScaleYProperty, null);
                _scales[i].ScaleY = move ? Still[i] : Rest[i];
                continue;
            }
            var bounce = new DoubleAnimationUsingKeyFrames
            {
                Duration = TimeSpan.FromSeconds(Periods[i]),
                RepeatBehavior = RepeatBehavior.Forever,
                BeginTime = TimeSpan.FromSeconds(-Phases[i] % Periods[i]),
            };
            bounce.KeyFrames.Add(new EasingDoubleKeyFrame(0.28, KeyTime.FromPercent(0), new SineEase()));
            bounce.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromPercent(0.45), new SineEase { EasingMode = EasingMode.EaseInOut }));
            bounce.KeyFrames.Add(new EasingDoubleKeyFrame(0.45, KeyTime.FromPercent(0.7), new SineEase { EasingMode = EasingMode.EaseInOut }));
            bounce.KeyFrames.Add(new EasingDoubleKeyFrame(0.28, KeyTime.FromPercent(1), new SineEase { EasingMode = EasingMode.EaseInOut }));
            Timeline.SetDesiredFrameRate(bounce, 30);
            _scales[i].BeginAnimation(ScaleTransform.ScaleYProperty, bounce);
        }
    }
}

/// Text that scrolls when it's too long for its space, pausing at each end, like the
/// island's marquee titles. Static (no timeline at all) when it fits.
public sealed class MarqueeText : Canvas
{
    private readonly TextBlock _text;
    private readonly TranslateTransform _shift = new();

    public MarqueeText(double size, FontWeight weight, Brush brush)
    {
        _text = Ui.Label("", size, weight, brush);
        _text.TextTrimming = TextTrimming.None;
        _text.RenderTransform = _shift;
        Children.Add(_text);
        ClipToBounds = true;
        Height = Math.Ceiling(size * 1.36);
        SizeChanged += (_, _) => Restart();
        IsVisibleChanged += (_, _) => Restart();
    }

    public string Text
    {
        get => _text.Text;
        set { if (_text.Text == value) return; _text.Text = value; Restart(); }
    }

    private void Restart()
    {
        _shift.BeginAnimation(TranslateTransform.XProperty, null);
        _shift.X = 0;
        _text.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var overflow = _text.DesiredSize.Width - ActualWidth;
        if (overflow <= 1 || !IsVisible || IslandMotion.Reduced || ActualWidth <= 0) return;
        // 30 points a second, with a 2 s rest at each end.
        var travel = overflow + 8;
        var move = travel / 30;
        var loop = new DoubleAnimationUsingKeyFrames { RepeatBehavior = RepeatBehavior.Forever };
        loop.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        loop.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(2))));
        loop.KeyFrames.Add(new EasingDoubleKeyFrame(-travel, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(2 + move)), new SineEase { EasingMode = EasingMode.EaseInOut }));
        loop.KeyFrames.Add(new LinearDoubleKeyFrame(-travel, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(4 + move))));
        loop.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(4 + move * 2)), new SineEase { EasingMode = EasingMode.EaseInOut }));
        Timeline.SetDesiredFrameRate(loop, 30);
        _shift.BeginAnimation(TranslateTransform.XProperty, loop);
    }
}

/// Album art with continuous rounded corners and a soft placeholder when there is none.
public sealed class ArtworkView : Border
{
    private readonly Image _image = new() { Stretch = Stretch.UniformToFill };
    private readonly TextBlock _placeholder = Ui.Glyph(Ui.Music, 12, Ui.Secondary);
    private readonly double _radius;

    public ArtworkView(double size, double radius)
    {
        Width = Height = size;
        _radius = radius;
        Background = Ui.Frozen(Color.FromArgb(40, 255, 255, 255));
        _placeholder.FontSize = size * 0.42;
        Child = new Grid { Children = { _placeholder, _image } };
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.HighQuality);
        Clip = new RectangleGeometry(new Rect(0, 0, size, size), radius, radius);
    }

    public ImageSource? Source
    {
        set
        {
            _image.Source = value;
            _placeholder.Visibility = value is null ? Visibility.Visible : Visibility.Collapsed;
        }
    }
}
