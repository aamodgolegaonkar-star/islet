import Foundation
import IsletCore
import Observation

enum LockSoundStyle: String, CaseIterable, Identifiable {
    case iPhone
    case macPadlock
    case custom
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iPhone: "iPhone-Style Click"
        case .macPadlock: "macOS Padlock"
        case .custom: "Custom Sound Files"
        case .off: "Off"
        }
    }
}

/// Which player Islet shows.
enum PlayerSource: String, CaseIterable, Identifiable {
    /// Whatever the system says is playing (any app).
    case automatic
    case appleMusic
    case spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Whatever Is Playing"
        case .appleMusic: "Apple Music Only"
        case .spotify: "Spotify Only"
        }
    }
}

/// When Islet trades animation smoothness for battery life.
enum BatterySaver: String, CaseIterable, Identifiable {
    case automatic
    case always
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "On Battery or Low Power Mode"
        case .always: "Always"
        case .off: "Never"
        }
    }
}

enum IslandStyle: String, CaseIterable, Identifiable {
    case smokyGlass
    case clearGlass
    case black

    var id: String { rawValue }
    var isGlass: Bool { self != .black }

    var title: String {
        switch self {
        case .smokyGlass: "Liquid Glass"
        case .clearGlass: "Clear Liquid Glass"
        case .black: "Black (iPhone)"
        }
    }
}

/// Where the volume and brightness level appears.
/// How the full-screen and lock-screen lyrics draw the line being sung.
enum LyricStyle: String, CaseIterable, Identifiable {
    /// The whole line lights up at once.
    case classic
    /// Each word lights up as it's sung.
    case wordByWord
    /// Words light up, and the one being sung swells like a lens passing along the line.
    case fisheye

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Line by Line"
        case .wordByWord: "Word by Word"
        case .fisheye: "Fisheye"
        }
    }
}

/// Where the big on-screen lyrics show.
enum ScreenLyricsPlace: String, CaseIterable, Identifiable {
    case lockScreen
    case everywhere

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lockScreen: "Lock Screen Only"
        case .everywhere: "Lock Screen and Desktop"
        }
    }
}

/// Typefaces for the on-screen lyrics (Verci's list), all bold.
enum ScreenLyricsFont: String, CaseIterable, Identifiable {
    case sfPro, sfRounded, newYork, helveticaNeue, avenirNext, futura, didot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sfPro: "SF Pro"
        case .sfRounded: "SF Rounded"
        case .newYork: "New York"
        case .helveticaNeue: "Helvetica Neue"
        case .avenirNext: "Avenir Next"
        case .futura: "Futura"
        case .didot: "Didot"
        }
    }
}

/// How the big on-screen lyrics move (after Verci's styles).
enum ScreenLyricsStyle: String, CaseIterable, Identifiable {
    /// A stack of single words seen through a glass lens.
    case fisheye
    /// The last few lines on a wall that drifts in 3D; words pop in as they're sung.
    case wall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fisheye: "Fisheye"
        case .wall: "Wall"
        }
    }
}

/// Where the edge glow takes its colors from (after Lumn's rim).
enum EdgeGlowColors: String, CaseIterable, Identifiable {
    case album
    case one
    case two

    var id: String { rawValue }

    var title: String {
        switch self {
        case .album: "From the Album"
        case .one: "One Color"
        case .two: "Two Colors"
        }
    }
}

/// When the island drops a paused song and goes back to resting (Canopy's "Hide the player
/// when music pauses"). The raw value is the delay in seconds; never keeps it showing.
enum PausedPlayerHide: Int, CaseIterable, Identifiable {
    case never = -1
    case instantly = 0
    case tenSeconds = 10
    case oneMinute = 60

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .instantly: "Instantly"
        case .tenSeconds: "After 10 Seconds"
        case .oneMinute: "After 1 Minute"
        }
    }
}

/// How the charging alert draws the battery.
enum BatteryIconStyle: String, CaseIterable, Identifiable {
    case battery
    case ring
    case percent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: "Battery"
        case .ring: "Ring"
        case .percent: "Percentage Only"
        }
    }
}

/// What happens to a file after it arrives through Portal.
enum PortalAfterReceive: String, CaseIterable, Identifiable {
    case shelf
    case reveal
    case open
    case nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shelf: "Put It on the Shelf"
        case .reveal: "Show in Finder"
        case .open: "Open It"
        case .nothing: "Just Save It"
        }
    }
}

/// Where Face ID shows that it's looking for you on the lock screen.
enum FaceIDStyle: String, CaseIterable, Identifiable {
    /// A slim pill at the top: a lock and the Face ID mark, in the island.
    case pill
    /// A big, clean square with the Face ID mark.
    case square

    var id: String { rawValue }
    var title: String { self == .pill ? "Pill" : "Square" }
}

/// How the portal looks when something goes through, on the Mac and the phone.
enum PortalEffect: String, CaseIterable, Identifiable {
    case vortex
    case ripple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vortex: "Vortex"
        case .ripple: "Ripple"
        }
    }
}

enum LevelPosition: String, CaseIterable, Identifiable {
    case island
    case leftEdge
    case rightEdge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .island: "In the Island"
        case .leftEdge: "Left Edge"
        case .rightEdge: "Right Edge"
        }
    }
}

