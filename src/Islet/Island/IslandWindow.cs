using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shell;
using System.Windows.Threading;
using Islet.Core;
using Islet.Media;
using Islet.Native;
using Islet.Settings;

namespace Islet.Island;

/// The Dynamic Island: a black pill under the top edge of the screen that springs open into
/// a live Now Playing card, and briefly shows system events such as charging.
///
/// Every state's content is laid out once at its final size and pinned to the top; only the
/// island's outline animates and reveals it, so content never drifts mid-morph.
///
/// Battery: the window is DWM-composed (no layered-window readback), its hit area is a window
/// region around the island (clicks elsewhere go straight to the apps below, with no global
/// mouse hook), and nothing renders unless a spring, the bars or a marquee is moving.
public sealed class IslandWindow : Window
{
    private readonly IslandModel _model;
    private readonly PlayerStore _store;
    private readonly AppSettings _settings;
    private readonly Canvas _root = new();
    private readonly Canvas _stage = new();
    private readonly Border _card = new() { Background = Ui.IslandBlack, ClipToBounds = false };
    private readonly Canvas _cardContent = new() { ClipToBounds = false };
    private readonly RectangleGeometry _cardClip = new();
    private readonly Border _shadow = new() { Background = Ui.IslandBlack };
    private readonly DropShadowEffect _shadowEffect = new() { Color = Colors.Black, Direction = 270, RenderingBias = RenderingBias.Performance };
    private readonly Border _capsule = new() { Background = Ui.IslandBlack };
    private readonly ScaleTransform _capsuleScale = new(1, 1);
    private readonly ScaleTransform _stageScale = new(1, 1);
    private readonly TranslateTransform _stageShift = new();
    private readonly System.Windows.Shapes.Ellipse _privacyDot = new() { Width = 6, Height = 6, Opacity = 0 };

    // Geometry springs (DIPs).
    private readonly Spring _width = new(112), _height = new(28), _radius = new(14);
    private readonly Spring _capsuleWidth = new(0), _capsuleHeight = new(0), _capsuleY = new(0), _capsuleOpacity = new(0);
    private readonly Spring _hoverScale = new(1), _bumpScale = new(1), _tuck = new(0), _shake = new(0), _visible = new(1);

    private FrameworkElement? _content;
    private string _contentKey = "";
    private CapsuleRow? _capsuleRow;
    private nint _hwnd;
    private double _dpi = 1;

    public event Action? OpenPlayer;
    public event Action<LevelKind, double>? LevelDragged;
    public event Action? OutputClicked;
    public Func<FrameworkElement>? ControlCenterFactory { get; set; }

