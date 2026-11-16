import AppKit
import SwiftUI

/// Liquid Glass in a clear overlay window refracts whatever is on screen behind it, live
/// (the island relies on that). The system lock screen is the exception: overlay windows
/// can't sample it, so the lock screen's windows draw the desktop picture behind their glass,
/// aligned to the screen, so the glass bends what the user actually sees there.
struct WallpaperContext: Equatable, @unchecked Sendable {
    /// Exactly the part of the desktop picture behind the window, at the screen's pixel density.
    var image: CGImage
    var scale: CGFloat
    /// Window size in points.
    var size: CGSize
}

extension EnvironmentValues {
    @Entry var wallpaper: WallpaperContext? = nil
}

/// Crops of the desktop picture for overlay windows. A 4K picture decoded in full costs
/// 30+ MB, so it is decoded once at screen size, cut into the few small pieces the windows
/// need, and released.
@MainActor
enum Wallpaper {
    private static var crops: [String: WallpaperContext] = [:]
    private static var decoded: (key: String, image: CGImage)?
    private static var releaseTask: Task<Void, Never>?

    static func context(for screen: NSScreen, windowFrame: CGRect) -> WallpaperContext? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let scale = screen.backingScaleFactor
        let screenKey = "\(url.path)|\(NSStringFromRect(screen.frame))|\(scale)"
        let key = "\(screenKey)|\(NSStringFromRect(windowFrame))"
        if let cached = crops[key] { return cached }
        guard let full = screenImage(url: url, screen: screen, key: screenKey) else { return nil }

        // The window's rectangle in screen pixels, top-left origin.
        let local = CGRect(x: (windowFrame.minX - screen.frame.minX) * scale,
                           y: (screen.frame.maxY - windowFrame.maxY) * scale,
                           width: windowFrame.width * scale, height: windowFrame.height * scale).integral
        // Copy the crop into its own bitmap; a plain crop would keep the whole picture alive.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(local.width), height: Int(local.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(full, in: CGRect(x: -local.minX, y: local.maxY - CGFloat(full.height),
                                      width: CGFloat(full.width), height: CGFloat(full.height)))
        guard let crop = context.makeImage() else { return nil }
        let result = WallpaperContext(image: crop, scale: scale, size: windowFrame.size)
        if crops.count >= 8 { crops.removeAll() }
        crops[key] = result
        return result
    }

    /// Forgets the pieces cut so far (the lock screen calls this once it's gone).
    static func releaseCrops() {
        crops.removeAll()
    }

    /// The picture as the Desktop shows it (aspect-filled and centred), at screen pixels.
    private static func screenImage(url: URL, screen: NSScreen, key: String) -> CGImage? {
        if let decoded, decoded.key == key { return decoded.image }
        let scale = screen.backingScaleFactor
        let target = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0
        else { return nil }
        let fill = max(target.width / width, target.height / height)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * min(fill, 1)).rounded(.up)),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(target.width), height: Int(target.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let drawn = CGSize(width: width * fill, height: height * fill)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (target.width - drawn.width) / 2, y: (target.height - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        guard let screenImage = context.makeImage() else { return nil }
        decoded = (key, screenImage)
        // Keep it just long enough for the other windows being placed at the same moment.
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            decoded = nil
            // Decoding leaves megabytes of freed but still-dirty pages behind; return them.
            malloc_zone_pressure_relief(nil, 0)
        }
        return screenImage
    }
}

/// Fills its frame with exactly the part of the wallpaper that sits behind it on screen.
/// Opaque, so it also makes the area clickable in otherwise transparent overlay windows.
struct WallpaperBackdrop: View {
    var fallback: Color = .black.opacity(0.35)
    @Environment(\.wallpaper) private var wallpaper

    var body: some View {
        GeometryReader { geo in
            if let wallpaper {
                let local = geo.frame(in: .global)
                Image(decorative: wallpaper.image, scale: wallpaper.scale)
                    .frame(width: wallpaper.size.width, height: wallpaper.size.height)
                    .offset(x: -local.minX, y: -local.minY)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .clipped()
            } else {
                fallback
            }
        }
    }
}

/// Near-invisible fill: non-transparent pixels make the window server deliver clicks here
/// instead of passing them through to whatever is behind the overlay window.
extension View {
    func clickable<S: Shape>(_ shape: S) -> some View {
        background(shape.fill(Color.black.opacity(0.012)))
    }
}

