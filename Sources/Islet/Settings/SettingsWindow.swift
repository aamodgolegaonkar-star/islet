import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

/// The Settings window: every preference in one place, applied live to the island.
@MainActor
final class SettingsController {
    private let settings: AppSettings
    private let sounds: LockSoundPlayer
    private let islandChanged: () -> Void
    private let previewIsland: (Bool) -> Void
    private let showTutorial: () -> Void
    private let sourceChanged: () -> Void
    private let updater: SPUUpdater
    private let portal: PortalController
    private let faceID: FaceIDController
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(settings: AppSettings, sounds: LockSoundPlayer, islandChanged: @escaping () -> Void,
         previewIsland: @escaping (Bool) -> Void, showTutorial: @escaping () -> Void,
         sourceChanged: @escaping () -> Void, updater: SPUUpdater, portal: PortalController, faceID: FaceIDController) {
        self.portal = portal
        self.faceID = faceID
        self.sourceChanged = sourceChanged
        self.updater = updater
        self.settings = settings
        self.sounds = sounds
        self.islandChanged = islandChanged
        self.previewIsland = previewIsland
        self.showTutorial = showTutorial
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// A closed window keeps nothing alive: its views (and their animations) are dropped.
    private func closed() {
        previewIsland(false)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window?.contentView = nil
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(
            settings: settings, sounds: sounds,
            islandChanged: islandChanged, previewIsland: previewIsland, sourceChanged: sourceChanged,
            updater: updater, portal: portal, faceID: faceID,
            showTutorial: { [weak self] in
                self?.window?.close()
                self?.showTutorial()
            })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Islet Settings"
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentMinSize = CGSize(width: 700, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        return window
    }
}

/// The sections of the Settings window, listed in its sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case island, appearance, activities, shelf, portal, music, haptics, lockScreen, standby, faceID, agents, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .island: "Island"
        case .appearance: "Appearance"
        case .standby: "Standby"
        case .activities: "Live Activities"
        case .shelf: "File Shelf"
        case .portal: "Portal"
        case .music: "Music & Lyrics"
        case .haptics: "Haptics"
        case .lockScreen: "Lock Screen"
        case .faceID: "Face ID"
        case .agents: "Coding Agents"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .island: "capsule.fill"
        case .appearance: "paintpalette.fill"
        case .standby: "clock.fill"
        case .activities: "waveform"
        case .shelf: "tray.full.fill"
        case .portal: "iphone.radiowaves.left.and.right"
        case .music: "music.note"
        case .haptics: "hand.tap.fill"
        case .lockScreen: "lock.fill"
        case .faceID: "faceid"
        case .agents: "terminal.fill"
        case .general: "gearshape.fill"
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let sounds: LockSoundPlayer
    let islandChanged: () -> Void
    let previewIsland: (Bool) -> Void
    let sourceChanged: () -> Void
    let updater: SPUUpdater
    let portal: PortalController
    let faceID: FaceIDController
    let showTutorial: () -> Void

    @AppStorage("settingsPane") private var paneName = SettingsPane.island.rawValue
    @State var previewing = false
    @State var autoUpdate = true
    @State var claudeConnected = AgentSetup.claudeConnected
    @State var codexConnected = AgentSetup.codexConnected
    @State var agentError: String?
    @State var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State var token = ""
    @State var userToken = ""
    @State var tryValue = 0.4

    private var pane: SettingsPane { SettingsPane(rawValue: paneName) ?? .island }

    /// A real notch, or an emulated one (follows the setting live).
    var hasNotch: Bool {
        _ = settings.emulateNotch
        return IslandMetrics.make(for: NSScreen.screens.first, style: settings.islandStyle).hasNotch
    }
    var hasHardwareNotch: Bool { IslandMetrics.hardwareNotch(of: NSScreen.screens.first) != nil }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { pane }, set: { if let next = $0 { paneName = next.rawValue } })) {
                ForEach(SettingsPane.allCases) { pane in
                    Label {
                        Text(pane.title)
                    } icon: {
                        PaneIcon(pane: pane, selected: pane == self.pane, theme: settings.accentTheme)
                    }
                    .tag(pane)
                }
            }
            .frame(minWidth: 215)
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack {
                detail(for: pane)
                    .id(pane)
                    .transition(.paneSwap)
            }
            .animation(IslandMotion.panel, value: pane)
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 700, minHeight: 480)
        .tint(settings.accentTheme.tint)
        .animation(IslandMotion.panel, value: settings.accentTheme)
        .onChange(of: settings.islandStyle) { islandChanged() }
        .onChange(of: settings.islandWidthScale) { islandChanged() }
        .onChange(of: settings.islandHeightScale) { islandChanged() }
        .onChange(of: settings.notchWidthAdjust) { islandChanged() }
        .onChange(of: settings.notchHeightAdjust) { islandChanged() }
        .onChange(of: settings.emulateNotch) { islandChanged() }
        .onChange(of: previewing) { _, on in previewIsland(on) }
        .onChange(of: settings.playerSource) { sourceChanged() }
        .onAppear {
            token = settings.developerToken ?? ""
            userToken = settings.musicUserToken ?? ""
            autoUpdate = updater.automaticallyChecksForUpdates
        }
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        Form {
            switch pane {
            case .island: islandPane
            case .appearance: appearancePane
            case .standby: standbyPane
            case .activities: activitiesPane
            case .shelf: shelfPane
            case .portal: portalPane
            case .music: musicPane
            case .haptics: hapticsPane
            case .lockScreen: lockPane
            case .faceID: FaceIDPane(settings: settings, faceID: faceID)
            case .agents: agentsPane
            case .general: generalPane
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Helpers shared by the panes

    /// A slider row: the name with its current value beneath, the slider on the right.
    func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                   low: String, high: String, readout: String) -> some View {
        LabeledContent {
            Slider(value: value, in: range) {
                EmptyView()
            } minimumValueLabel: {
                Text(low).font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 280)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(IslandMotion.quick, value: readout)
            }
        }
    }

    var transparencyLabel: String {
        let value = settings.glassTransparency
        if abs(value - 0.5) < 0.02 { return "Apple standard" }
        return value < 0.5 ? "Smokier" : "Clearer"
    }

    func seconds(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        if tenths == 0 { return "In time" }
        return String(format: "%.1f s %@", abs(tenths), tenths > 0 ? "earlier" : "later")
    }

    func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) %"
    }

    func points(_ value: Double, signed: Bool = true) -> String {
        let rounded = Int(value.rounded())
        return signed && rounded > 0 ? "+\(rounded) pt" : "\(rounded) pt"
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            NSSound.beep()
            launchAtLogin = service.status == .enabled
        }
    }
}

