import AppKit
import SwiftUI

/// "Drag to Screen Edge to Send": while something is being dragged, a portal opens along
/// the right edge of the screen, where the iPhone sits beside a MacBook. It glows brighter,
/// and the trackpad ticks faster, the closer the pointer gets; letting go over it sends.
@MainActor
final class PortalEdge {
    private weak var controller: PortalController?
    /// The vortex itself: drawn only, never in the way of a drop.
    private var visual: NSPanel?
    /// A thin strip at the very edge that takes the drop, so drops anywhere else on the
    /// screen (desktop icons, windows on the right) still go where they always did.
    private var dropZone: NSPanel?
    private let state = EdgeState()
    private var monitors: [Any] = []
    private var dragCount = 0
    private var dragging = false
    private var lastTick: TimeInterval = 0

    /// How far from the edge the portal starts to respond.
    private static let reach: CGFloat = 260
    private static let width: CGFloat = 300
    /// The strip that accepts drops.
    private static let dropWidth: CGFloat = 28

    init(controller: PortalController) {
        self.controller = controller
    }

    func setEnabled(_ on: Bool) {
        if on, monitors.isEmpty { install() }
        if !on { uninstall() }
    }

    private func install() {
        let board = NSPasteboard(name: .drag)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.type, board: board) }
        }) { monitors.append(monitor) }
    }

    private func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hide()
    }

    private func handle(_ type: NSEvent.EventType, board: NSPasteboard) {
        switch type {
        case .leftMouseDown:
            dragCount = board.changeCount
            dragging = false
        case .leftMouseDragged:
            // A real drag (files, text or a link) has written to the drag pasteboard.
            if !dragging, board.changeCount != dragCount, controller?.hasDevices == true,
               board.types?.contains(where: { [.fileURL, .URL, .string].contains($0) }) == true {
                dragging = true
            }
            guard dragging, let screen = NSScreen.screens.first else { return }
            let pointer = NSEvent.mouseLocation
            // Past the edge means another display; nothing to do with the portal.
            let distance = screen.frame.maxX - pointer.x
            let onScreen = distance >= 0 && pointer.y >= screen.frame.minY && pointer.y <= screen.frame.maxY
            let near = onScreen ? max(0, min(1, 1 - distance / Self.reach)) : 0
            update(near: near, atEdge: onScreen && distance <= Self.dropWidth + 12, on: screen)
            tick(near)
        case .leftMouseUp:
            dragging = false
            // Leave a moment for a drop on the strip to land before it goes.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, !self.dragging else { return }
                self.hide()
            }
        default:
            break
        }
    }

    private func update(near: CGFloat, atEdge: Bool, on screen: NSScreen) {
        withAnimation(IslandMotion.quick) { state.near = near }
        if near > 0 { showVisual(on: screen) } else { visual?.orderOut(nil) }
        if atEdge { showDropZone(on: screen) } else { dropZone?.orderOut(nil) }
    }

    /// Ticks get closer together as the pointer nears the edge.
    private func tick(_ near: CGFloat) {
        guard near > 0.05 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let gap = 0.42 - 0.36 * Double(near)
        guard now - lastTick > gap else { return }
        lastTick = now
        controller?.edgeTick()
    }

    /// Something is on its way from a phone: the portal opens on the edge and widens with
    /// the upload, then closes as it lands (the island shows what came through).
    func incoming(from phone: String, progress: Double?) {
        guard !dragging, let screen = NSScreen.screens.first else { return }
        guard let progress else {
            guard state.incoming != nil else { return }
            state.incoming = nil
            withAnimation(IslandMotion.playful) { state.swallowed = true }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, !self.dragging, self.state.incoming == nil else { return }
                self.hide()
            }
            return
        }
        state.swallowed = false
        state.incoming = "From \(phone) · \(Int((progress * 100).rounded()))%"
        showVisual(on: screen)
        withAnimation(IslandMotion.quick) { state.near = 0.4 + 0.6 * progress }
    }

    func debugShow(_ near: CGFloat) {
        guard let screen = NSScreen.screens.first else { return }
        if near <= 0 { return hide() }
        showVisual(on: screen)
        withAnimation(IslandMotion.quick) { state.near = near }
    }

    private func showVisual(on screen: NSScreen) {
        let panel = visual ?? makeVisual()
        let frame = CGRect(x: screen.frame.maxX - Self.width, y: screen.frame.minY, width: Self.width, height: screen.frame.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func showDropZone(on screen: NSScreen) {
        let panel = dropZone ?? makeDropZone()
        let frame = CGRect(x: screen.frame.maxX - Self.dropWidth, y: screen.frame.minY, width: Self.dropWidth, height: screen.frame.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hide() {
        withAnimation(IslandMotion.exit) { state.near = 0 }
        state.swallowed = false
        visual?.orderOut(nil)
        dropZone?.orderOut(nil)
    }

    private func makeVisual() -> NSPanel {
        let panel = IslandPanel(size: CGSize(width: Self.width, height: 400))
        panel.identifier = NSUserInterfaceItemIdentifier("portal.edge")
        panel.ignoresMouseEvents = true
        panel.contentView = PassThroughHostingView(rootView: PortalThemed(settings: controller?.settings) { EdgePortalView(state: state) })
        visual = panel
        return panel
    }

    private func makeDropZone() -> NSPanel {
        let panel = IslandPanel(size: CGSize(width: Self.dropWidth, height: 400))
        panel.identifier = NSUserInterfaceItemIdentifier("portal.drop")
        panel.ignoresMouseEvents = false
        panel.contentView = EdgeDropView { [weak self] files, text in self?.dropped(files: files, text: text) }
        dropZone = panel
        return panel
    }

    private func dropped(files: [URL], text: String?) {
        withAnimation(IslandMotion.playful) { state.swallowed = true }
        controller?.send(files: files, text: text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.hide()
        }
    }
}

@MainActor
@Observable
final class EdgeState {
    /// 0 far away → 1 at the edge.
    var near: CGFloat = 0
    /// Just took a drop: flare and close.
    var swallowed = false
    /// "From iPhone · 40%" while something comes in from a phone.
    var incoming: String?
}

/// Draws only: drags and clicks go to the drop view underneath.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Takes files, links and text dropped on the edge portal.
final class EdgeDropView: NSView {
    private let onDrop: ([URL], String?) -> Void

    init(onDrop: @escaping ([URL], String?) -> Void) {
        self.onDrop = onDrop
        super.init(frame: CGRect(x: 0, y: 0, width: 28, height: 400))
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    /// Nearly invisible, but not transparent: fully clear pixels let drags fall through.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.012).setFill()
        dirtyRect.fill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let link = (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first { !$0.isFileURL }
        let text = files.isEmpty ? (link?.absoluteString ?? board.string(forType: .string)) : nil
        guard !files.isEmpty || text != nil else { return false }
        onDrop(files, text)
        return true
    }
}

/// A great elliptical vortex half out of the screen's edge: rings of light turning against
/// each other around a dark core, sparks spiralling in. It swells as the pointer nears.
struct EdgePortalView: View {
    @Environment(\.portalTheme) private var theme
    let state: EdgeState

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let near = Double(state.near)
            let grow = 0.45 + 0.55 * near + (state.swallowed ? 0.25 : 0)
            let speed = 0.8 + 2.4 * near + (state.swallowed ? 3 : 0)
            GeometryReader { geometry in
                let edge = CGPoint(x: geometry.size.width, y: geometry.size.height / 2)
                ZStack {
                    Ellipse()
                        .fill(RadialGradient(colors: [theme.colors[0].opacity(0.85), theme.colors[1].opacity(0.3), .clear],
                                             center: .center, startRadius: 10, endRadius: 260))
                        .frame(width: 420 * grow, height: 900 * grow)
                        .blur(radius: 30)
                        .position(edge)
                    ForEach(0..<3, id: \.self) { index in
                        let spin = t * speed * (index == 1 ? -1.3 : 1) * (1 + Double(index) * 0.4)
                        Ellipse()
                            .stroke(AngularGradient(colors: index == 1
                                                        ? [.clear, theme.colors[1], .clear, theme.colors[2], .clear]
                                                        : [theme.colors[0], theme.colors[1], theme.colors[2], theme.colors[0]],
                                                    center: .center, angle: .radians(spin)),
                                    lineWidth: 6 - Double(index) * 1.5)
                            .frame(width: (200 - Double(index) * 46) * grow, height: (620 - Double(index) * 130) * grow)
                            .shadow(color: theme.colors[1].opacity(0.7), radius: 8)
                            .blur(radius: 0.8)
                            .position(edge)
                    }
                    Ellipse()
                        .fill(RadialGradient(colors: [.black, .black, Color(red: 0.12, green: 0.02, blue: 0.3)],
                                             center: .center, startRadius: 0, endRadius: 90))
                        .frame(width: 70 * grow, height: 250 * grow)
                        .shadow(color: theme.colors[0], radius: 18)
                        .position(edge)
                    Canvas { context, size in
                        // Sparks falling inward along an elliptical spiral.
                        for index in 0..<70 {
                            let seed = Double(index) * 0.618_034
                            let life = (seed + t * (0.22 + 0.5 * near)).truncatingRemainder(dividingBy: 1)
                            let radius = (1 - life) * 1.1 + 0.12
                            let angle = .pi / 2 + (seed * 2 - 1) * .pi / 2 * 0.98 + life * 2.4
                            let x = edge.x - abs(cos(angle)) * radius * 100 * grow
                            let y = edge.y + sin(angle + .pi / 2) * radius * 310 * grow
                            let r = 1 + (1 - life) * 2
                            context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                         with: .color(Color(hue: 0.75 - life * 0.25, saturation: 0.75, brightness: 1)
                                            .opacity(0.25 + life * 0.75)))
                        }
                    }
                    .blendMode(.plusLighter)
                    if near > 0.55 || state.incoming != nil {
                        Label(state.incoming ?? "Send to iPhone", systemImage: state.incoming == nil ? "iphone.gen3" : "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .overlay(Capsule().stroke(.white.opacity(0.2)))
                            .position(x: edge.x - 150 * grow - 20, y: edge.y)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
            }
            .brightness(state.swallowed ? 0.35 : 0)
            .opacity(min(1, near * 1.8))
        }
        .allowsHitTesting(false)
    }
}