/// Runs a control's action from AppKit's own mouse-down/up. Islet's panels never activate
/// the app, and SwiftUI may then ignore a button's click even though the click reached the
/// window. Controls register their frame here; the hosting view fires the control when a
/// press and its release land on it. SwiftUI may still fire too, so a click runs only once.
@MainActor
@Observable
final class ClickRouter {
    @ObservationIgnored private var targets: [String: (frame: CGRect, action: () -> Void)] = [:]
    @ObservationIgnored private var lastFired: (id: String, press: Int)?
    /// Counts presses, so each click runs its control once however late SwiftUI's own
    /// action arrives, while quick repeat clicks still each count.
    @ObservationIgnored private var press = 0
    /// The control under a press that hasn't been released yet, so it can look pressed
    /// (SwiftUI's own pressed state doesn't show in a window that never activates).
    var pressed: String?
    /// Where the controls' coordinate space starts in the window when the island is at
    /// rest. Controls register frames in that space, so a passing scale (hover lift, pulse,
    /// tuck) can't leave stale positions behind.
    @ObservationIgnored var origin: CGPoint = .zero

    func register(_ id: String, frame: CGRect, action: @escaping () -> Void) {
        targets[id] = (frame, action)
    }

    /// Debug: every registered control and where it is.
    var dump: String {
        targets.sorted { $0.key < $1.key }.map { "\($0.key) \(NSStringFromRect($0.value.frame))" }.joined(separator: "\n")
    }

    func unregister(_ id: String) {
        targets[id] = nil
    }

    /// The control under `point` (top-left window coordinates).
    func target(at point: CGPoint) -> String? {
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        return targets.first { $0.value.frame.contains(local) }?.key
    }

    /// From the hosting view's mouse-up.
    func fire(_ id: String) {
        guard let action = targets[id]?.action else { return }
        run(id, action)
    }

    /// A button's own action, wrapped so it and the routed click can't both run for one
    /// click (a switch would flip twice and seem to do nothing).
    static func guarded(_ router: ClickRouter?, _ id: String, _ action: @escaping () -> Void) -> @MainActor () -> Void {
        { if let router { router.run(id, action) } else { action() } }
    }

    /// From the hosting view's mouse-down: a new click begins.
    func pressBegan() {
        press += 1
    }

    /// From SwiftUI's own action; whichever path comes second within a click is ignored.
    func run(_ id: String, _ action: () -> Void) {
        if let last = lastFired, last.id == id, last.press == press { return }
        lastFired = (id, press)
        Log.island.debug("Control \(id, privacy: .public)")
        action()
    }
}

extension EnvironmentValues {
    @Entry var clickRouter: ClickRouter?
    /// Set inside `routedClickSpace`: controls measure themselves there instead of globally.
    @Entry var routedClickSpaced = false
}

extension View {
    /// A tap target that works even while the app is inactive; `action` runs once per click.
    /// Hidden controls pass `enabled: false` so they can't be clicked invisibly.
    func routedClick(_ id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(RoutedClick(id: id, enabled: enabled, action: action))
    }
}

/// A button for Islet's panels with the click routing built in. Use it instead of a plain
/// `Button`, which may ignore clicks in a window that never activates the app.
struct RoutedButton<Label: View>: View {
    let id: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.clickRouter) private var router

    init(_ id: String, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.id = id
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: ClickRouter.guarded(router, id, action), label: label)
            .buttonStyle(.plain)
            .routedClick(id, action: action)
    }
}

private struct RoutedClick: ViewModifier {
    let id: String
    let enabled: Bool
    let action: () -> Void
    @Environment(\.clickRouter) private var router
    @Environment(\.routedClickSpaced) private var spaced
    @State private var frame: CGRect = .zero
    /// False once the control has gone, so a leaving view's last animation frames can't
    /// register it again (it would answer clicks meant for whatever replaced it).
    @State private var present = false

    func body(content: Content) -> some View {
        if let router {
            content
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: spaced ? .named(RoutedClickSpace.name) : .global)
                } action: { newFrame in
                    frame = newFrame
                    update(router)
                }
                .onChange(of: enabled) { update(router) }
                .onAppear {
                    present = true
                    update(router)
                }
                .onDisappear {
                    present = false
                    router.unregister(id)
                }
        } else {
            content
        }
    }

    private func update(_ router: ClickRouter) {
        if enabled, present, frame != .zero { router.register(id, frame: frame, action: action) } else { router.unregister(id) }
    }
}

/// Marks the island's content as the space its controls measure themselves in, and tells
/// the router where that space sits in the window at rest: centered, `topInset` down.
struct RoutedClickSpace: ViewModifier {
    static let name = "routedClickSpace"
    let windowWidth: CGFloat
    let topInset: CGFloat
    @Environment(\.clickRouter) private var router

    func body(content: Content) -> some View {
        content
            .environment(\.routedClickSpaced, true)
            .coordinateSpace(.named(Self.name))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                router?.origin = CGPoint(x: (windowWidth - size.width) / 2, y: topInset)
            }
    }
}
