import AppKit
import Observation
import SwiftUI

enum IslandPresentation: Equatable {
    case compact
    case expanded
    /// The file shelf (opened by dragging files to the island, or from the tray button).
    case shelf
    /// Control Center: system switches, volume and brightness.
    case controls
}

/// Short-lived system events the island shows on its own, like the iPhone.
enum IslandActivity: Equatable {
    case charging(BatteryState)
    /// The Mac was just unlocked: the fingerprint goes red to green, then the padlock opens.
    case unlocked
    /// On the lock screen: a closed padlock, like the iPhone's Face ID island.
    case locked
    /// A failed unlock attempt: a red fingerprint while the island shakes.
    case lockFailed
    /// Volume or brightness changed: a glass level bar, like the iPhone's. The level itself
    /// lives in `IslandModel.level`, so a stream of changes (a Touch Bar slide) only moves
    /// the bar instead of re-running the island's activity animations each time.
    case level(LevelHUD.Kind)
    /// Headphones connected: their picture, name and battery, in a card.
    case headphones(HeadphoneCard)
    /// Claude Code or Codex needs attention (or finished).
    case agent(AgentAlert)
    /// The battery fell to 20% or 10%: a red pill, the charging card in reverse.
    case lowBattery(Int)
    /// A timer reached zero.
    case timerDone

    /// Activities shown as a card (expanded shape) rather than a pill.
    var isCard: Bool {
        switch self {
        case .headphones, .agent: true
        default: false
        }
    }

    /// Same kind of activity (a level update shouldn't re-bounce the island).
    func sameKind(as other: IslandActivity?) -> Bool {
        switch (self, other) {
        case (.level(let a), .level(let b)?): a == b
        case (.charging, .charging?), (.unlocked, .unlocked?), (.locked, .locked?),
             (.lockFailed, .lockFailed?), (.headphones, .headphones?), (.agent, .agent?),
             (.lowBattery, .lowBattery?), (.timerDone, .timerDone?): true
        default: false
        }
    }
}

struct LevelHUD: Equatable {
    enum Kind { case volume, brightness }
    var kind: Kind
    var value: Double
    var muted = false
}

/// Island geometry for one screen. Macs without a notch get a floating pill under the
/// top edge; notched Macs get an island attached to the notch.
struct IslandMetrics: Equatable {
    var hasNotch: Bool
    var notchHeight: CGFloat
    var topInset: CGFloat
    var compactHeight: CGFloat
    var idleWidth: CGFloat
    var compactWidth: CGFloat
    var chargingWidth: CGFloat
    var expandedSize: CGSize
    var windowSize: CGSize
    /// Glass styles split the transport controls into their own glass capsule.
    var split = false
    var controlsSize = CGSize(width: 204, height: 52)
    var controlsGap: CGFloat = 12

    /// Every style splits the transport controls into a capsule floating below the card.
    /// Without a screen (none attached for a moment) this is the no-notch layout. The
    /// Settings size sliders scale the pill; beside a notch they scale the wings.
    @MainActor
    static func make(for screen: NSScreen?, style: IslandStyle) -> IslandMetrics {
        let tuning = LiveTuning.shared
        let adjust = CGSize(width: tuning.notchWidthAdjust, height: tuning.notchHeightAdjust)
        var metrics = base(for: screen, notchAdjust: adjust)
        let width = CGFloat(tuning.widthScale), height = CGFloat(tuning.heightScale)
        if metrics.hasNotch {
            metrics.compactWidth = metrics.idleWidth + (metrics.compactWidth - metrics.idleWidth) * width
            metrics.chargingWidth = metrics.idleWidth + (metrics.chargingWidth - metrics.idleWidth) * width
        } else {
            metrics.idleWidth *= width
            metrics.compactWidth *= width
            metrics.chargingWidth *= width
            metrics.compactHeight = (metrics.compactHeight * height).rounded()
        }
        metrics.expandedSize.width *= width
        metrics.split = true
        metrics.expandedSize.height -= 56
        return metrics
    }

    private static func base(for screen: NSScreen?, notchAdjust: CGSize) -> IslandMetrics {
        if var notch = notch(of: screen) {
            notch.width = max(notch.width + notchAdjust.width, 60)
            notch.height = max(notch.height + notchAdjust.height, 16)
            // Every notched MacBook: the sizes come from the screen, so any notch width or
            // height works. Content lives in the wings either side of the camera housing.
            return IslandMetrics(
                hasNotch: true, notchHeight: notch.height, topInset: 0, compactHeight: notch.height,
                idleWidth: notch.width, compactWidth: notch.width + 92, chargingWidth: notch.width + 220,
                expandedSize: CGSize(width: max(430, notch.width + 190), height: 188 + notch.height * 0.6),
                windowSize: CGSize(width: 660, height: 320))
        }
        return IslandMetrics(
            hasNotch: false, notchHeight: 0, topInset: 5, compactHeight: 28,
            idleWidth: 112, compactWidth: 190, chargingWidth: 256,
            expandedSize: CGSize(width: 384, height: 180),
            windowSize: CGSize(width: 620, height: 300))
    }

    /// The camera housing's size, or nil on a Mac without one. Debug: `defaults write
    /// local.islet.Islet simulateNotch 185x32` lays out as if the screen had that notch.
    private static func notch(of screen: NSScreen?) -> CGSize? {
        if let simulated = UserDefaults.standard.string(forKey: "simulateNotch") {
            let parts = simulated.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { return CGSize(width: parts[0], height: parts[1]) }
        }
        if let real = hardwareNotch(of: screen) { return real }
        // Settings → Island → "Emulate a notch": a MacBook-sized notch, as tall as this
        // screen's menu bar so it sits flush in it.
        guard UserDefaults.standard.bool(forKey: AppSettings.emulateNotchKey) else { return nil }
        let menuBar = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        return CGSize(width: 185, height: max(menuBar, 24))
    }