    public IslandWindow(IslandModel model, PlayerStore store, AppSettings settings)
    {
        _model = model;
        _store = store;
        _settings = settings;
        Title = "Islet";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Focusable = false;
        Background = Brushes.Transparent;
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            GlassFrameThickness = new Thickness(-1), CaptionHeight = 0, ResizeBorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false,
        });
        Width = model.Metrics.WindowSize.Width;
        Height = model.Metrics.WindowSize.Height;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.ClearType);
        UseLayoutRounding = true;

        _card.Child = _cardContent;
        _cardContent.Clip = _cardClip;
        _shadow.Effect = _shadowEffect;
        _capsule.RenderTransformOrigin = new Point(0.5, 0);
        _capsule.RenderTransform = _capsuleScale;
        _capsule.ClipToBounds = true;
        _stage.Children.Add(_capsule);
        _stage.Children.Add(_shadow);
        _stage.Children.Add(_card);
        _stage.Children.Add(_privacyDot);
        _stage.RenderTransform = new TransformGroup { Children = { _stageScale, _stageShift } };
        _root.Children.Add(_stage);
        Content = _root;

        foreach (var spring in new[] { _width, _height, _radius, _capsuleWidth, _capsuleHeight, _capsuleY, _capsuleOpacity, _hoverScale, _bumpScale, _tuck, _shake, _visible })
            spring.Moved += MarkDirty;
        SpringDriver.Frame += () => { if (_dirty) Draw(); };
        SpringDriver.Animating += moving => { if (!moving) UpdateRegion(final: true); };

        model.PropertyChanged += ModelChanged;
        store.PropertyChanged += StoreChanged;
        store.TrackChanged += Pulse;
        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppSettings.IslandWidthScale) or nameof(AppSettings.IslandHeightScale))
            {
                _model.Metrics = IslandMetrics.Make(_settings);
                _contentKey = "";
                Refresh();
            }
            if (e.PropertyName is nameof(AppSettings.IslandClock)) Refresh();
        };

        MouseMove += (_, e) => PointerMoved(e.GetPosition(_root));
        MouseLeave += (_, _) => PointerLeft();
        AllowDrop = true;
        DragEnter += (_, e) =>
        {
            if (!_settings.ShelfEnabled || !e.Data.GetDataPresent(DataFormats.FileDrop)) return;
            CancelPending();
            SetPresentation(IslandPresentation.Shelf);
        };

        SourceInitialized += (_, _) => Configure();
        Loaded += (_, _) =>
        {
            Reposition();
            Refresh(snap: true);
        };
    }

    // MARK: - Window setup

    private void Configure()
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        var source = HwndSource.FromHwnd(_hwnd);
        source.CompositionTarget.BackgroundColor = Colors.Transparent;
        source.AddHook(WndProc);
        // A tool window that never activates: clicks work, focus stays where it was.
        Win32.AddExStyle(_hwnd, Win32.WS_EX_TOOLWINDOW | Win32.WS_EX_NOACTIVATE);
        var margins = new Win32.MARGINS { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        Win32.DwmExtendFrameIntoClientArea(_hwnd, ref margins);
        var corner = Win32.DWMWCP_DONOTROUND;
        Win32.DwmSetWindowAttribute(_hwnd, Win32.DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));
        var border = Win32.DWMWA_COLOR_NONE;
        Win32.DwmSetWindowAttribute(_hwnd, Win32.DWMWA_BORDER_COLOR, ref border, sizeof(int));
        var noTransitions = 1;
        Win32.DwmSetWindowAttribute(_hwnd, Win32.DWMWA_TRANSITIONS_FORCEDISABLED, ref noTransitions, sizeof(int));
        _dpi = source.CompositionTarget.TransformToDevice.M11;
    }

    private nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        switch (msg)
        {
            case Win32.WM_MOUSEACTIVATE:
                handled = true;
                return Win32.MA_NOACTIVATE;
            case Win32.WM_DPICHANGED:
                _dpi = (wParam.ToInt64() & 0xFFFF) / 96.0;
                Dispatcher.BeginInvoke(Reposition);
                break;
            case Win32.WM_DISPLAYCHANGE:
                Dispatcher.BeginInvoke(Reposition);
                break;
            case 0x020E: // WM_MOUSEHWHEEL
                Scrolled(0, (short)((wParam.ToInt64() >> 16) & 0xFFFF));
                break;
            case 0x020A: // WM_MOUSEWHEEL
                Scrolled((short)((wParam.ToInt64() >> 16) & 0xFFFF), 0);
                break;
        }
        return 0;
    }

    /// Top centre of the primary display's work area (below a top taskbar, if there is one).
    public void Reposition()
    {
        if (_hwnd == 0) return;
        var monitor = Win32.MonitorFromPoint(new Win32.POINT(), Win32.MONITOR_DEFAULTTOPRIMARY);
        var info = new Win32.MONITORINFO { cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Win32.MONITORINFO>() };
        if (!Win32.GetMonitorInfo(monitor, ref info)) return;
        if (Win32.GetDpiForMonitor(monitor, 0, out var dpiX, out _) == 0) _dpi = dpiX / 96.0;
        var size = _model.Metrics.WindowSize;
        var width = (int)Math.Round(size.Width * _dpi);
        var height = (int)Math.Round(size.Height * _dpi);
        var x = info.rcMonitor.Left + (info.rcMonitor.Right - info.rcMonitor.Left - width) / 2;
        var y = info.rcWork.Top;
        Win32.SetWindowPos(_hwnd, Win32.HWND_TOPMOST, x, y, width, height, Win32.SWP_NOACTIVATE | Win32.SWP_SHOWWINDOW);
        UpdateRegion(final: true);
    }

    /// Topmost again, e.g. after a full-screen app or the Start menu took the top of the stack.
    public void Raise()
    {
        if (_hwnd != 0) Win32.SetWindowPos(_hwnd, Win32.HWND_TOPMOST, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
    }

    // MARK: - State → targets

    private bool HasTrack => _store.HasTrack && _model.ShowsTrack;
    private bool IsExpanded => _model.Presentation == IslandPresentation.Expanded && HasTrack && _model.Activity is null;
    private bool ShowsTimer => _model.TimerEnd is not null && _model.Activity is null && _model.Presentation == IslandPresentation.Compact;
    private bool ShowsClock => _settings.IslandClock && !HasTrack && _model.TimerEnd is null && _model.Activity is null && _model.Presentation == IslandPresentation.Compact;
    private bool Busy => HasTrack || _model.TimerEnd is not null || ShowsClock;

    private IslandActivity? _lastActivity;

    private void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(IslandModel.Presentation) or nameof(IslandModel.Activity) or nameof(IslandModel.TimerEnd)
                or nameof(IslandModel.ShowsTrack) or nameof(IslandModel.Metrics):
                if (e.PropertyName == nameof(IslandModel.Activity) && _model.Activity is { } a && !a.SameKind(_lastActivity)) Pulse();
                Refresh();
                break;
            case nameof(IslandModel.IsHovered):
                var hovered = _model.IsHovered && _model.Presentation == IslandPresentation.Compact && _model.Activity is null;
                _hoverScale.To(hovered ? 1.045 : 1, IslandMotion.Subtle);
                break;
            case nameof(IslandModel.IsTucked):
                _tuck.To(_model.IsTucked ? 1 : 0, IslandMotion.Subtle);
                UpdateRegion(final: false);
                break;
            case nameof(IslandModel.IsSuppressed):
                _visible.To(_model.IsSuppressed ? 0 : 1, IslandMotion.Quick);
                UpdateRegion(final: false);
                break;
            case nameof(IslandModel.Shakes):
                ShakeOnce();
                break;
            case nameof(IslandModel.MicActive) or nameof(IslandModel.CameraActive):
                UpdatePrivacyDot();
                break;
        }
    }

    private void StoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(PlayerStore.HasTrack))
        {
            // Music stopped while open: start compact next time, not popped open.
            if (!HasTrack && _model.Presentation == IslandPresentation.Expanded) _model.Presentation = IslandPresentation.Compact;
            if (_store.HasTrack && _store.IsPlaying) _model.ShowsTrack = true;
            Refresh();
        }
        else if (e.PropertyName == nameof(PlayerStore.IsPlaying))
        {
            if (_store.IsPlaying && !_model.ShowsTrack) _model.ShowsTrack = true;
        }
    }

    /// Recomputes the island's target shape and content, and springs toward it.
    public void Refresh(bool snap = false)
    {
        var m = _model.Metrics;
        var activity = _model.Activity;
        var sized = m.SizeFor(_model.Presentation, Busy, activity);
        var card = ShowsTimer || ShowsClock ? new Size(m.TimerWidth, sized.Height) : sized;
        var radius = m.CornerRadius(_model.Presentation, Busy, activity);
        var expanded = IsExpanded;
        var spec = activity is not null || _lastActivity is not null
            ? IslandMotion.Activity
            : _model.Presentation != IslandPresentation.Compact || card.Width > _width.Target + 1 ? IslandMotion.Open : IslandMotion.Close;
        _lastActivity = activity;

        // The transport capsule: hidden behind the card, it springs out a beat after the card opens.
        var showsCapsule = HasTrack && activity is null;
        var capsule = expanded ? m.ControlsSize : new Size(card.Width * 0.6, card.Height * 0.8);
        var capsuleY = expanded ? card.Height + m.ControlsGap : (card.Height - capsule.Height) / 2;
        if (snap)
        {
            _width.Snap(card.Width); _height.Snap(card.Height); _radius.Snap(radius);
            _capsuleWidth.Snap(capsule.Width); _capsuleHeight.Snap(capsule.Height); _capsuleY.Snap(capsuleY);
            _capsuleOpacity.Snap(expanded ? 1 : 0);
        }
        else
        {
            _width.To(card.Width, spec);
            _height.To(card.Height, spec);
            _radius.To(radius, spec);
            var capsuleSpec = expanded ? IslandMotion.Open : IslandMotion.Close;
            var capsuleDelay = expanded && !IslandMotion.Reduced ? 0.05 : 0;
            _capsuleWidth.To(capsule.Width, capsuleSpec, capsuleDelay);
            _capsuleHeight.To(capsule.Height, capsuleSpec, capsuleDelay);
            _capsuleY.To(capsuleY, capsuleSpec, capsuleDelay);
            // Its own fade: shown once it has mostly cleared the card, gone before it slides back.
            _capsuleOpacity.To(expanded ? 1 : 0, expanded ? new SpringSpec(0.2, 0) : new SpringSpec(0.08, 0), expanded && !IslandMotion.Reduced ? 0.13 : 0);
        }
        _capsule.Visibility = showsCapsule ? Visibility.Visible : Visibility.Hidden;
        _capsule.IsHitTestVisible = expanded;
        if (_capsuleRow is null || _capsuleRow.Width != m.ControlsSize.Width)
        {
            _capsuleRow = new CapsuleRow(_store, m);
            _capsuleRow.Output.Click += () => OutputClicked?.Invoke();
            _capsuleRow.Controls.Click += () => SetPresentation(IslandPresentation.Controls);
            _capsule.Child = _capsuleRow;
            _capsule.Width = m.ControlsSize.Width;
            _capsule.Height = m.ControlsSize.Height;
            _capsule.CornerRadius = new CornerRadius(m.ControlsSize.Height / 2);
        }
        SwapContent();
        UpdatePrivacyDot();
        UpdateRegion(final: snap);
        MarkDirty();
        if (snap) Draw();
    }

    private string ContentKey()
    {
        return _model.Activity switch
        {
            IslandActivity.Level l => "level:" + l.Kind,
            { } a => a.GetType().Name + ":" + a.GetHashCode(),
            null => _model.Presentation switch
            {
                IslandPresentation.Controls => "controls",
                IslandPresentation.Shelf => "shelf",
                IslandPresentation.Phone => "phone",
                _ when IsExpanded => "expanded",
                _ when ShowsTimer => "timer",
                _ when HasTrack => "compact",
                _ when ShowsClock => "clock",
                _ => "idle",
            },
        } + "@" + _model.Metrics.GetHashCode();
    }

    private void SwapContent()
    {
        var key = ContentKey();
        if (key == _contentKey) return;
        _contentKey = key;
        var m = _model.Metrics;
        var (view, delay) = BuildContent(m);
        if (_content is { } old)
        {
            Materialize.Out(old, () => _cardContent.Children.Remove(old));
        }
        _content = view;
        _cardContent.Children.Add(view);
        Materialize.In(view, delay);
        PositionContent();
    }

    private (FrameworkElement View, double Delay) BuildContent(IslandMetrics m)
    {
        switch (_model.Activity)
        {
            case IslandActivity.Charging c: return (new ChargingView(m, c.Battery, _settings.BatteryIconStyle), 0.04);
            case IslandActivity.Unlocked: return (new UnlockView(m), 0.04);
            case IslandActivity.Level: return (new LevelView(_model, (k, v) => LevelDragged?.Invoke(k, v)), 0.04);
            case IslandActivity.LowBattery low: return (new LowBatteryView(m, low.Percent), 0.04);
            case IslandActivity.TimerDone: return (new SimplePillView(m.ChargingWidth, m.CompactHeight, Ui.Timer, Ui.Orange, "Timer Done"), 0.04);
            case IslandActivity.Focus f: return (new SimplePillView(m.ChargingWidth, m.CompactHeight, Ui.Moon, Ui.Frozen(Color.FromRgb(94, 92, 230)), f.Name, f.On ? "On" : "Off"), 0.04);
            case IslandActivity.Headphones h:
                return (new CardView(m.HeadphoneCardWidth, m.CompactHeight + 76, Ui.Headphones, Ui.White, h.Name, h.Battery is int b ? $"Connected · {b}%" : "Connected"), 0.08);
            case IslandActivity.Agent a:
                var (glyph, tint, title) = a.Event.Kind switch
                {
                    AgentEvent.EventKind.Permission => (Ui.Warning, Ui.Orange, "Needs your permission"),
                    AgentEvent.EventKind.Waiting => (Ui.Terminal, Ui.White, "Waiting for you"),
                    _ => (Ui.Check, Ui.Green, "Finished"),
                };
                return (new CardView(m.HeadphoneCardWidth, m.CompactHeight + 58, glyph, tint,
                    a.Event.Project.Length > 0 ? $"{a.Event.Project} · {title}" : title, a.Event.Message, click: () => AgentClicked?.Invoke(a.Event)), 0.08);
            case IslandActivity.Portal p:
                return (new CardView(m.HeadphoneCardWidth, m.CompactHeight + 84, Ui.Phone, Ui.White, p.Title, p.Detail), 0.06);
            case IslandActivity.Phone p:
                return (new CardView(m.HeadphoneCardWidth, m.CompactHeight + 66, Ui.Phone, Ui.White, p.Title, p.Detail), 0.06);
        }
        switch (_model.Presentation)
        {
            case IslandPresentation.Controls when ControlCenterFactory is not null:
                var controls = ControlCenterFactory();
                controls.Width = m.ExpandedSize.Width;
                controls.Height = m.ControlsHeight;
                return (controls, 0.05);
            case IslandPresentation.Shelf when ShelfFactory is not null:
                var shelf = ShelfFactory();
                shelf.Width = m.ExpandedSize.Width;
                shelf.Height = m.ShelfHeight;
                return (shelf, 0.05);
        }
        if (IsExpanded)
        {
            var card = new PlayerCardView(_store, m, () => OpenPlayer?.Invoke());
            card.Scrubber.Editing += on =>
            {
                _model.IsInteracting = on;
                if (!on) Recheck();
            };
            return (card, 0.05);
        }
        if (ShowsTimer && _model.TimerEnd is DateTime end) return (new TimerCompactView(m, end), 0.04);
        if (HasTrack) return (new CompactPlayerView(_store, m, () => SetPresentation(IslandPresentation.Expanded)), 0.08);
        if (ShowsClock)
        {
            var clock = new IdleClockView(m);
            clock.MouseLeftButtonUp += (_, _) => SetPresentation(IslandPresentation.Controls);
            return (clock, 0.08);
        }
        // The resting island: a click opens Control Center.
        var idle = new Border { Width = m.IdleWidth, Height = m.CompactHeight, Background = Ui.Clear };
        idle.MouseLeftButtonUp += (_, _) => SetPresentation(IslandPresentation.Controls);
        return (idle, 0);
    }

    public event Action<AgentEvent>? AgentClicked;
    public Func<FrameworkElement>? ShelfFactory { get; set; }

    // MARK: - Drawing (one pass per frame, only while something moves)

    private bool _dirty;
    private void MarkDirty()
    {
        _dirty = true;
        // Inside the frame loop the Frame event draws; outside it (a snap), the next dispatcher turn does.
        if (!SpringDriver.IsRunning && !_drawQueued)
        {
            _drawQueued = true;
            Dispatcher.BeginInvoke(DispatcherPriority.Render, () => { _drawQueued = false; if (_dirty) Draw(); });
        }
    }
    private bool _drawQueued;

    private void Draw()
    {
        _dirty = false;
        var m = _model.Metrics;
        var windowWidth = m.WindowSize.Width;
        double w = Math.Max(_width.Value, 1), h = Math.Max(_height.Value, 1), r = Math.Clamp(_radius.Value, 0, Math.Min(w, h) / 2);
        var left = (windowWidth - w) / 2;
        var top = m.TopInset;

        Canvas.SetLeft(_card, left);
        Canvas.SetTop(_card, top);
        _card.Width = w;
        _card.Height = h;
        _card.CornerRadius = new CornerRadius(r);
        _cardClip.Rect = new Rect(0, 0, w, h);
        _cardClip.RadiusX = _cardClip.RadiusY = r;
        PositionContent();

        Canvas.SetLeft(_shadow, left);
        Canvas.SetTop(_shadow, top);
        _shadow.Width = w;
        _shadow.Height = h;
        _shadow.CornerRadius = new CornerRadius(r);
        var open = Math.Clamp((h - m.CompactHeight) / Math.Max(m.ExpandedSize.Height - m.CompactHeight, 1), 0, 1);
        _shadowEffect.BlurRadius = 12 + 40 * open;
        _shadowEffect.ShadowDepth = 2 + 10 * open;
        _shadowEffect.Opacity = 0.22 + 0.28 * open;

        // The capsule's content is laid out at full size and scaled, so it never re-lays out.
        var cw = m.ControlsSize.Width;
        var ch = m.ControlsSize.Height;
        _capsuleScale.ScaleX = Math.Max(_capsuleWidth.Value, 0.01) / cw;
        _capsuleScale.ScaleY = Math.Max(_capsuleHeight.Value, 0.01) / ch;
        Canvas.SetLeft(_capsule, (windowWidth - cw) / 2);
        Canvas.SetTop(_capsule, top + _capsuleY.Value);
        _capsule.Opacity = Math.Clamp(_capsuleOpacity.Value, 0, 1);
        if (_capsuleRow is not null) _capsuleRow.Opacity = _capsule.Opacity;

        Canvas.SetLeft(_privacyDot, left + w + 6);
        Canvas.SetTop(_privacyDot, top + (h - 6) / 2);

        // Stage: hover lift, the track-change bump, tuck away, shake, hide.
        var tuck = _tuck.Value;
        var scale = _hoverScale.Value * _bumpScale.Value * (1 - 0.25 * tuck);
        _stageScale.CenterX = windowWidth / 2;
        _stageScale.CenterY = top;
        _stageScale.ScaleX = _stageScale.ScaleY = scale;
        _stageShift.X = ShakeOffset();
        _stageShift.Y = -18 * tuck;
        _stage.Opacity = Math.Clamp(_visible.Value * (1 - tuck), 0, 1);
    }

    private void PositionContent()
    {
        if (_content is null) return;
        foreach (UIElement child in _cardContent.Children)
        {
            if (child is not FrameworkElement element) continue;
            Canvas.SetLeft(element, (_card.Width - element.Width) / 2);
            Canvas.SetTop(element, 0);
        }
    }

    // MARK: - Hit area (window region)

    private Rect IslandRect()
    {
        var m = _model.Metrics;
        var activity = _model.Activity;
        var sized = m.SizeFor(_model.Presentation, Busy, activity);
        var card = ShowsTimer || ShowsClock ? new Size(m.TimerWidth, sized.Height) : sized;
        var height = card.Height;
        if (IsExpanded) height += m.ControlsGap + m.ControlsSize.Height;
        return new Rect((m.WindowSize.Width - card.Width) / 2, m.TopInset, card.Width, height);
    }

    private Rect CurrentRect()
    {
        var m = _model.Metrics;
        var w = _width.Value;
        var h = Math.Max(_height.Value, _capsuleOpacity.Value > 0.01 ? _capsuleY.Value + _capsuleHeight.Value : 0);
        return new Rect((m.WindowSize.Width - w) / 2, m.TopInset, w, h);
    }

    /// The window only takes the pointer over the island: everywhere else, clicks go to the
    /// apps beneath. While moving it covers both the old and new shapes so nothing is clipped.
    private void UpdateRegion(bool final)
    {
        if (_hwnd == 0) return;
        if (_model.IsSuppressed || (_model.IsTucked && final))
        {
            Win32.SetWindowRgn(_hwnd, Win32.CreateRectRgn(0, 0, 0, 0), true);
            return;
        }
        var rect = IslandRect();
        if (!final) rect.Union(CurrentRect());
        // Room for the shadow and the hover lift; the hover test itself uses the exact shape.
        var open = rect.Height > _model.Metrics.CompactHeight + 1;
        rect.Inflate(open ? 22 : 10, 0);
        rect = new Rect(rect.X, Math.Max(rect.Y - 8, 0), rect.Width, rect.Height + (open ? 34 : 12) + 8);
        var region = Win32.CreateRectRgn(
            (int)Math.Floor(rect.Left * _dpi), (int)Math.Floor(rect.Top * _dpi),
            (int)Math.Ceiling(rect.Right * _dpi), (int)Math.Ceiling(rect.Bottom * _dpi));
        // The system owns the region after this call.
        Win32.SetWindowRgn(_hwnd, region, true);
    }

    // MARK: - Hover and clicks

    private DispatcherTimer? _pending;
    private IslandPresentation? _pendingTarget;

    private void PointerMoved(Point p)
    {
        if (_model.IsTucked || _model.IsSuppressed) return;
        if (Mouse.LeftButton == MouseButtonState.Pressed && _model.IsInteracting) return;
        var hot = IslandRect();
        hot.Inflate(6, 6);
        var isHot = hot.Contains(p);
        if (_model.IsHovered != isHot) _model.IsHovered = isHot;
        if (!isHot) { Unhovered(); return; }
        if (_model.Activity?.HoldsHover == true) { CancelPending(); return; }
        if (_model.Presentation != IslandPresentation.Compact || !_settings.ExpandOnHover) { CancelPending(); return; }
        if (HasTrack) Schedule(IslandPresentation.Expanded, 60);
        else if (_settings.ShelfEnabled && ShelfHasItems?.Invoke() == true) Schedule(IslandPresentation.Shelf, 60);
        else if (_model.TimerEnd is null && _model.Activity is null) Schedule(IslandPresentation.Controls, 60);
        else CancelPending();
    }

    private void PointerLeft()
    {
        if (_model.IsHovered) _model.IsHovered = false;
        Unhovered();
    }

    private void Unhovered()
    {
        if (_model.Presentation != IslandPresentation.Compact && !_model.IsInteracting && !_debugPinned)
            Schedule(IslandPresentation.Compact, 320);
        else CancelPending();
    }

    /// After a drag inside the island ends, look at where the pointer is now.
    private void Recheck()
    {
        Win32.GetCursorPos(out var screen);
        if (_hwnd == 0) return;
        Win32.GetWindowRect(_hwnd, out var bounds);
        PointerMoved(new Point((screen.X - bounds.Left) / _dpi, (screen.Y - bounds.Top) / _dpi));
    }

    public Func<bool>? ShelfHasItems { get; set; }
    private bool _debugPinned;
    public void Pin(bool pinned) => _debugPinned = pinned;

    private void Schedule(IslandPresentation target, int milliseconds)
    {
        if (_pendingTarget == target) return;
        CancelPending();
        _pendingTarget = target;
        _pending = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(milliseconds) };
        _pending.Tick += (_, _) => SetPresentation(target);
        _pending.Start();
    }

    private void CancelPending()
    {
        _pending?.Stop();
        _pending = null;
        _pendingTarget = null;
    }

    public void SetPresentation(IslandPresentation presentation)
    {
        CancelPending();
        if (_model.Presentation == presentation) return;
        if (presentation == IslandPresentation.Expanded && !HasTrack) return;
        // Opening takes over from a transient activity.
        if (presentation != IslandPresentation.Compact) ActivityCleared?.Invoke();
        _model.Presentation = presentation;
    }

    public event Action? ActivityCleared;

    // MARK: - Two fingers: up tucks the island away, sideways skips

    private readonly TwoFingerSwipe _swipe = new();
    private long _lastScroll;
    private DispatcherTimer? _untuck;
    private long _tuckedAt;

    private void Scrolled(double vertical, double horizontal)
    {
        if (_model.IsTucked) return;
        // Wheel notches (multiples of 120) are a mouse, not fingers on a touchpad.
        if ((vertical != 0 && vertical % 120 == 0) || (horizontal != 0 && horizontal % 120 == 0)) return;
        var now = Environment.TickCount64;
        if (now - _lastScroll > 250) _swipe.Begin();
        _lastScroll = now;
        var canSkip = _settings.SwipeToSkip && HasTrack && Mouse.LeftButton != MouseButtonState.Pressed
                      && _model.Presentation is IslandPresentation.Compact or IslandPresentation.Expanded;
        // Windows reports scrolling in content direction; flip to the direction the fingers move.
        // shortcut: assumes Windows' default "down motion scrolls up" touchpad setting; upgrade by reading
        // HKCU\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad\ScrollDirection.
        switch (_swipe.Move(-vertical / 4, -horizontal / 4, canSkip))
        {
            case TwoFingerSwipe.Action.Tuck: Tuck(); break;
            case TwoFingerSwipe.Action.Next: _store.Next(); break;
            case TwoFingerSwipe.Action.Previous: _store.Previous(); break;
        }
    }

    private void Tuck()
    {
        CancelPending();
        _model.Presentation = IslandPresentation.Compact;
        _model.IsTucked = true;
        _tuckedAt = Environment.TickCount64;
        // While tucked the window takes no pointer at all, so look at the cursor a few times a
        // second (only until it drops back) to know when the pointer has moved away.
        _untuck?.Stop();
        long awaySince = 0;
        _untuck = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(300) };
        _untuck.Tick += (_, _) =>
        {
            Win32.GetCursorPos(out var screen);
            Win32.GetWindowRect(_hwnd, out var bounds);
            var p = new Point((screen.X - bounds.Left) / _dpi, (screen.Y - bounds.Top) / _dpi);
            var near = IslandRect();
            near.Inflate(50, 50);
            var now = Environment.TickCount64;
            if (near.Contains(p)) { awaySince = 0; return; }
            if (awaySince == 0) awaySince = now;
            if (now - awaySince < 1200 || now - _tuckedAt < 2000) return;
            _untuck!.Stop();
            _model.IsTucked = false;
            UpdateRegion(final: true);
        };
        _untuck.Start();
    }

    // MARK: - Small motions

    /// The bump on a song change or a new activity (not while open).
    private void Pulse()
    {
        if (IsExpanded || IslandMotion.Reduced) return;
        _bumpScale.To(1.06, new SpringSpec(0.22, 0.5));
        var settle = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(160) };
        settle.Tick += (_, _) => { settle.Stop(); _bumpScale.To(1, new SpringSpec(0.4, 0.3)); };
        settle.Start();
    }

    private void ShakeOnce()
    {
        _shake.Snap(0);
        _shake.To(1, new SpringSpec(0.5, 0));
    }

    /// Three quick swings that die away, like the iPhone's padlock after a wrong attempt.
    private double ShakeOffset()
    {
        var progress = _shake.Value;
        if (progress <= 0 || progress >= 1) return 0;
        return 11 * (1 - progress) * Math.Sin(progress * Math.PI * 6);
    }

    private void UpdatePrivacyDot()
    {
        var show = _settings.PrivacyDots && (_model.MicActive || _model.CameraActive) && _model.Activity is null && _model.Presentation == IslandPresentation.Compact;
        _privacyDot.Fill = _model.CameraActive ? Ui.Green : Ui.Orange;
        _privacyDot.Opacity = show ? 1 : 0;
    }
}
