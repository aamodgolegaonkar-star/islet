using Path = System.Windows.Shapes.Path;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using Islet.Core;
using Islet.Media;
using Islet.Settings;

namespace Islet.Island;

/// Previous, play/pause and next, sized by `scale` like the Mac's TransportRow.
public sealed class TransportRow : StackPanel
{
    private readonly PlayerStore _store;
    private readonly Path _playIcon;

    public TransportRow(PlayerStore store, double scale)
    {
        _store = store;
        Orientation = Orientation.Horizontal;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
        var previous = new GlyphButton(Ui.ShapeIcon(Ui.BackwardShape, 19 * scale), 38 * scale, "Previous");
        _playIcon = Ui.ShapeIcon(Ui.PlayShape, 25 * scale);
        var play = new GlyphButton(_playIcon, 44 * scale, "Play/Pause");
        var next = new GlyphButton(Ui.ShapeIcon(Ui.ForwardShape, 19 * scale), 38 * scale, "Next");
        previous.Click += store.Previous;
        play.Click += store.TogglePlayPause;
        next.Click += store.Next;
        var gap = Math.Max(0, 22 * scale - 12 * scale);
        previous.Margin = new Thickness(0, 0, gap, 0);
        next.Margin = new Thickness(gap, 0, 0, 0);
        Children.Add(previous);
        Children.Add(play);
        Children.Add(next);
        this.WhileLoaded(store, (_, e) => { if (e.PropertyName == nameof(PlayerStore.IsPlaying)) Update(); }, Update);
        Update();
    }

    private void Update() => _playIcon.Data = _store.IsPlaying ? Ui.PauseShape : Ui.PlayShape;
}

/// Elapsed time, a draggable bar and the time left, inline like the iPhone's. The labels
/// tick on whole seconds and the bar only moves when it would move by at least half a pixel,
/// so a playing song costs a timer wake or two a second, not 60 frames.
public sealed class InlineScrubber : Grid
{
    private readonly PlayerStore _store;
    private readonly TextBlock _elapsed, _remaining;
    private readonly Border _track, _fill;
    private readonly DispatcherTimer _tick;
    private readonly Spring _thickness = new(5);
    private double? _preview;
    public event Action<bool>? Editing;

    public InlineScrubber(PlayerStore store, double fontSize = 11)
    {
        _store = store;
        Height = 18;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(fontSize * 3.4) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(9) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(9) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(fontSize * 3.8) });
        _elapsed = Ui.Label("0:00", fontSize, FontWeights.SemiBold, Ui.Frozen(Color.FromArgb(140, 255, 255, 255)), digits: true);
        _elapsed.HorizontalAlignment = HorizontalAlignment.Right;
        _remaining = Ui.Label("-0:00", fontSize, FontWeights.SemiBold, Ui.Frozen(Color.FromArgb(140, 255, 255, 255)), digits: true);
        _track = new Border { Background = Ui.Track, Height = 5, CornerRadius = new CornerRadius(2.5), VerticalAlignment = VerticalAlignment.Center };
        _fill = new Border { Background = Ui.White, HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(2.5) };
        _track.Child = _fill;
        var hit = new Border { Background = Ui.Frozen(Color.FromArgb(1, 0, 0, 0)), Child = _track, Cursor = Cursors.Arrow };
        SetColumn(_elapsed, 0);
        SetColumn(hit, 2);
        SetColumn(_remaining, 4);
        Children.Add(_elapsed);
        Children.Add(hit);
        Children.Add(_remaining);

        _thickness.Moved += () => { _track.Height = _thickness.Value; _track.CornerRadius = new CornerRadius(_thickness.Value / 2); _fill.CornerRadius = _track.CornerRadius; };
        hit.MouseEnter += (_, _) => _thickness.To(8, IslandMotion.Quick);
        hit.MouseLeave += (_, _) => { if (_preview is null) _thickness.To(5, IslandMotion.Quick); };
        hit.MouseLeftButtonDown += (_, e) =>
        {
            hit.CaptureMouse();
            Editing?.Invoke(true);
            Drag(e.GetPosition(_track).X);
            e.Handled = true;
        };
        hit.MouseMove += (_, e) => { if (hit.IsMouseCaptured) Drag(e.GetPosition(_track).X); };
        hit.MouseLeftButtonUp += (_, e) =>
        {
            if (!hit.IsMouseCaptured) return;
            hit.ReleaseMouseCapture();
            if (_preview is double target) _store.Seek(target);
            _preview = null;
            if (!hit.IsMouseOver) _thickness.To(5, IslandMotion.Quick);
            Editing?.Invoke(false);
            Refresh();
            e.Handled = true;
        };

        _tick = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(1) };
        _tick.Tick += (_, _) => Refresh();
        this.WhileLoaded(store, (_, e) => { if (e.PropertyName is nameof(PlayerStore.Snapshot)) Refresh(); }, Refresh);
        Unloaded += (_, _) => _tick.Stop();
        IsVisibleChanged += (_, _) => Refresh();
        _track.SizeChanged += (_, _) => Refresh();
    }

    private void Drag(double x)
    {
        var width = Math.Max(_track.ActualWidth, 1);
        _preview = Math.Clamp(x / width, 0, 1) * _store.Duration;
        Refresh();
    }

    private void Refresh()
    {
        var now = DateTime.UtcNow;
        var duration = _store.Duration;
        var elapsed = _preview ?? _store.Elapsed(now);
        _elapsed.Text = TimeText.Format(elapsed);
        _remaining.Text = duration > 0 ? TimeText.Remaining(elapsed, duration) : "--:--";
        var fraction = duration > 0 ? Math.Clamp(elapsed / duration, 0, 1) : 0;
        _fill.Width = Math.Max(_track.ActualWidth * fraction, 0);
        _fill.Height = double.NaN;
        _tick.Stop();
        // Next wake: when the next second label changes or the bar moves half a pixel.
        if (!IsVisible || !IsLoaded || _preview is not null || _store.Snapshot?.Timing is not { } timing) return;
        var pixelsPerSecond = duration > 0 ? _track.ActualWidth / duration : 0;
        var steps = (int)Math.Clamp(Math.Ceiling(pixelsPerSecond * 2), 1, 30);
        if (timing.NextTick(now, steps) is not DateTime next) return;
        _tick.Interval = TimeSpan.FromMilliseconds(Math.Max((next - now).TotalMilliseconds + 2, 15));
        _tick.Start();
    }
}