/// A small rounded tile in the sidebar: a quiet grey glyph, and for the open page a tile
/// filled with the theme's gradient that pops in with a little bounce.
struct PaneIcon: View {
    let pane: SettingsPane
    let selected: Bool
    let theme: AccentTheme

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .symbolEffect(.bounce, value: selected)
            .frame(width: 20, height: 20)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.gradient)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.6)
            }
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
            }
            .animation(IslandMotion.playful, value: selected)
            .animation(IslandMotion.panel, value: theme)
    }
}

/// The Appearance page's header: the theme's colors drifting slowly behind its name.
struct ThemeHero: View {
    let theme: AccentTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(theme.colors.enumerated()), id: \.offset) { index, color in
                    let phase = t * 0.35 + Double(index) * 2.1
                    Circle()
                        .fill(color)
                        .frame(width: 150, height: 150)
                        .offset(x: cos(phase) * 90, y: sin(phase * 1.3) * 22)
                        .blur(radius: 40)
                }
                VStack(spacing: 2) {
                    Text(theme.title)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .contentTransition(.interpolate)
                    Text("Islet's colors")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .animation(IslandMotion.panel, value: theme)
    }
}

extension AnyTransition {
    /// A Settings page arriving comes into focus from a little below; the old one simply
    /// fades, quicker, so the two never fight for attention.
    static var paneSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PaneFocus(amount: 1), identity: PaneFocus(amount: 0)),
            removal: .opacity.animation(IslandMotion.exit))
    }
}

private struct PaneFocus: ViewModifier {
    let amount: Double
    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .offset(y: IslandMotion.reduced ? 0 : amount * 10)
            .blur(radius: IslandMotion.reduced ? 0 : amount * 4)
    }
}
