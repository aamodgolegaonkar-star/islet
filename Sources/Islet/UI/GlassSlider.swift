import AppKit
import IOKit
import SwiftUI

// MARK: - Glass helpers

extension EnvironmentValues {
    /// True only for offscreen PNG rendering, where Liquid Glass and AppKit views can't draw.
    @Entry var isSnapshotRendering = false
    /// Views inside a glass surface use highlights instead of stacking more glass.
    @Entry var insideGlass = false
    /// Self-test hook: sliders report their window-space frames here.
    @Entry var sliderProbe: SliderProbe?
}

/// Collects slider and transport-button frames (top-left window coordinates) during
/// `--slider-selftest`.
@MainActor
final class SliderProbe {
    var frames: [CGRect] = []
    var buttons: [String: CGRect] = [:]
}

extension View {
    /// Reports this control's frame to the self-test probe; nothing at all otherwise.
    func probeFrame(_ name: String) -> some View {
        modifier(ProbeFrame(name: name))
    }
}

private struct ProbeFrame: ViewModifier {
    let name: String
    @Environment(\.sliderProbe) private var probe

    func body(content: Content) -> some View {
        if let probe {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.buttons[name] = $0 }
        } else {
            content
        }
    }
}

private struct SnapshotSafeGlass<S: Shape>: ViewModifier {
    let glass: Glass
    let visible: Bool
    let shape: S
    @Environment(\.isSnapshotRendering) private var snapshot

    func body(content: Content) -> some View {
        if snapshot {
            content.background(shape.fill(.white.opacity(visible ? 0.16 : 0)))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

private struct GlassIdentity: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @Environment(\.isSnapshotRendering) private var snapshot

    func body(content: Content) -> some View {
        if snapshot { content } else { content.glassEffectID(id, in: namespace) }
    }
}

extension View {
    /// Liquid Glass in the app; a flat translucent stand-in when rendering snapshots.
    func snapshotSafeGlass(_ glass: Glass, visible: Bool = true, in shape: some Shape) -> some View {
        modifier(SnapshotSafeGlass(glass: glass, visible: visible, shape: shape))
    }

    /// Gives glass a stable identity so it morphs between layouts inside a container.
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        modifier(GlassIdentity(id: id, namespace: namespace))
    }
}

/// `GlassEffectContainer` (shared sampling, liquid merging and morphing of nearby glass);
/// a plain group when rendering snapshots.
struct GlassContainer<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.isSnapshotRendering) private var snapshot

    var body: some View {
        if snapshot {
            content
        } else {
            GlassEffectContainer(spacing: spacing) { content }
        }
    }
}

// MARK: - Slider

/// Apple's own Liquid Glass slider (AppKit `NSSlider`), the one System Settings uses: a
/// white pill knob that turns into a real refracting glass lens while dragged. Islet adds
/// the dial haptics, first-click handling for its never-active panels and the playback
/// callbacks. Offscreen snapshots get a drawn stand-in.
struct GlassSlider: View {
    enum Thumb {
        /// Always visible (sliders floating over content).
        case always
        /// Appears on hover (compact places like the island).
        case onHover
    }

    /// Current value in 0...1, driven by the model.
    var value: Double
    var tint: Color = .white
    /// Track thickness hint: 5 pt or less picks the small system slider.
    var restHeight: CGFloat = 6
    var activeHeight: CGFloat = 12
    /// Kept for call sites; the system slider draws its own track.
    var groove = false
    var thumb: Thumb = .onHover
    var onEditingChanged: (Bool) -> Void = { _ in }
    /// Live updates while dragging (volume). Scrubbers usually only commit.
    var onChange: ((Double) -> Void)?
    var onPreview: ((Double?) -> Void)?
    var onCommit: (Double) -> Void

    @Environment(\.sliderProbe) private var probe
    @Environment(\.isSnapshotRendering) private var snapshot

    private var small: Bool { restHeight <= 5 }

    var body: some View {
        Group {
            if snapshot {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2)).frame(height: small ? 4 : 6)
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: max(6, geo.size.width * min(max(value, 0), 1)), height: small ? 4 : 6)
                        Capsule().fill(.white)
                            .frame(width: small ? 18 : 22, height: small ? 12 : 16)
                            .offset(x: (geo.size.width - (small ? 18 : 22)) * min(max(value, 0), 1))
                    }
                    .frame(maxHeight: .infinity)
                }
            } else {
                SystemSlider(value: value, tint: NSColor(tint), size: small ? .small : .regular,
                             onEditingChanged: onEditingChanged, onChange: onChange,
                             onPreview: onPreview, onCommit: onCommit)
            }
        }
        .frame(height: small ? 20 : 26)
        // Near-invisible but not fully transparent: overlay windows pass clicks on
        // transparent pixels through to the app behind.
        .background(Color.black.opacity(0.012))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            guard let probe else { return }
            if !probe.frames.contains(frame) { probe.frames.append(frame) }
        }
    }
}

