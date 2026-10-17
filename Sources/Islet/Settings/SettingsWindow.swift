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
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(settings: AppSettings, sounds: LockSoundPlayer, islandChanged: @escaping () -> Void,
         previewIsland: @escaping (Bool) -> Void, showTutorial: @escaping () -> Void,
         sourceChanged: @escaping () -> Void, updater: SPUUpdater) {
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
            updater: updater,
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
    case island, activities, shelf, music, haptics, lockScreen, agents, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .island: "Island"
        case .activities: "Live Activities"
        case .shelf: "File Shelf"
        case .music: "Music & Lyrics"
        case .haptics: "Haptics"
        case .lockScreen: "Lock Screen"
        case .agents: "Coding Agents"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .island: "capsule.fill"
        case .activities: "waveform"
        case .shelf: "tray.full.fill"
        case .music: "music.note"
        case .haptics: "hand.tap.fill"
        case .lockScreen: "lock.fill"
        case .agents: "terminal.fill"
        case .general: "gearshape.fill"
        }
    }

    /// The icon tile's color, in the manner of System Settings.
    var tint: Color {
        switch self {
        case .island: .blue
        case .activities: .orange
        case .shelf: .teal
        case .music: .pink
        case .haptics: .purple
        case .lockScreen: .indigo
        case .agents: Color(white: 0.3)
        case .general: .gray
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
    let showTutorial: () -> Void

    @AppStorage("settingsPane") private var paneName = SettingsPane.island.rawValue
    @State var previewing = false
    @State var autoUpdate = true
    @State var claudeConnected = AgentSetup.claudeConnected
    @State var codexConnected = AgentSetup.codexConnected
    @State var agentError: String?
    @State var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State var token = ""
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
                        PaneIcon(pane: pane)
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
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                            removal: .opacity))
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: pane)
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 700, minHeight: 480)
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
            autoUpdate = updater.automaticallyChecksForUpdates
        }
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        Form {
            switch pane {
            case .island: islandPane
            case .activities: activitiesPane
            case .shelf: shelfPane
            case .music: musicPane
            case .haptics: hapticsPane
            case .lockScreen: lockPane
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
                    .animation(.snappy(duration: 0.2), value: readout)
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

/// A white symbol on a small colored rounded square, like the System Settings sidebar.
struct PaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(pane.tint.gradient))
    }
}
