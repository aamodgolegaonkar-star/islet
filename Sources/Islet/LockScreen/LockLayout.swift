import AppKit
import CoreGraphics

/// Where the lock-screen pieces go, like iOS: tiny widgets just under the clock, the player
/// in the lower middle above the account / password area.
///
/// Uses loginwindow's own window frames when the window server reports them; otherwise
/// proportions of the macOS lock screen (big clock at the top, login at the bottom).
struct LockLayout {
    /// Cocoa screen coordinates.
    let widgets: CGRect
    let player: CGRect
    /// Height of the clock area from the top of the screen; the full-screen album lays
    /// out below it and draws the clock inside it.
    let clockInset: CGFloat

    static let widgetsSize = CGSize(width: 640, height: 104)
    static let playerSize = CGSize(width: 460, height: 224)

    /// `clockBottom`: where the real clock's digits end (from LoginUIKit's own views).
    init(screen: NSScreen, loginWindows: [CGRect], clockBottom measuredClock: CGFloat? = nil) {
        let frame = screen.frame
        let height = frame.height
        var clockBottom = measuredClock ?? height * 0.33
        var loginTop = height * 0.77

        // Global CG coordinates share the primary display's top-left origin.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        let screenTopInCG = primaryTop - frame.maxY
        let partial = loginWindows
            .map { $0.offsetBy(dx: -frame.minX, dy: -screenTopInCG) }
            .filter { $0.height < height * 0.9 && $0.width < frame.width * 0.95 && $0.height > 8 }
        let top = partial.filter { $0.midY < height * 0.45 }
        let bottom = partial.filter { $0.midY > height * 0.55 }
        if let maxY = top.map(\.maxY).max() { clockBottom = maxY }
        if let minY = bottom.map(\.minY).min() { loginTop = minY }

        func cocoaRect(top y: CGFloat, size: CGSize) -> CGRect {
            CGRect(x: frame.midX - size.width / 2, y: frame.maxY - y - size.height,
                   width: size.width, height: size.height)
        }
        let widgetsTop = clockBottom + 10
        widgets = cocoaRect(top: widgetsTop, size: Self.widgetsSize)
        let regionTop = widgetsTop + Self.widgetsSize.height
        let regionBottom = loginTop - 8
        let playerTop = max(regionTop, (regionTop + regionBottom - Self.playerSize.height) / 2)
        player = cocoaRect(top: playerTop, size: Self.playerSize)

        clockInset = clockBottom + 18
    }

    /// Frames of loginwindow's on-screen windows (global, top-left origin). Logged so the
    /// layout can be checked against the real lock screen.
    static func loginWindowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var frames: [CGRect] = []
        for info in list where info[kCGWindowOwnerName as String] as? String == "loginwindow" {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            Log.lock.info("loginwindow window: layer \(layer) frame \(rect.debugDescription, privacy: .public)")
            frames.append(rect)
        }
        return frames
    }
}