private struct SystemSlider: NSViewRepresentable {
    var value: Double
    var tint: NSColor
    var size: NSControl.ControlSize
    var onEditingChanged: (Bool) -> Void
    var onChange: ((Double) -> Void)?
    var onPreview: ((Double?) -> Void)?
    var onCommit: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> IsletSlider {
        let slider = IsletSlider(value: value, minValue: 0, maxValue: 1,
                                 target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.sendAction(on: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        slider.isContinuous = true
        slider.appearance = NSAppearance(named: .darkAqua)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: IsletSlider, context: Context) {
        context.coordinator.parent = self
        if slider.controlSize != size { slider.controlSize = size }
        if slider.trackFillColor != tint { slider.trackFillColor = tint }
        // Playback keeps moving the value; never fight the user's drag.
        if !slider.isTracking, abs(slider.doubleValue - value) > 0.0005 {
            slider.doubleValue = min(max(value, 0), 1)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SystemSlider?
        private var detent = 0

        private func step(_ slider: NSSlider) -> Int {
            Int((CGFloat(slider.doubleValue) * max(slider.bounds.width - 20, 1) / Haptics.detentSpacing)
                .rounded(.down))
        }

        /// AppKit sends the action for the press, every move and the release; the current
        /// event says which.
        @objc func changed(_ slider: IsletSlider) {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown?:
                slider.isTracking = true
                watchRelease(slider)
                detent = step(slider)
                Haptics.tap()
                parent?.onEditingChanged(true)
                report(slider)
            case .leftMouseUp?:
                report(slider)
                end(slider)
            default:
                if !slider.isTracking {
                    // Keyboard or accessibility: a single committed change.
                    parent?.onCommit(slider.doubleValue)
                    return
                }
                let next = step(slider)
                if next != detent {
                    detent = next
                    Haptics.detent()
                }
                report(slider)
            }
        }

        private func report(_ slider: NSSlider) {
            parent?.onPreview?(slider.doubleValue)
            parent?.onChange?(slider.doubleValue)
        }

        /// Watches for the release while a drag is on: pinned at an end the value stops
        /// changing and AppKit sends no action for the release, so the drag would never end
        /// (and the island would never close).
        private var releaseMonitor: Any?

        private func watchRelease(_ slider: IsletSlider) {
            stopWatching()
            releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self, weak slider] event in
                // After the slider has taken the release and settled its final value.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let slider else { return }
                        self.end(slider)
                    }
                }
                return event
            }
        }

        private func stopWatching() {
            if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor) }
            releaseMonitor = nil
        }

        private func end(_ slider: IsletSlider) {
            stopWatching()
            guard slider.isTracking else { return }
            slider.isTracking = false
            parent?.onCommit(slider.doubleValue)
            parent?.onPreview?(nil)
            parent?.onEditingChanged(false)
        }
    }
}

/// The system slider, taking the first click in Islet's never-active panels.
final class IsletSlider: NSSlider {
    /// True from the press until the release, so playback updates don't fight the drag.
    var isTracking = false

    // No mouse-event overrides: this slider tracks differently when a subclass overrides
    // them, and stops following the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Haptics

/// Trackpad feedback. Slider detents and button presses fire the trackpad motor at
/// force-click strength; if that private path is unavailable it falls back to the public
/// API's strongest pattern. A mouse has no haptics.
@MainActor
enum Haptics {
    /// Points of travel between slider detents (Settings), the same feel on every slider
    /// whatever its length.
    static var detentSpacing: CGFloat { CGFloat(LiveTuning.shared.detentSpacing) }
    /// Closer clicks blur into a buzz, so a fast flick skips some.
    private static let minimumGap: TimeInterval = 0.02
    private static var lastTap: TimeInterval = 0
    private static var lastClick: TimeInterval = 0

    /// A press. Several layers may report the same click; it is felt once.
    static func tap() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTap > 0.12 else { return }
        lastTap = now
        click()
    }

    /// Crossing a slider detent.
    static func detent() {
        click()
    }