/// The line being sung, under the artist, when the song has synced lyrics. Changes only at
/// line boundaries (one timer per line).
public sealed class LiveLyricLine : Border
{
    private readonly PlayerStore _store;
    private readonly TextBlock _text;
    private readonly DispatcherTimer _timer = new(DispatcherPriority.Render);
    private int? _shown = -1;

    public LiveLyricLine(PlayerStore store)
    {
        _store = store;
        _text = Ui.Label("", 12, FontWeights.SemiBold, Ui.Frozen(Color.FromArgb(220, 255, 255, 255)));
        Child = _text;
        Margin = new Thickness(0, 1, 0, 0);
        _timer.Tick += (_, _) => Refresh();
        this.WhileLoaded(store, (_, e) => { if (e.PropertyName is nameof(PlayerStore.Lyrics) or nameof(PlayerStore.Snapshot)) Refresh(); }, Refresh);
        Unloaded += (_, _) => _timer.Stop();
        IsVisibleChanged += (_, _) => Refresh();
        Refresh();
    }

    private void Refresh()
    {
        _timer.Stop();
        if (_store.Lyrics is not LyricsState.Synced synced || !AppSettings.Shared.ShowIslandLyrics)
        {
            Visibility = Visibility.Collapsed;
            return;
        }
        Visibility = Visibility.Visible;
        var now = DateTime.UtcNow;
        var position = _store.LyricsPosition(now);
        var index = LRCParser.ActiveIndex(synced.Lines, position);
        if (index != _shown)
        {
            _shown = index;
            var line = index is int i ? synced.Lines[i] : null;
            _text.Text = line is null ? "" : line.IsInterlude ? "• • •" : line.Text;
            if (IsLoaded && IsVisible) Materialize.In(_text, 0);
        }
        if (!IsVisible || !IsLoaded || !_store.IsPlaying) return;
        var nextIndex = (index ?? -1) + 1;
        if (nextIndex >= synced.Lines.Count || _store.Snapshot?.Timing is not { } timing) return;
        // ActiveIndex leads by 0.15 s; wake just as the next line becomes active.
        if (timing.DateReaching(synced.Lines[nextIndex].Start - 0.15 - AppSettings.Shared.LyricsOffset) is not DateTime at) return;
        _timer.Interval = TimeSpan.FromMilliseconds(Math.Max((at - now).TotalMilliseconds + 5, 20));
        _timer.Start();
    }
}