/// A widget in the row under the lock-screen clock. The user picks which ones show and
/// in what order (Settings → Lock Screen).
enum LockWidget: String, CaseIterable, Identifiable {
    case weather
    case battery
    case nowPlaying
    case volume
    case headphones
    case date
    case worldClock
    case cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: "Weather"
        case .battery: "Battery"
        case .nowPlaying: "Now Playing"
        case .volume: "Volume"
        case .headphones: "Headphones"
        case .date: "Date"
        case .worldClock: "World Clock"
        case .cpu: "CPU"
        }
    }

    var symbol: String {
        switch self {
        case .weather: "cloud.sun.fill"
        case .battery: "battery.75percent"
        case .nowPlaying: "music.note"
        case .volume: "speaker.wave.2.fill"
        case .headphones: "airpods.pro"
        case .date: "calendar"
        case .worldClock: "globe"
        case .cpu: "cpu"
        }
    }

    /// Shown under the name in Settings, for widgets that aren't always there.
    var note: String? {
        switch self {
        case .weather: "Uses your location"
        case .nowPlaying: "While something plays"
        case .headphones: "While connected"
        case .battery: "Laptops only"
        default: nil
        }
    }

    /// Tile width; the rest are circles.
    var width: CGFloat { self == .nowPlaying ? 222 : 66 }

    static let spacing: CGFloat = 12
    /// What fits across the widgets window (`LockLayout.widgetsSize`) with a margin.
    static let rowWidth: CGFloat = 620

    static func width(of widgets: [LockWidget]) -> CGFloat {
        widgets.map(\.width).reduce(0, +) + spacing * CGFloat(max(widgets.count - 1, 0))
    }

    /// Whether `widget` still fits after `widgets`.
    static func fits(_ widget: LockWidget, after widgets: [LockWidget]) -> Bool {
        width(of: widgets + [widget]) <= rowWidth
    }

    static let standard: [LockWidget] = [.battery, .nowPlaying, .volume, .headphones]
}

