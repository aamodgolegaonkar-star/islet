import AppKit
import IsletCore
import Observation
import SwiftUI

enum IslandPresentation: Equatable {
    case compact
    case expanded
    /// The file shelf (opened by dragging files to the island, or from the tray button).
    case shelf
    /// Control Center: system switches, volume and brightness.
    case controls
    /// The Android phone on Islet Link: battery, its music, notifications, actions.
    case phone
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
    /// Something came through Portal from an iPhone, or went to one.
    case portal(PortalArrival)
    /// Face ID looking for you on the lock screen.
    case faceScan(FaceScanPhase)
    /// A Focus mode turned on (`on`) or off.
    case focus(FocusMode, on: Bool)
    /// The Android phone: a notification, a call, a pairing code or a file on its way.
    case phone(PhoneAlert)

    /// Activities shown as a card (expanded shape) rather than a pill.
    var isCard: Bool {
        switch self {
        case .headphones, .agent, .portal, .phone: true
        default: false
        }
    }

    /// Cards with buttons (a phone notification, a call, a coding agent): the pointer on
    /// them keeps them up, instead of opening the island underneath.
    var holdsHover: Bool {
        switch self {
        case .phone, .agent: true
        default: false
        }
    }

    /// Same kind of activity (a level update shouldn't re-bounce the island).
    func sameKind(as other: IslandActivity?) -> Bool {
        switch (self, other) {
        case (.level(let a), .level(let b)?): a == b
        case (.charging, .charging?), (.unlocked, .unlocked?), (.locked, .locked?),
             (.lockFailed, .lockFailed?), (.headphones, .headphones?), (.agent, .agent?),
             (.lowBattery, .lowBattery?), (.timerDone, .timerDone?), (.portal, .portal?),
             (.faceScan, .faceScan?), (.focus, .focus?), (.phone, .phone?): true
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
    var controlsSize = CGSize(width: 300, height: 52)
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

    /// The phone page (below the notch, if any).
    var phoneHeight: CGFloat { (hasNotch ? notchHeight : 0) + 196 }

    /// Height of a phone card (below the notch, if any).
    func phoneAlertHeight(_ alert: PhoneAlert) -> CGFloat {
        switch alert {
        case let .notification(note): compactHeight + (note.actions.isEmpty ? 66 : 92)
        case .call: compactHeight + 70
        case .pairing: compactHeight + 104
        case .transfer: compactHeight + 52
        }
    }

    /// Wide enough for a long name beside three battery rings.
    var headphoneCardWidth: CGFloat { max(expandedSize.width + 24, 400) }

    /// The locked pill: short without a notch; with one, the padlock needs the left wing.
    /// Beside a notch the wings get extra room, so the padlock (and the red fingerprint) can
    /// shake after a wrong attempt without sliding under the camera housing, which stays put.
    var lockedWidth: CGFloat { hasNotch ? compactWidth + 28 : idleWidth }
    /// "Unlocked" needs a wide right wing beside a notch.
    var unlockedWidth: CGFloat { hasNotch ? chargingWidth : compactWidth }

    func size(for presentation: IslandPresentation, hasTrack: Bool, activity: IslandActivity? = nil) -> CGSize {
        switch activity {
        case .charging?: return CGSize(width: chargingWidth, height: compactHeight)
        case .unlocked?: return CGSize(width: unlockedWidth, height: compactHeight)
        case .locked?, .lockFailed?, .faceScan?: return CGSize(width: lockedWidth, height: compactHeight)
        // Beside a notch the bar can't run through the middle: it drops below the notch.
        case .level?: return CGSize(width: chargingWidth, height: hasNotch ? compactHeight + 26 : compactHeight)
        case .headphones?: return CGSize(width: headphoneCardWidth, height: compactHeight + 76)
        case .agent?: return CGSize(width: headphoneCardWidth, height: compactHeight + 58)
        case .portal?: return CGSize(width: headphoneCardWidth, height: compactHeight + 84)
        case let .phone(alert)?: return CGSize(width: headphoneCardWidth, height: phoneAlertHeight(alert))
        case .lowBattery?, .timerDone?, .focus?: return CGSize(width: chargingWidth, height: compactHeight)
        case nil: break
        }
        switch presentation {
        case .expanded where hasTrack: return expandedSize
        case .shelf: return CGSize(width: expandedSize.width, height: shelfHeight)
        case .controls: return CGSize(width: expandedSize.width, height: controlsHeight)
        case .phone: return CGSize(width: expandedSize.width, height: phoneHeight)
        default: return CGSize(width: hasTrack ? compactWidth : idleWidth, height: compactHeight)
        }
    }

    func cornerRadii(for presentation: IslandPresentation, hasTrack: Bool, activity: IslandActivity? = nil)
        -> (top: CGFloat, bottom: CGFloat) {
        let expanded = (presentation == .expanded && hasTrack && activity == nil) || activity?.isCard == true
            || ((presentation == .shelf || presentation == .controls || presentation == .phone) && activity == nil)
        // Square top beside a real or emulated notch, so the island reads as the notch hanging from the bezel.
        if hasNotch { return expanded ? (0, 38) : (0, 12) }
        return expanded ? (split ? 36 : 40, split ? 36 : 40) : (compactHeight / 2, compactHeight / 2)
    }

    /// Everything the island occupies (card plus split controls), in top-left-origin window
    /// coordinates. Used for hover hit-testing.
    func islandRect(for presentation: IslandPresentation, hasTrack: Bool, activity: IslandActivity? = nil,
                    phoneBubble: Bool = false) -> CGRect {
        let card = size(for: presentation, hasTrack: hasTrack, activity: activity)
        var height = card.height
        if split, presentation == .expanded, hasTrack, activity == nil {
            height += controlsGap + controlsSize.height
        }
        let rect = CGRect(x: (windowSize.width - card.width) / 2, y: topInset, width: card.width, height: height)
        guard phoneBubble, presentation != .compact, activity == nil else { return rect }
        // The phone button beside the open island counts as part of it.
        let size = Self.phoneBubbleSize
        return rect.union(CGRect(x: rect.minX - Self.phoneBubbleGap - size, y: topInset + phoneBubbleY, width: size, height: size))
    }

    static let phoneBubbleSize: CGFloat = 44
    static let phoneBubbleGap: CGFloat = 10
    /// Level with the open island's content, below the notch.
    var phoneBubbleY: CGFloat { (hasNotch ? notchHeight : 0) + 10 }
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
    /// False once a paused song has been dropped from the island ("Hide the player when
    /// music pauses"); it comes back when anything plays again.
    var showsTrack = true
    /// The open island shows the weather page instead of the player.
    var showsWeather = false
    /// The latest weather for that page (fetched while the island is open).
    var weather: WeatherService.Report?
    /// The last unlock was Face ID's, so the unlock animation shows the Face ID mark
    /// instead of the fingerprint.
    var unlockedWithFace = false
    /// Microphone / camera in use by some app: a coloured dot, like the iPhone's.
    var micActive = false
    var cameraActive = false
    /// A running timer's end; the compact island shows the countdown.
    var timerEnd: Date?
    /// The phone's newest Live Activity, which the resting island shows when nothing plays here.
    var phoneLive: PhoneLive? { link?.phone?.live.first }
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
    /// Bumped when the island lands on a newly active desktop; it drops in once per bump.
    var arrivals = 0
    /// True while a slider in the island is being dragged; prevents collapsing.
    var isInteracting = false
    /// Hidden while the full-screen player covers the screen.
    var isSuppressed = false
    /// Frame of the artwork view in window coordinates (top-left origin).
    var artFrame: CGRect = .zero
    /// Islet Link, for the phone page, the phone cards and the phone button.
    @ObservationIgnored var link: LinkController?
    /// Desktop picture behind the panel, for glass styles.
    var wallpaper: WallpaperContext?

    @ObservationIgnored var openPlayer: () -> Void = {}
    @ObservationIgnored var openPhonePage: () -> Void = {}
    @ObservationIgnored var requestExpand: () -> Void = {}
    /// A drag inside the island ended: re-check the pointer (it may have left meanwhile).
    @ObservationIgnored var interactionEnded: () -> Void = {}

    init(metrics: IslandMetrics) {
        self.metrics = metrics
    }
}