/// The closed island with music: the cover on the left, the bars on the right.
public sealed class CompactPlayerView : Grid
{
    public CompactPlayerView(PlayerStore store, IslandMetrics metrics, Action expand)
    {
        Width = metrics.CompactWidth;
        Height = metrics.CompactHeight;
        Margin = new Thickness(0);
        var art = new ArtworkView(metrics.CompactHeight - 9, 7) { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(5, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        var bars = new EqualizerBars(20, 13) { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 11, 0), VerticalAlignment = VerticalAlignment.Center };
        Children.Add(art);
        Children.Add(bars);
        Background = Ui.Clear;
        void Update()
        {
            art.Source = store.Artwork;
            bars.Color = store.Accent;
            bars.IsPlaying = store.IsPlaying;
        }
        this.WhileLoaded(store, (_, e) => { if (e.PropertyName is nameof(PlayerStore.Artwork) or nameof(PlayerStore.Accent) or nameof(PlayerStore.IsPlaying)) Update(); }, Update);
        Update();
        MouseLeftButtonUp += (_, _) => expand();
    }
}

/// The open island's Now Playing card: cover, title, artist, the sung line, bars and scrubber.
public sealed class PlayerCardView : Grid
{
    public InlineScrubber Scrubber { get; }

    public PlayerCardView(PlayerStore store, IslandMetrics metrics, Action openPlayer)
    {
        Width = metrics.ExpandedSize.Width;
        Height = metrics.ExpandedSize.Height;
        var stack = new StackPanel { Margin = new Thickness(24, 0, 24, 0), VerticalAlignment = VerticalAlignment.Center };
        var row = new Grid { Margin = new Thickness(0, 0, 0, 10) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(54) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(13) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var art = new ArtworkView(54, 13) { Cursor = Cursors.Hand, ToolTip = "Open Now Playing" };
        var artHolder = new Border
        {
            Child = art,
            Effect = new DropShadowEffect { Color = Colors.Black, Opacity = 0.4, BlurRadius = 16, ShadowDepth = 4, Direction = 270, RenderingBias = RenderingBias.Performance },
        };
        art.MouseLeftButtonUp += (_, _) => openPlayer();
        var title = new MarqueeText(15, FontWeights.SemiBold, Ui.White);
        var subtitle = new MarqueeText(13, FontWeights.Normal, Ui.Frozen(Color.FromArgb(158, 255, 255, 255)));
        var lyric = new LiveLyricLine(store);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { title, subtitle, lyric }, Background = Ui.Clear };
        texts.MouseLeftButtonUp += (_, _) => openPlayer();
        var bars = new EqualizerBars(26, 20) { VerticalAlignment = VerticalAlignment.Center };
        SetColumn(artHolder, 0);
        SetColumn(texts, 2);
        SetColumn(bars, 4);
        row.Children.Add(artHolder);
        row.Children.Add(texts);
        row.Children.Add(bars);
        Scrubber = new InlineScrubber(store);
        stack.Children.Add(row);
        stack.Children.Add(Scrubber);
        Children.Add(stack);
        void Update()
        {
            art.Source = store.Artwork;
            title.Text = store.Title;
            subtitle.Text = store.Subtitle;
            bars.Color = store.Accent;
            bars.IsPlaying = store.IsPlaying;
        }
        this.WhileLoaded(store, (_, e) =>
        {
            if (e.PropertyName is nameof(PlayerStore.Artwork) or nameof(PlayerStore.Title) or nameof(PlayerStore.Subtitle)
                or nameof(PlayerStore.Accent) or nameof(PlayerStore.IsPlaying)) Update();
        }, Update);
        Update();
    }
}

/// The floating capsule under the open card: sound output on the left, play controls in the
/// middle, Control Center on the right.
public sealed class CapsuleRow : Grid
{
    public GlyphButton Output { get; }
    public GlyphButton Controls { get; }

    public CapsuleRow(PlayerStore store, IslandMetrics metrics)
    {
        Width = metrics.ControlsSize.Width;
        Height = metrics.ControlsSize.Height;
        Output = new GlyphButton(Ui.Speakers, 14, 30, "Sound output") { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(11, 0, 0, 0) };
        Controls = new GlyphButton(Ui.Controls, 14, 30, "Control Center") { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 11, 0) };
        Children.Add(Output);
        Children.Add(new TransportRow(store, 0.8));
        Children.Add(Controls);
    }
}