/// User preferences plus the app's Application Support locations.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let hover = "expandOnHover"
        static let lockWidget = "lockWidgetEnabled"
        static let lockSound = "lockSoundStyle"
        static let motion = "animatedArtworkEnabled"
        static let islandStyle = "islandStyle"
        static let accentTheme = "accentTheme"
        static let portalTheme = "portalTheme"
        static let standbyEnabled = "standbyEnabled"
        static let standbyIdleMinutes = "standbyIdleMinutes"
        static let standbyKeepAwake = "standbyKeepAwake"
        static let glassTransparency = "glassTransparency"
        static let islandWidth = "islandWidthScale"
        static let islandHeight = "islandHeightScale"
        static let notchWidth = "notchWidthAdjust"
        static let notchHeight = "notchHeightAdjust"
        static let haptics = "hapticsEnabled"
        static let forceClick = "hapticsForceClick"
        static let detentSpacing = "detentSpacing"
        static let onboarded = "onboardingDone"
        static let batterySaver = "batterySaver"
        static let lyricsOffset = "lyricsOffset"
        static let source = "playerSource"
        static let volumeHUD = "showVolumeInIsland"
        static let brightnessHUD = "showBrightnessInIsland"
        static let headphoneCards = "showHeadphonesInIsland"
        static let replaceHUD = "replaceSystemIndicator"
        static let agentAlerts = "showAgentAlerts"
        static let shelf = "shelfEnabled"
        static let privacyDots = "showPrivacyDots"
        static let lowBattery = "showLowBattery"
        static let islandLyrics = "showIslandLyrics"
        static let islandClock = "islandClock"
        static let lyricStyle = "lyricStyle"
        static let wordIcons = "lyricWordIcons"
        static let screenLyrics = "screenLyrics"
        static let screenLyricsPlace = "screenLyricsPlace"
        static let screenLyricsSize = "screenLyricsSize"
        static let screenLyricsFont = "screenLyricsFont"
        static let screenLyricsAutoColors = "screenLyricsAutoColors"
        static let screenLyricsText = "screenLyricsTextColor"
        static let screenLyricsHighlight = "screenLyricsHighlightColor"
        static let screenLyricsBoxText = "screenLyricsHighlightTextColor"
        static let screenLyricsAwake = "screenLyricsKeepAwake"
        static let edgeGlow = "edgeGlow"
        static let edgeGlowStrength = "edgeGlowStrength"
        static let edgeGlowWidth = "edgeGlowWidth"
        static let edgeGlowBeat = "edgeGlowBeat"
        static let edgeGlowColors = "edgeGlowColors"
        static let edgeGlowColor1 = "edgeGlowColor1"
        static let edgeGlowColor2 = "edgeGlowColor2"
        static let edgeGlowNotch = "edgeGlowNotch"
        static let edgeGlowAllDisplays = "edgeGlowAllDisplays"
        static let screenLyricsStyle = "screenLyricsStyle"
        static let shelfCopies = "shelfKeepsCopies"
        static let emulateNotch = AppSettings.emulateNotchKey
        static let levelPosition = "levelPosition"
        static let hideFromCapture = "hideFromScreenCapture"
        static let portal = "portalEnabled"
        static let faceID = "faceIDEnabled"
        static let faceStrictness = "faceIDStrictness"
        static let faceLiveness = "faceIDLiveness"
        static let faceStyle = "faceIDStyle"
        static let faceDuration = "faceIDDuration"
        static let faceOnWake = "faceIDOnWake"
        static let faceOnLock = "faceIDOnLock"
        static let faceOnClick = "faceIDOnClick"
        static let faceLearn = "faceIDLearn"
        static let faceBlinkNudge = "faceIDBlinkNudge"
        static let portalFolder = "portalSaveFolder"
        static let portalAfter = "portalAfterReceive"
        static let portalLinks = "portalOpenLinks"
        static let portalEdge = "portalEdgeSend"
        static let portalEffect = "portalEffect"
        static let portalShowEffect = "portalShowEffect"
        static let portalHaptics = "portalHaptics"
        static let hidePaused = "hidePausedPlayer"
        static let swipeToSkip = "swipeToSkip"
        static let chargingAlert = "showChargingAlert"
        static let chargingDuration = "chargingAlertDuration"
        static let batteryIcon = "batteryIconStyle"
        static let clipboard = "clipboardHistory"
        static let waveform = "liveWaveform"
        static let equalizer = "equalizerEnabled"
        static let eqBands = "equalizerBands"
        static let eqPreamp = "equalizerPreamp"
        static let eqPreset = "equalizerPreset"
        static let lockWeather = "lockWeather"
        static let lockWidgetList = "lockWidgets"
        static let worldClockZone = "worldClockZone"
        static let lockHeadphones = "lockHeadphones"
        static let lockMotion = "lockMotionBackground"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var expandOnHover: Bool {
        didSet { defaults.set(expandOnHover, forKey: Key.hover) }
    }
    var lockWidgetEnabled: Bool {
        didSet { defaults.set(lockWidgetEnabled, forKey: Key.lockWidget) }
    }
    var lockSoundStyle: LockSoundStyle {
        didSet { defaults.set(lockSoundStyle.rawValue, forKey: Key.lockSound) }
    }
    var animatedArtworkEnabled: Bool {
        didSet { defaults.set(animatedArtworkEnabled, forKey: Key.motion) }
    }
    /// Settings → Appearance: the colors of controls, Portal, Standby and the sidebar.
    var accentTheme: AccentTheme {
        didSet { defaults.set(accentTheme.rawValue, forKey: Key.accentTheme) }
    }
    /// Portal's own colors; nil follows `accentTheme`.
    var portalTheme: AccentTheme? {
        didSet { defaults.set(portalTheme?.rawValue ?? "", forKey: Key.portalTheme) }
    }
    var portalColors: AccentTheme { portalTheme ?? accentTheme }

    /// Standby: a full-screen clock while the Mac charges and nobody is using it.
    var standbyEnabled: Bool {
        didSet { defaults.set(standbyEnabled, forKey: Key.standbyEnabled) }
    }
    /// Idle minutes on the charger before Standby starts.
    var standbyIdleMinutes: Int {
        didSet { defaults.set(standbyIdleMinutes, forKey: Key.standbyIdleMinutes) }
    }
    /// Holds off display sleep while Standby is up.
    var standbyKeepAwake: Bool {
        didSet { defaults.set(standbyKeepAwake, forKey: Key.standbyKeepAwake) }
    }

    var islandStyle: IslandStyle {
        didSet { defaults.set(islandStyle.rawValue, forKey: Key.islandStyle); LiveTuning.shared.clearGlass = islandStyle == .clearGlass }
    }
    /// 0 = frosted and smoky, 0.5 = Apple's stock glass, 1 = fully clear.
    var glassTransparency: Double {
        didSet { save(glassTransparency, Key.glassTransparency); LiveTuning.shared.glassTransparency = glassTransparency }
    }
    /// Island size multipliers (the notch fixes the height on notched Macs).
    var islandWidthScale: Double {
        didSet { save(islandWidthScale, Key.islandWidth); LiveTuning.shared.widthScale = islandWidthScale }
    }
    var islandHeightScale: Double {
        didSet { save(islandHeightScale, Key.islandHeight); LiveTuning.shared.heightScale = islandHeightScale }
    }
    /// Points added to the measured notch, if it ever reports a little off.
    var notchWidthAdjust: Double {
        didSet { save(notchWidthAdjust, Key.notchWidth); LiveTuning.shared.notchWidthAdjust = notchWidthAdjust }
    }
    var notchHeightAdjust: Double {
        didSet { save(notchHeightAdjust, Key.notchHeight); LiveTuning.shared.notchHeightAdjust = notchHeightAdjust }
    }
    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.haptics); LiveTuning.shared.hapticsEnabled = hapticsEnabled }
    }
    /// Force-click strength through the trackpad motor, or the standard system haptic.
    var hapticsForceClick: Bool {
        didSet { defaults.set(hapticsForceClick, forKey: Key.forceClick); LiveTuning.shared.forceClick = hapticsForceClick }
    }
    /// Points of slider travel between haptic detents.
    var detentSpacing: Double {
        didSet { save(detentSpacing, Key.detentSpacing); LiveTuning.shared.detentSpacing = detentSpacing }
    }
    var batterySaver: BatterySaver {
        didSet {
            defaults.set(batterySaver.rawValue, forKey: Key.batterySaver)
            LiveTuning.shared.saverMode = batterySaver
            LiveTuning.shared.refreshBatterySaving()
        }
    }
    /// Seconds lyrics run ahead (+) or behind (−) the music, for songs whose timing is off.
    var lyricsOffset: Double {
        didSet { save(lyricsOffset, Key.lyricsOffset); LiveTuning.shared.lyricsOffset = lyricsOffset }
    }
    var lyricStyle: LyricStyle {
        didSet { defaults.set(lyricStyle.rawValue, forKey: Key.lyricStyle); LiveTuning.shared.lyricStyle = lyricStyle }
    }
    /// Small pictures over words like "fire" or "rain" as they're sung.
    var lyricWordIcons: Bool {
        didSet { defaults.set(lyricWordIcons, forKey: Key.wordIcons); LiveTuning.shared.lyricWordIcons = lyricWordIcons }
    }
    /// Big lyrics on the screen itself, a word at a time, while music plays.
    var screenLyrics: Bool {
        didSet { defaults.set(screenLyrics, forKey: Key.screenLyrics) }
    }
    var screenLyricsPlace: ScreenLyricsPlace {
        didSet { defaults.set(screenLyricsPlace.rawValue, forKey: Key.screenLyricsPlace) }
    }
    var screenLyricsSize: Double {
        didSet { save(screenLyricsSize, Key.screenLyricsSize) }
    }
    var screenLyricsFont: ScreenLyricsFont {
        didSet { defaults.set(screenLyricsFont.rawValue, forKey: Key.screenLyricsFont); LiveTuning.shared.screenLyricsFont = screenLyricsFont }
    }
    /// Colors from the album artwork instead of the three picked below.
    var screenLyricsAutoColors: Bool {
        didSet { defaults.set(screenLyricsAutoColors, forKey: Key.screenLyricsAutoColors); publishScreenLyricsColors() }
    }
    /// Words already sung.
    var screenLyricsTextColor: RGB {
        didSet { defaults.set(screenLyricsTextColor.hex, forKey: Key.screenLyricsText); publishScreenLyricsColors() }
    }
    /// The box behind the word being sung, and the icons.
    var screenLyricsHighlightColor: RGB {
        didSet { defaults.set(screenLyricsHighlightColor.hex, forKey: Key.screenLyricsHighlight); publishScreenLyricsColors() }
    }
    /// The word being sung, inside its box.
    var screenLyricsHighlightTextColor: RGB {
        didSet { defaults.set(screenLyricsHighlightTextColor.hex, forKey: Key.screenLyricsBoxText); publishScreenLyricsColors() }
    }

    /// The player draws the Fisheye lyrics too, from `LiveTuning`.
    private func publishScreenLyricsColors() {
        LiveTuning.shared.screenLyricsColors = screenLyricsAutoColors
            ? nil : [screenLyricsTextColor, screenLyricsHighlightColor, screenLyricsHighlightTextColor]
    }
    /// The display stays on while the on-screen lyrics show (the lock screen dims after a minute).
    var screenLyricsKeepAwake: Bool {
        didSet { defaults.set(screenLyricsKeepAwake, forKey: Key.screenLyricsAwake) }
    }

    /// A soft light around the screen's edges in the album's colors while music plays.
    var edgeGlow: Bool {
        didSet { defaults.set(edgeGlow, forKey: Key.edgeGlow) }
    }
    var edgeGlowStrength: Double {
        didSet { save(edgeGlowStrength, Key.edgeGlowStrength) }
    }

    /// How wide the glow reaches in from the edge (1 is the standard width).
    var edgeGlowWidth: Double {
        didSet { save(edgeGlowWidth, Key.edgeGlowWidth) }
    }
    /// The glow pulses with the music's beat (needs Audio Recording access, like the live waveform).
    var edgeGlowBeat: Bool {
        didSet { defaults.set(edgeGlowBeat, forKey: Key.edgeGlowBeat) }
    }
    var edgeGlowColors: EdgeGlowColors {
        didSet { defaults.set(edgeGlowColors.rawValue, forKey: Key.edgeGlowColors) }
    }
    var edgeGlowColor1: RGB {
        didSet { defaults.set(edgeGlowColor1.hex, forKey: Key.edgeGlowColor1) }
    }
    var edgeGlowColor2: RGB {
        didSet { defaults.set(edgeGlowColor2.hex, forKey: Key.edgeGlowColor2) }
    }
    /// On a Mac with a notch, the glow runs around the notch instead of under it.
    var edgeGlowNotch: Bool {
        didSet { defaults.set(edgeGlowNotch, forKey: Key.edgeGlowNotch) }
    }
    var edgeGlowAllDisplays: Bool {
        didSet { defaults.set(edgeGlowAllDisplays, forKey: Key.edgeGlowAllDisplays) }
    }
    var screenLyricsStyle: ScreenLyricsStyle {
        didSet { defaults.set(screenLyricsStyle.rawValue, forKey: Key.screenLyricsStyle); LiveTuning.shared.screenLyricsStyle = screenLyricsStyle }
    }

    static let edgeGlowStrengthRange: ClosedRange<Double> = 0.3...1
    static let edgeGlowWidthRange: ClosedRange<Double> = 0.5...2
    static let screenLyricsSizeRange: ClosedRange<Double> = 0.5...1.5
    static let defaultScreenLyricsColors = (text: RGB(0.91, 0.58, 0.47), highlight: RGB(0.86, 0.38, 0.49),
                                            highlightText: RGB(1, 1, 1))

    func resetScreenLyricsColors() {
        screenLyricsTextColor = Self.defaultScreenLyricsColors.text
        screenLyricsHighlightColor = Self.defaultScreenLyricsColors.highlight
        screenLyricsHighlightTextColor = Self.defaultScreenLyricsColors.highlightText
    }

    /// Which player Islet follows.
    var playerSource: PlayerSource {
        didSet { defaults.set(playerSource.rawValue, forKey: Key.source) }
    }
    /// Live activities in the island.
    var showVolumeInIsland: Bool {
        didSet { defaults.set(showVolumeInIsland, forKey: Key.volumeHUD) }
    }
    var showBrightnessInIsland: Bool {
        didSet { defaults.set(showBrightnessInIsland, forKey: Key.brightnessHUD) }
    }
    var showHeadphonesInIsland: Bool {
        didSet { defaults.set(showHeadphonesInIsland, forKey: Key.headphoneCards) }
    }
    /// Islet handles the volume and brightness keys, hiding the macOS indicator.
    var replaceSystemIndicator: Bool {
        didSet { defaults.set(replaceSystemIndicator, forKey: Key.replaceHUD) }
    }
    /// Claude Code / Codex alerts in the island.
    var showAgentAlerts: Bool {
        didSet { defaults.set(showAgentAlerts, forKey: Key.agentAlerts) }
    }
    /// Dragging files to the island keeps them on its shelf.
    var shelfEnabled: Bool {
        didSet { defaults.set(shelfEnabled, forKey: Key.shelf) }
    }
    nonisolated static let emulateNotchKey = "emulateNotch"
    /// On a Mac without a notch, lays the island out as if it had one.
    var emulateNotch: Bool {
        didSet { defaults.set(emulateNotch, forKey: Key.emulateNotch) }
    }
    /// The shelf keeps its own copies of dropped files (in Application Support).
    var shelfKeepsCopies: Bool {
        didSet { defaults.set(shelfKeepsCopies, forKey: Key.shelfCopies) }
    }
    var showPrivacyDots: Bool {
        didSet { defaults.set(showPrivacyDots, forKey: Key.privacyDots) }
    }
    var showLowBattery: Bool {
        didSet { defaults.set(showLowBattery, forKey: Key.lowBattery) }
    }
    /// A small clock in the resting island when nothing is playing.
    var islandClock: Bool {
        didSet { defaults.set(islandClock, forKey: Key.islandClock) }
    }
    /// The line being sung, under the artist in the open island.
    var showIslandLyrics: Bool {
        didSet { defaults.set(showIslandLyrics, forKey: Key.islandLyrics); LiveTuning.shared.showIslandLyrics = showIslandLyrics }
    }
    /// Where the volume and brightness level shows: the island, or a slider at a screen edge.
    var levelPosition: LevelPosition {
        didSet { defaults.set(levelPosition.rawValue, forKey: Key.levelPosition) }
    }
    /// Face ID: unlock by looking at the Mac. Off until the user sets it up.
    var faceIDEnabled: Bool {
        didSet { defaults.set(faceIDEnabled, forKey: Key.faceID) }
    }
    /// 0 easier … 1 stricter (`FaceID.threshold`).
    var faceIDStrictness: Double {
        didSet { defaults.set(faceIDStrictness, forKey: Key.faceStrictness) }
    }
    var faceIDLiveness: FaceLiveness {
        didSet { defaults.set(faceIDLiveness.rawValue, forKey: Key.faceLiveness) }
    }
    var faceIDStyle: FaceIDStyle {
        didSet { defaults.set(faceIDStyle.rawValue, forKey: Key.faceStyle) }
    }
    /// Seconds it looks for you each time.
    var faceIDDuration: Double {
        didSet { defaults.set(faceIDDuration, forKey: Key.faceDuration) }
    }
    /// When it looks: the display waking, right after locking, a click on the notch.
    var faceIDOnWake: Bool {
        didSet { defaults.set(faceIDOnWake, forKey: Key.faceOnWake) }
    }
    var faceIDOnLock: Bool {
        didSet { defaults.set(faceIDOnLock, forKey: Key.faceOnLock) }
    }
    /// Face ID keeps new looks of you from unlocks (`FaceIDController.learn`).
    var faceIDLearn: Bool {
        didSet { defaults.set(faceIDLearn, forKey: Key.faceLearn) }
    }
    /// A quick white flash when liveness is waiting for a blink (`considerBlinkNudge`).
    var faceIDBlinkNudge: Bool {
        didSet { defaults.set(faceIDBlinkNudge, forKey: Key.faceBlinkNudge) }
    }
    var faceIDOnClick: Bool {
        didSet { defaults.set(faceIDOnClick, forKey: Key.faceOnClick) }
    }
    /// Portal: the Mac listens on the local network for paired iPhones.
    var portalEnabled: Bool {
        didSet { defaults.set(portalEnabled, forKey: Key.portal) }
    }
    /// Where received photos, videos and files are saved.
    var portalSaveFolder: URL {
        didSet { defaults.set(portalSaveFolder.path, forKey: Key.portalFolder) }
    }
    var portalAfterReceive: PortalAfterReceive {
        didSet { defaults.set(portalAfterReceive.rawValue, forKey: Key.portalAfter) }
    }
    /// Received web links open in the browser (they're always copied too).
    var portalOpenLinks: Bool {
        didSet { defaults.set(portalOpenLinks, forKey: Key.portalLinks) }
    }
    /// Dragging to the right edge of the screen sends to the phone.
    var portalEdgeSend: Bool {
        didSet { defaults.set(portalEdgeSend, forKey: Key.portalEdge) }
    }
    var portalEffect: PortalEffect {
        didSet { defaults.set(portalEffect.rawValue, forKey: Key.portalEffect) }
    }
    /// Arrivals play their animation in the island.
    var portalShowEffect: Bool {
        didSet { defaults.set(portalShowEffect, forKey: Key.portalShowEffect) }
    }
    var portalHaptics: Bool {
        didSet { defaults.set(portalHaptics, forKey: Key.portalHaptics) }
    }
    /// Islet's windows are left out of screenshots, recordings and screen sharing.
    var hideFromScreenCapture: Bool {
        didSet { defaults.set(hideFromScreenCapture, forKey: Key.hideFromCapture) }
    }
    var hidePausedPlayer: PausedPlayerHide {
        didSet { defaults.set(hidePausedPlayer.rawValue, forKey: Key.hidePaused) }
    }
    /// Two fingers left or right over the island change the song.
    var swipeToSkip: Bool {
        didSet { defaults.set(swipeToSkip, forKey: Key.swipeToSkip) }
    }
    var showChargingAlert: Bool {
        didSet { defaults.set(showChargingAlert, forKey: Key.chargingAlert) }
    }
    /// Seconds the charging alert stays up.
    var chargingAlertDuration: Double {
        didSet { defaults.set(chargingAlertDuration, forKey: Key.chargingDuration) }
    }
    var batteryIconStyle: BatteryIconStyle {
        didSet { defaults.set(batteryIconStyle.rawValue, forKey: Key.batteryIcon) }
    }
    /// The shelf's Clipboard tab keeps what was copied (in memory only).
    var clipboardHistory: Bool {
        didSet { defaults.set(clipboardHistory, forKey: Key.clipboard); ClipboardHistory.shared.isEnabled = clipboardHistory }
    }
    /// The bars follow the playing app's real audio (needs audio recording permission).
    var liveWaveform: Bool {
        didSet { defaults.set(liveWaveform, forKey: Key.waveform) }
    }
    /// The equalizer for Apple Music and Spotify.
    var equalizerEnabled: Bool {
        didSet { defaults.set(equalizerEnabled, forKey: Key.equalizer) }
    }
    /// Gain of each band in dB (see `Equalizer.frequencies`).
    var equalizerBands: [Double] {
        didSet { defaults.set(equalizerBands, forKey: Key.eqBands) }
    }
    /// Overall gain in dB before the bands, to make room for boosts.
    var equalizerPreamp: Double {
        didSet { save(equalizerPreamp, Key.eqPreamp) }
    }
    /// The preset the bands came from; nil once they're edited by hand.
    var equalizerPreset: EqualizerPreset? {
        didSet { defaults.set(equalizerPreset?.rawValue, forKey: Key.eqPreset) }
    }
    /// The widgets under the lock-screen clock, in order.
    var lockWidgets: [LockWidget] {
        didSet { defaults.set(lockWidgets.map(\.rawValue), forKey: Key.lockWidgetList) }
    }
    var lockWeather: Bool { lockWidgets.contains(.weather) }
    var lockHeadphones: Bool { lockWidgets.contains(.headphones) }
    /// The World Clock widget's time zone (an IANA identifier).
    var worldClockZone: String {
        didSet { defaults.set(worldClockZone, forKey: Key.worldClockZone) }
    }
    /// Motion artwork fills the lock screen behind the widgets while music plays.
    var lockMotionBackground: Bool {
        didSet { defaults.set(lockMotionBackground, forKey: Key.lockMotion) }
    }
    /// The release whose tutorial was last seen; "What's New" covers anything newer.
    var tutorialVersion: String? {
        didSet { defaults.set(tutorialVersion, forKey: "tutorialVersion") }
    }
    /// The first-launch tutorial has been seen.
    var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: Key.onboarded) }
    }
    /// Apple Music API developer token (paid Apple Developer Program), stored in a 0600 file.
    private(set) var developerToken: String?
    /// Apple Music user token (the user's own subscription), stored the same way. With the
    /// developer token it unlocks Apple's word-timed lyrics.
    private(set) var musicUserToken: String?

    let supportDirectory: URL
    var lyricsCacheDirectory: URL { supportDirectory.appending(path: "LyricsCache") }
    var customSoundsDirectory: URL { supportDirectory.appending(path: "Sounds") }
    private var tokenURL: URL { supportDirectory.appending(path: "developer-token") }
    private var userTokenURL: URL { supportDirectory.appending(path: "music-user-token") }

    init() {
        defaults.register(defaults: [
            Key.hover: true,
            Key.lockWidget: true,
            Key.lockSound: LockSoundStyle.iPhone.rawValue,
            Key.motion: true,
            Key.islandStyle: IslandStyle.black.rawValue,
            Key.standbyEnabled: true,
            Key.standbyIdleMinutes: 5,
            Key.standbyKeepAwake: false,
            Key.glassTransparency: 0.5,
            Key.islandWidth: 1.0,
            Key.islandHeight: 1.0,
            Key.notchWidth: 0.0,
            Key.notchHeight: 0.0,
            Key.haptics: true,
            Key.forceClick: true,
            Key.detentSpacing: 5.0,
            Key.onboarded: false,
            Key.batterySaver: BatterySaver.automatic.rawValue,
            Key.lyricsOffset: 0.0,
            Key.source: PlayerSource.automatic.rawValue,
            Key.volumeHUD: true,
            Key.brightnessHUD: true,
            Key.headphoneCards: true,
            Key.replaceHUD: false,
            Key.agentAlerts: true,
            Key.shelf: true,
            Key.privacyDots: true,
            Key.islandLyrics: true,
            Key.islandClock: false,
            Key.lyricStyle: LyricStyle.wordByWord.rawValue,
            Key.wordIcons: false,
            Key.screenLyrics: true,
            // The desktop is for working: big lyrics there only when asked for.
            Key.screenLyricsPlace: ScreenLyricsPlace.lockScreen.rawValue,
            Key.screenLyricsFont: ScreenLyricsFont.sfPro.rawValue,
            Key.screenLyricsSize: 1.0,
            Key.screenLyricsAutoColors: true,
            Key.screenLyricsAwake: true,
            Key.edgeGlow: true,
            Key.edgeGlowStrength: 0.8,
            Key.edgeGlowWidth: 1.0,
            Key.edgeGlowBeat: false,
            Key.edgeGlowColors: EdgeGlowColors.album.rawValue,
            Key.edgeGlowNotch: true,
            Key.edgeGlowAllDisplays: false,
            Key.screenLyricsStyle: ScreenLyricsStyle.fisheye.rawValue,
            Key.lowBattery: true,
            Key.levelPosition: LevelPosition.island.rawValue,
            Key.hideFromCapture: false,
            Key.portal: false,
            Key.faceID: false,
            Key.faceStrictness: 0.4,
            Key.faceLiveness: FaceLiveness.natural.rawValue,
            Key.faceStyle: FaceIDStyle.pill.rawValue,
            Key.faceDuration: 5.0,
            Key.faceOnWake: true,
            Key.faceOnLock: false,
            Key.faceOnClick: true,
            Key.faceLearn: true,
            Key.faceBlinkNudge: true,
            Key.portalAfter: PortalAfterReceive.shelf.rawValue,
            Key.portalLinks: true,
            Key.portalEdge: true,
            Key.portalEffect: PortalEffect.vortex.rawValue,
            Key.portalShowEffect: true,
            Key.portalHaptics: true,
            Key.hidePaused: PausedPlayerHide.never.rawValue,
            Key.swipeToSkip: true,
            Key.chargingAlert: true,
            Key.chargingDuration: 3.5,
            Key.batteryIcon: BatteryIconStyle.battery.rawValue,
            Key.clipboard: true,
            Key.waveform: false,
            Key.equalizer: false,
            Key.eqPreamp: 0.0,
            Key.lockWeather: false,
            Key.lockHeadphones: true,
            Key.lockMotion: true,
        ])
        supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Islet")
        expandOnHover = defaults.bool(forKey: Key.hover)
        lockWidgetEnabled = defaults.bool(forKey: Key.lockWidget)
        lockSoundStyle = LockSoundStyle(rawValue: defaults.string(forKey: Key.lockSound) ?? "") ?? .iPhone
        animatedArtworkEnabled = defaults.bool(forKey: Key.motion)
        islandStyle = IslandStyle(rawValue: defaults.string(forKey: Key.islandStyle) ?? "") ?? .black
        accentTheme = AccentTheme(rawValue: defaults.string(forKey: Key.accentTheme) ?? "") ?? .aurora
        portalTheme = AccentTheme(rawValue: defaults.string(forKey: Key.portalTheme) ?? "")
        standbyEnabled = defaults.bool(forKey: Key.standbyEnabled)
        standbyIdleMinutes = max(1, defaults.integer(forKey: Key.standbyIdleMinutes))
        standbyKeepAwake = defaults.bool(forKey: Key.standbyKeepAwake)
        glassTransparency = Self.clamped(defaults.double(forKey: Key.glassTransparency), 0...1)
        islandWidthScale = Self.clamped(defaults.double(forKey: Key.islandWidth), Self.sizeRange)
        islandHeightScale = Self.clamped(defaults.double(forKey: Key.islandHeight), Self.sizeRange)
        notchWidthAdjust = Self.clamped(defaults.double(forKey: Key.notchWidth), Self.notchRange)
        notchHeightAdjust = Self.clamped(defaults.double(forKey: Key.notchHeight), Self.notchRange)
        hapticsEnabled = defaults.bool(forKey: Key.haptics)
        hapticsForceClick = defaults.bool(forKey: Key.forceClick)
        detentSpacing = Self.clamped(defaults.double(forKey: Key.detentSpacing), Self.detentRange)
        onboardingDone = defaults.bool(forKey: Key.onboarded)
        batterySaver = BatterySaver(rawValue: defaults.string(forKey: Key.batterySaver) ?? "") ?? .automatic
        lyricsOffset = Self.clamped(defaults.double(forKey: Key.lyricsOffset), Self.lyricsOffsetRange)
        playerSource = PlayerSource(rawValue: defaults.string(forKey: Key.source) ?? "") ?? .automatic
        showVolumeInIsland = defaults.bool(forKey: Key.volumeHUD)
        showBrightnessInIsland = defaults.bool(forKey: Key.brightnessHUD)
        showHeadphonesInIsland = defaults.bool(forKey: Key.headphoneCards)
        replaceSystemIndicator = defaults.bool(forKey: Key.replaceHUD)
        showAgentAlerts = defaults.bool(forKey: Key.agentAlerts)
        shelfEnabled = defaults.bool(forKey: Key.shelf)
        showPrivacyDots = defaults.bool(forKey: Key.privacyDots)
        showLowBattery = defaults.bool(forKey: Key.lowBattery)
        showIslandLyrics = defaults.bool(forKey: Key.islandLyrics)
        islandClock = defaults.bool(forKey: Key.islandClock)
        lyricStyle = LyricStyle(rawValue: defaults.string(forKey: Key.lyricStyle) ?? "") ?? .wordByWord
        lyricWordIcons = defaults.bool(forKey: Key.wordIcons)
        screenLyrics = defaults.bool(forKey: Key.screenLyrics)
        screenLyricsPlace = ScreenLyricsPlace(rawValue: defaults.string(forKey: Key.screenLyricsPlace) ?? "") ?? .lockScreen
        screenLyricsFont = ScreenLyricsFont(rawValue: defaults.string(forKey: Key.screenLyricsFont) ?? "") ?? .sfPro
        screenLyricsSize = Self.clamped(defaults.double(forKey: Key.screenLyricsSize), Self.screenLyricsSizeRange)
        screenLyricsAutoColors = defaults.bool(forKey: Key.screenLyricsAutoColors)
        let colors = Self.defaultScreenLyricsColors
        screenLyricsTextColor = defaults.string(forKey: Key.screenLyricsText).flatMap(RGB.init(hex:)) ?? colors.text
        screenLyricsHighlightColor = defaults.string(forKey: Key.screenLyricsHighlight).flatMap(RGB.init(hex:)) ?? colors.highlight
        screenLyricsHighlightTextColor = defaults.string(forKey: Key.screenLyricsBoxText).flatMap(RGB.init(hex:)) ?? colors.highlightText
        screenLyricsKeepAwake = defaults.bool(forKey: Key.screenLyricsAwake)
        edgeGlow = defaults.bool(forKey: Key.edgeGlow)
        edgeGlowStrength = Self.clamped(defaults.double(forKey: Key.edgeGlowStrength), Self.edgeGlowStrengthRange)
        edgeGlowWidth = Self.clamped(defaults.double(forKey: Key.edgeGlowWidth), Self.edgeGlowWidthRange)
        edgeGlowBeat = defaults.bool(forKey: Key.edgeGlowBeat)
        edgeGlowColors = EdgeGlowColors(rawValue: defaults.string(forKey: Key.edgeGlowColors) ?? "") ?? .album
        edgeGlowColor1 = defaults.string(forKey: Key.edgeGlowColor1).flatMap(RGB.init(hex:)) ?? RGB(0.98, 0.36, 0.6)
        edgeGlowColor2 = defaults.string(forKey: Key.edgeGlowColor2).flatMap(RGB.init(hex:)) ?? RGB(0.36, 0.55, 1)
        edgeGlowNotch = defaults.bool(forKey: Key.edgeGlowNotch)
        edgeGlowAllDisplays = defaults.bool(forKey: Key.edgeGlowAllDisplays)
        screenLyricsStyle = ScreenLyricsStyle(rawValue: defaults.string(forKey: Key.screenLyricsStyle) ?? "") ?? .fisheye
        shelfKeepsCopies = defaults.bool(forKey: Key.shelfCopies)
        emulateNotch = defaults.bool(forKey: Key.emulateNotch)
        levelPosition = LevelPosition(rawValue: defaults.string(forKey: Key.levelPosition) ?? "") ?? .island
        hideFromScreenCapture = defaults.bool(forKey: Key.hideFromCapture)
        portalEnabled = defaults.bool(forKey: Key.portal)
        faceIDEnabled = defaults.bool(forKey: Key.faceID)
        faceIDStrictness = Self.clamped(defaults.double(forKey: Key.faceStrictness), 0...1)
        faceIDLiveness = FaceLiveness(rawValue: defaults.string(forKey: Key.faceLiveness) ?? "") ?? .natural
        faceIDStyle = FaceIDStyle(rawValue: defaults.string(forKey: Key.faceStyle) ?? "") ?? .pill
        faceIDDuration = Self.clamped(defaults.double(forKey: Key.faceDuration), 2...15)
        faceIDOnWake = defaults.bool(forKey: Key.faceOnWake)
        faceIDOnLock = defaults.bool(forKey: Key.faceOnLock)
        faceIDOnClick = defaults.bool(forKey: Key.faceOnClick)
        faceIDLearn = defaults.bool(forKey: Key.faceLearn)
        faceIDBlinkNudge = defaults.bool(forKey: Key.faceBlinkNudge)
        portalSaveFolder = defaults.string(forKey: Key.portalFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        portalAfterReceive = PortalAfterReceive(rawValue: defaults.string(forKey: Key.portalAfter) ?? "") ?? .shelf
        portalOpenLinks = defaults.bool(forKey: Key.portalLinks)
        portalEdgeSend = defaults.bool(forKey: Key.portalEdge)
        portalEffect = PortalEffect(rawValue: defaults.string(forKey: Key.portalEffect) ?? "") ?? .vortex
        portalShowEffect = defaults.bool(forKey: Key.portalShowEffect)
        portalHaptics = defaults.bool(forKey: Key.portalHaptics)
        hidePausedPlayer = PausedPlayerHide(rawValue: defaults.integer(forKey: Key.hidePaused)) ?? .never
        swipeToSkip = defaults.bool(forKey: Key.swipeToSkip)
        showChargingAlert = defaults.bool(forKey: Key.chargingAlert)
        chargingAlertDuration = Self.clamped(defaults.double(forKey: Key.chargingDuration), 1.5...10)
        batteryIconStyle = BatteryIconStyle(rawValue: defaults.string(forKey: Key.batteryIcon) ?? "") ?? .battery
        clipboardHistory = defaults.bool(forKey: Key.clipboard)
        liveWaveform = defaults.bool(forKey: Key.waveform)
        equalizerEnabled = defaults.bool(forKey: Key.equalizer)
        let bands = (defaults.array(forKey: Key.eqBands) as? [Double]) ?? []
        equalizerBands = bands.count == Equalizer.frequencies.count
            ? bands.map { Self.clamped($0, Equalizer.gainRange) } : Equalizer.flat
        equalizerPreamp = Self.clamped(defaults.double(forKey: Key.eqPreamp), Equalizer.gainRange)
        equalizerPreset = defaults.string(forKey: Key.eqPreset).flatMap(EqualizerPreset.init(rawValue:))
        if let saved = defaults.stringArray(forKey: Key.lockWidgetList) {
            var widgets: [LockWidget] = []
            for widget in saved.compactMap(LockWidget.init(rawValue:))
            where !widgets.contains(widget) && LockWidget.fits(widget, after: widgets) {
                widgets.append(widget)
            }
            lockWidgets = widgets
        } else {
            // Before 1.7 the row was fixed, with switches for weather and headphones.
            lockWidgets = (defaults.bool(forKey: Key.lockWeather) ? [.weather] : [])
                + [.battery, .nowPlaying, .volume]
                + (defaults.bool(forKey: Key.lockHeadphones) ? [.headphones] : [])
        }
        worldClockZone = defaults.string(forKey: Key.worldClockZone)
            .flatMap { TimeZone(identifier: $0)?.identifier } ?? "America/New_York"
        lockMotionBackground = defaults.bool(forKey: Key.lockMotion)
        tutorialVersion = defaults.string(forKey: "tutorialVersion")
        ClipboardHistory.shared.isEnabled = clipboardHistory
        // didSet doesn't run in init: publish the loaded values to the live views.
        let live = LiveTuning.shared
        live.glassTransparency = glassTransparency
        live.clearGlass = islandStyle == .clearGlass
        live.widthScale = islandWidthScale
        live.heightScale = islandHeightScale
        live.notchWidthAdjust = notchWidthAdjust
        live.notchHeightAdjust = notchHeightAdjust
        live.hapticsEnabled = hapticsEnabled
        live.forceClick = hapticsForceClick
        live.detentSpacing = detentSpacing
        live.lyricsOffset = lyricsOffset
        live.showIslandLyrics = showIslandLyrics
        live.lyricStyle = lyricStyle
        live.lyricWordIcons = lyricWordIcons
        live.screenLyricsFont = screenLyricsFont
        live.screenLyricsStyle = screenLyricsStyle
        publishScreenLyricsColors()
        live.saverMode = batterySaver
        live.refreshBatterySaving()

        let fm = FileManager.default
        try? fm.createDirectory(at: lyricsCacheDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: customSoundsDirectory, withIntermediateDirectories: true)
        developerToken = Self.readToken(tokenURL)
        musicUserToken = Self.readToken(userTokenURL)
    }

    static let sizeRange: ClosedRange<Double> = 0.8...1.3
    static let notchRange: ClosedRange<Double> = -20...20
    static let detentRange: ClosedRange<Double> = 3...14
    static let lyricsOffsetRange: ClosedRange<Double> = -3...3

    /// Back to the defaults for everything on the Island and Haptics settings.
    func resetAppearance() {
        glassTransparency = 0.5
        islandWidthScale = 1
        islandHeightScale = 1
        notchWidthAdjust = 0
        notchHeightAdjust = 0
        hapticsEnabled = true
        hapticsForceClick = true
        detentSpacing = 5
    }

    private func save(_ value: Double, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private static func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }

    /// Applies an equalizer preset (Flat is the reset).
    func applyEqualizer(_ preset: EqualizerPreset) {
        equalizerBands = preset.bands
        equalizerPreamp = preset.preamp
        equalizerPreset = preset
    }

    func setDeveloperToken(_ token: String?) {
        developerToken = Self.writeToken(token, to: tokenURL)
    }

    func setMusicUserToken(_ token: String?) {
        musicUserToken = Self.writeToken(token, to: userTokenURL)
    }

    private static func readToken(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Saves (or, for nil, deletes) a token readable only by this user; returns what was saved.
    private static func writeToken(_ token: String?, to url: URL) -> String? {
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let cleaned {
            FileManager.default.createFile(atPath: url.path, contents: Data(cleaned.utf8),
                                           attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        return cleaned
    }
}

/// The settings the drawing code reads directly (glass material, island geometry, haptics),
/// kept in one observable place so every window follows a slider the moment it moves.
@MainActor
@Observable
final class LiveTuning {
    static let shared = LiveTuning()
    var glassTransparency = 0.5
    /// The Clear Liquid Glass style: the lock screen's tiles use the island's clear glass too.
    var clearGlass = false
    /// The Transparency slider on clear glass: fully transparent is crystal clear; lower
    /// values frost and darken it a little, so white text stays readable over bright pictures.
    var clearFrost: Double { (1 - glassTransparency) * 16 }
    var clearDim: Double { (1 - glassTransparency) * 0.3 }
    var widthScale = 1.0
    var heightScale = 1.0
    var notchWidthAdjust = 0.0
    var notchHeightAdjust = 0.0
    var hapticsEnabled = true
    var forceClick = true
    var detentSpacing = 5.0
    var lyricsOffset = 0.0
    var showIslandLyrics = true
    var lyricStyle = LyricStyle.wordByWord
    var lyricWordIcons = false
    var screenLyricsFont = ScreenLyricsFont.sfPro
    var screenLyricsStyle = ScreenLyricsStyle.fisheye
    /// Text, highlight and highlighted-text colors the user picked; nil: from the album.
    var screenLyricsColors: [RGB]?
    var saverMode = BatterySaver.automatic
    /// True while Islet should save power: label updates once a second, slower equalizer,
    /// a slower-moving background and no motion-artwork video.
    private(set) var batterySaving = false

    /// Re-evaluates the saver from the power source and Low Power Mode.
    func refreshBatterySaving() {
        let saving: Bool
        switch saverMode {
        case .always: saving = true
        case .off: saving = false
        case .automatic:
            let onBattery = Battery.current().map { !$0.isPluggedIn } ?? false
            saving = onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        if saving != batterySaving { batterySaving = saving }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