    /// The camera housing actually built into the screen, if any.
    static func hardwareNotch(of screen: NSScreen?) -> CGSize? {
        guard let screen, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }

    /// A running timer's pill: the music pill, or beside a notch the wider charging pill,
    /// so the digits stay in the right wing.
    var timerWidth: CGFloat { hasNotch ? chargingWidth : compactWidth }

    /// Room for a row of file tiles under the shelf's header (below the notch, if any).
    var shelfHeight: CGFloat { (hasNotch ? notchHeight : 0) + 122 }

    /// Two rows of switches (below the notch, if any).
    var controlsHeight: CGFloat { (hasNotch ? notchHeight : 0) + 160 }

    /// Wide enough for a long name beside three battery rings.
    var headphoneCardWidth: CGFloat { max(expandedSize.width + 24, 400) }

    /// The locked pill: short without a notch; with one, the padlock needs the left wing.
    var lockedWidth: CGFloat { hasNotch ? compactWidth : idleWidth }
    /// "Unlocked" needs a wide right wing beside a notch.
    var unlockedWidth: CGFloat { hasNotch ? chargingWidth : compactWidth }

    func size(for presentation: IslandPresentation, hasTrack: Bool, activity: IslandActivity? = nil) -> CGSize {
        switch activity {
        case .charging?: return CGSize(width: chargingWidth, height: compactHeight)
        case .unlocked?: return CGSize(width: unlockedWidth, height: compactHeight)
        case .locked?, .lockFailed?: return CGSize(width: lockedWidth, height: compactHeight)
        // Beside a notch the bar can't run through the middle: it drops below the notch.
        case .level?: return CGSize(width: chargingWidth, height: hasNotch ? compactHeight + 26 : compactHeight)
        case .headphones?: return CGSize(width: headphoneCardWidth, height: compactHeight + 76)
        case .agent?: return CGSize(width: headphoneCardWidth, height: compactHeight + 58)
        case .lowBattery?, .timerDone?: return CGSize(width: chargingWidth, height: compactHeight)
        case nil: break
        }
        switch presentation {
        case .expanded where hasTrack: return expandedSize
        case .shelf: return CGSize(width: expandedSize.width, height: shelfHeight)
        case .controls: return CGSize(width: expandedSize.width, height: controlsHeight)
        default: return CGSize(width: hasTrack ? compactWidth : idleWidth, height: compactHeight)
        }
    }

    func cornerRadii(for presentation: IslandPresentation, hasTrack: Bool, activity: IslandActivity? = nil)
        -> (top: CGFloat, bottom: CGFloat) {
        let expanded = (presentation == .expanded && hasTrack && activity == nil) || activity?.isCard == true
            || ((presentation == .shelf || presentation == .controls) && activity == nil)
        if hasNotch { return expanded ? (14, 38) : (6, 12) }
        return expanded ? (split ? 36 : 40, split ? 36 : 40) : (compactHeight / 2, compactHeight / 2)
    }

    /// Everything the island occupies (card plus split controls), in top-left-origin window
    /// coordinates. Used for hover hit-testing.
    func islandRect(for presentation: IslandPresentation, hasTrack: Bool, activity: IslandActivity? = nil) -> CGRect {
        let card = size(for: presentation, hasTrack: hasTrack, activity: activity)
        var height = card.height
        if split, presentation == .expanded, hasTrack, activity == nil {
            height += controlsGap + controlsSize.height
        }
        return CGRect(x: (windowSize.width - card.width) / 2, y: topInset, width: card.width, height: height)
    }
}

@MainActor
@Observable
final class IslandModel {
    var presentation: IslandPresentation = .compact
    var metrics: IslandMetrics
    /// A transient system event (e.g. a charger was connected) shown in place of the pill.
    var activity: IslandActivity?
    /// Swiped away (two fingers up) so it doesn't cover what's behind it, for a moment.
    var isTucked = false
    /// The pointer is over the island (it lifts slightly when it won't open on hover).
    var isHovered = false
    /// Microphone / camera in use by some app: a coloured dot, like the iPhone's.
    var micActive = false
    var cameraActive = false
    /// A running timer's end; the compact island shows the countdown.
    var timerEnd: Date?
    /// Files kept on the island.
    @ObservationIgnored let shelf = ShelfStore()
    /// A file drag ended on the shelf.
    @ObservationIgnored var onShelfDrop: () -> Void = {}
    /// The current volume or brightness level for the `.level` activity.
    var level = LevelHUD(kind: .volume, value: 0)
    /// Clicking an agent card brings its terminal forward.
    @ObservationIgnored var onAgentTap: (AgentAlert) -> Void = { _ in }
    /// Dragging the level pill's slider sets the volume or brightness.
    @ObservationIgnored var onLevelDrag: (LevelHUD.Kind, Double) -> Void = { _, _ in }
    /// Bumped for each failed unlock attempt; the island shakes once per bump.
    var shakes = 0
    /// True while a slider in the island is being dragged; prevents collapsing.
    var isInteracting = false
    /// Hidden while the full-screen player covers the screen.
    var isSuppressed = false
    /// Frame of the artwork view in window coordinates (top-left origin).
    var artFrame: CGRect = .zero
    /// Desktop picture behind the panel, for glass styles.
    var wallpaper: WallpaperContext?

    @ObservationIgnored var openPlayer: () -> Void = {}
    @ObservationIgnored var requestExpand: () -> Void = {}
    /// A drag inside the island ended: re-check the pointer (it may have left meanwhile).
    @ObservationIgnored var interactionEnded: () -> Void = {}

    init(metrics: IslandMetrics) {
        self.metrics = metrics
    }
}
