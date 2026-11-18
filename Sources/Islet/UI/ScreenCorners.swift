import AppKit
import Observation

/// Which display corners Islet rounds off.
enum ScreenCornerRounding: String, CaseIterable, Identifiable {
    case off
    case bottom
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .bottom: "Bottom Corners"
        case .all: "All Corners"
        }
    }
}

/// Black quarter-circle masks in the display's corners, so square corners look like the
/// rounded top of a MacBook screen. Each is a tiny click-through window with a fixed
/// shape: nothing redraws, nothing runs. They sit over full-screen apps and stay out of
/// screenshots and recordings. A notched screen's top corners are already round.
@MainActor
final class ScreenCorners {
    static let radius: CGFloat = 10

    private let settings: AppSettings
    private var windows: [NSWindow] = []
    private var screensObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        follow()
    }

    private func follow() {
        withObservationTracking { rebuild() } onChange: {
            Task { @MainActor [weak self] in self?.follow() }
        }
    }

    private func rebuild() {
        let mode = settings.screenCorners
        windows.forEach { $0.orderOut(nil) }
        windows = []
        guard mode != .off else { return }
        for screen in NSScreen.screens {
            let notched = screen.safeAreaInsets.top > 0
            var corners: [Corner] = [.bottomLeft, .bottomRight]
            if mode == .all, !notched { corners += [.topLeft, .topRight] }
            for corner in corners { windows.append(window(corner, on: screen)) }
        }
    }

    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func window(_ corner: Corner, on screen: NSScreen) -> NSWindow {
        let r = Self.radius
        let f = screen.frame
        let origin: CGPoint = switch corner {
        case .bottomLeft: CGPoint(x: f.minX, y: f.minY)
        case .bottomRight: CGPoint(x: f.maxX - r, y: f.minY)
        case .topLeft: CGPoint(x: f.minX, y: f.maxY - r)
        case .topRight: CGPoint(x: f.maxX - r, y: f.maxY - r)
        }
        // NSWindow, not NSPanel: the capture setting re-shares every panel, and these never belong in a capture.
        let window = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: r, height: r)),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = CornerView(corner: corner)
        window.orderFrontRegardless()
        return window
    }

    private final class CornerView: NSView {
        init(corner: Corner) {
            super.init(frame: CGRect(x: 0, y: 0, width: ScreenCorners.radius, height: ScreenCorners.radius))
            wantsLayer = true
            let r = ScreenCorners.radius
            // The square minus a quarter circle centred on the corner pointing into the screen.
            let centre: CGPoint = switch corner {
            case .bottomLeft: CGPoint(x: r, y: r)
            case .bottomRight: CGPoint(x: 0, y: r)
            case .topLeft: CGPoint(x: r, y: 0)
            case .topRight: CGPoint(x: 0, y: 0)
            }
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            let shape = CAShapeLayer()
            shape.path = path
            shape.fillRule = .evenOdd
            shape.fillColor = NSColor.black.cgColor
            layer?.addSublayer(shape)
        }

        required init?(coder: NSCoder) { nil }
    }
}
