import Foundation
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
        static let shelfCopies = "shelfKeepsCopies"
        static let emulateNotch = AppSettings.emulateNotchKey
        static let levelPosition = "levelPosition"
        static let clipboard = "clipboardHistory"
        static let waveform = "liveWaveform"
        static let equalizer = "equalizerEnabled"
        static let eqBands = "equalizerBands"
        static let eqPreamp = "equalizerPreamp"
        static let eqPreset = "equalizerPreset"
        static let lockWeather = "lockWeather"
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
    var islandStyle: IslandStyle {
        didSet { defaults.set(islandStyle.rawValue, forKey: Key.islandStyle) }
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
    /// The line being sung, under the artist in the open island.
    var showIslandLyrics: Bool {
        didSet { defaults.set(showIslandLyrics, forKey: Key.islandLyrics); LiveTuning.shared.showIslandLyrics = showIslandLyrics }
    }
    /// Where the volume and brightness level shows: the island, or a slider at a screen edge.
    var levelPosition: LevelPosition {
        didSet { defaults.set(levelPosition.rawValue, forKey: Key.levelPosition) }
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
    /// Lock-screen widgets.
    var lockWeather: Bool {
        didSet { defaults.set(lockWeather, forKey: Key.lockWeather) }
    }
    var lockHeadphones: Bool {
        didSet { defaults.set(lockHeadphones, forKey: Key.lockHeadphones) }
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

    let supportDirectory: URL
    var lyricsCacheDirectory: URL { supportDirectory.appending(path: "LyricsCache") }
    var customSoundsDirectory: URL { supportDirectory.appending(path: "Sounds") }
    private var tokenURL: URL { supportDirectory.appending(path: "developer-token") }

    init() {
        defaults.register(defaults: [
            Key.hover: true,
            Key.lockWidget: true,
            Key.lockSound: LockSoundStyle.iPhone.rawValue,
            Key.motion: true,
            Key.islandStyle: IslandStyle.black.rawValue,
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
            Key.lowBattery: true,
            Key.levelPosition: LevelPosition.island.rawValue,
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
        shelfKeepsCopies = defaults.bool(forKey: Key.shelfCopies)
        emulateNotch = defaults.bool(forKey: Key.emulateNotch)
        levelPosition = LevelPosition(rawValue: defaults.string(forKey: Key.levelPosition) ?? "") ?? .island
        clipboardHistory = defaults.bool(forKey: Key.clipboard)
        liveWaveform = defaults.bool(forKey: Key.waveform)
        equalizerEnabled = defaults.bool(forKey: Key.equalizer)
        let bands = (defaults.array(forKey: Key.eqBands) as? [Double]) ?? []
        equalizerBands = bands.count == Equalizer.frequencies.count
            ? bands.map { Self.clamped($0, Equalizer.gainRange) } : Equalizer.flat
        equalizerPreamp = Self.clamped(defaults.double(forKey: Key.eqPreamp), Equalizer.gainRange)
        equalizerPreset = defaults.string(forKey: Key.eqPreset).flatMap(EqualizerPreset.init(rawValue:))
        lockWeather = defaults.bool(forKey: Key.lockWeather)
        lockHeadphones = defaults.bool(forKey: Key.lockHeadphones)
        lockMotionBackground = defaults.bool(forKey: Key.lockMotion)
        tutorialVersion = defaults.string(forKey: "tutorialVersion")
        ClipboardHistory.shared.isEnabled = clipboardHistory
        // didSet doesn't run in init: publish the loaded values to the live views.
        let live = LiveTuning.shared
        live.glassTransparency = glassTransparency
        live.widthScale = islandWidthScale
        live.heightScale = islandHeightScale
        live.notchWidthAdjust = notchWidthAdjust
        live.notchHeightAdjust = notchHeightAdjust
        live.hapticsEnabled = hapticsEnabled
        live.forceClick = hapticsForceClick
        live.detentSpacing = detentSpacing
        live.lyricsOffset = lyricsOffset
        live.showIslandLyrics = showIslandLyrics
        live.saverMode = batterySaver
        live.refreshBatterySaving()

        let fm = FileManager.default
        try? fm.createDirectory(at: lyricsCacheDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: customSoundsDirectory, withIntermediateDirectories: true)
        developerToken = (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
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
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        developerToken = cleaned
        if let cleaned {
            FileManager.default.createFile(atPath: tokenURL.path, contents: Data(cleaned.utf8),
                                           attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.removeItem(at: tokenURL)
        }
    }
}

/// The settings the drawing code reads directly (glass material, island geometry, haptics),
/// kept in one observable place so every window follows a slider the moment it moves.
@MainActor
@Observable
final class LiveTuning {
    static let shared = LiveTuning()
    var glassTransparency = 0.5
    var widthScale = 1.0
    var heightScale = 1.0
    var notchWidthAdjust = 0.0
    var notchHeightAdjust = 0.0
    var hapticsEnabled = true
    var forceClick = true
    var detentSpacing = 5.0
    var lyricsOffset = 0.0
    var showIslandLyrics = true
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