    private static func click() {
        guard LiveTuning.shared.hapticsEnabled, TrackpadMotor.isSupported else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastClick >= minimumGap else { return }
        lastClick = now
        if !LiveTuning.shared.forceClick || !TrackpadMotor.shared.forceClick() {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
}

/// The built-in trackpad's haptic motor through the private MultitouchSupport framework —
/// the only way to reach force-click strength. Every symbol is looked up at run time; if
/// anything is missing or refuses, `forceClick()` returns false and the caller falls back.
/// Pulses go out on a background queue: each one blocks for 3–5 ms while the motor fires,
/// which on the main thread made slider drags stutter.
final class TrackpadMotor: @unchecked Sendable {
    static let shared = TrackpadMotor()

    /// Whether any connected trackpad has a haptic motor (Force Touch trackpads report
    /// "ActuationSupported"). Older Macs and most mice don't.
    static let isSupported: Bool = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"),
                                           &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        var supported = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            let value = IORegistryEntryCreateCFProperty(service, "ActuationSupported" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue()
            if (value as? Bool) == true { supported = true }
            IOObjectRelease(service)
        }
        return supported
    }()

    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetID = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateActuator = @convention(c) (UInt64) -> Unmanaged<AnyObject>?
    private typealias Open = @convention(c) (AnyObject) -> Int32
    private typealias Actuate = @convention(c) (AnyObject, Int32, UInt32, Float, Float) -> Int32

    /// The strongest known actuation: a force click.
    private static let forceClickPattern: Int32 = 6
    private let queue = DispatchQueue(label: "local.islet.haptics", qos: .userInteractive)
    private let lock = NSLock()
    /// Guarded by `lock`: set once the motor turns out to be unusable.
    private var failed = false
    // Touched only on `queue`.
    private var actuator: AnyObject?
    private var actuate: Actuate?
    private var connected = false

    /// Queues a force click. False when the motor is known to be unavailable, so the caller
    /// uses the standard haptic instead.
    func forceClick() -> Bool {
        if lock.withLock({ failed }) { return false }
        queue.async { self.pulse() }
        return true
    }

    private func pulse() {
        if !connected {
            connected = true
            connect()
        }
        guard let actuator, let actuate, actuate(actuator, Self.forceClickPattern, 0, 0, 0) == 0 else {
            lock.withLock { failed = true }
            Log.island.notice("Trackpad motor unavailable; using standard haptics")
            return
        }
    }

    private func connect() {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let list = symbol(framework, "MTDeviceCreateList", CreateList.self),
              let deviceID = symbol(framework, "MTDeviceGetDeviceID", GetID.self),
              let create = symbol(framework, "MTActuatorCreateFromDeviceID", CreateActuator.self),
              let open = symbol(framework, "MTActuatorOpen", Open.self),
              let actuate = symbol(framework, "MTActuatorActuate", Actuate.self),
              let devices = list()?.takeRetainedValue() as? [AnyObject]
        else { return }
        // The keyboard and the trackpad are both multitouch devices; only one has a motor.
        for device in devices {
            var id: UInt64 = 0
            guard deviceID(Unmanaged.passUnretained(device).toOpaque(), &id) == 0,
                  let candidate = create(id)?.takeRetainedValue(), open(candidate) == 0 else { continue }
            actuator = candidate
            self.actuate = actuate
            return
        }
    }

    private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: type) }
    }
}

// MARK: - Buttons

extension Glass {
    /// Islet's glass: Apple's stock Liquid Glass at the default transparency (the material
    /// the system slider and Control Center use), clearer or smokier as the Settings slider
    /// moves away from the middle.
    @MainActor static var islet: Glass { islet(clear: false) }

    /// The Clear Liquid Glass island style starts from clear glass instead.
    @MainActor static func islet(clear: Bool) -> Glass {
        let transparency = LiveTuning.shared.glassTransparency
        if clear {
            return Glass.clear.tint(.black.opacity(max(0, 0.5 - transparency) * 0.7)).interactive()
        }
        if transparency > 0.52 {
            return Glass.clear.tint(.black.opacity((1 - transparency) * 0.5)).interactive()
        }
        if transparency < 0.48 {
            return Glass.regular.tint(.black.opacity((0.5 - transparency) * 0.9)).interactive()
        }
        return Glass.regular.interactive()
    }
}


/// How an icon button shows feedback.
enum GlassButtonLook {
    /// Always a glass circle (standalone buttons floating over content).
    case glass
    /// Glass circle appears on hover and press.
    case glassOnHover
    /// A soft highlight only — for buttons that already sit inside a glass surface.
    case highlight
}

struct GlassIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 40
    var look: GlassButtonLook = .glassOnHover

    func makeBody(configuration: Configuration) -> some View {
        GlassIconBody(configuration: configuration, diameter: diameter, look: look)
    }
}

private struct GlassIconBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    let look: GlassButtonLook
    @State private var hovering = false

    var body: some View {
        let active = hovering || configuration.isPressed
        configuration.label
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .background {
                if look == .highlight {
                    Circle().fill(.white.opacity(configuration.isPressed ? 0.22 : (hovering ? 0.12 : 0)))
                }
            }
            .modifier(IconGlass(look: look, active: active))
            .scaleEffect(configuration.isPressed ? 0.84 : (hovering ? 1.05 : 1))
            .animation(IslandMotion.quick, value: configuration.isPressed)
            .animation(IslandMotion.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

private struct IconGlass: ViewModifier {
    let look: GlassButtonLook
    let active: Bool

    func body(content: Content) -> some View {
        switch look {
        case .glass:
            content.snapshotSafeGlass(.islet, in: Circle())
        case .glassOnHover:
            content.snapshotSafeGlass(active ? .islet : .identity, visible: active, in: Circle())
        case .highlight:
            content
        }
    }
}
