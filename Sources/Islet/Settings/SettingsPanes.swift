import AppKit
import SwiftUI

/// The contents of each Settings page. Options that only matter when another one is on
/// appear beneath it (and slide away when it's turned off) instead of sitting there greyed out.
extension SettingsView {
    private var reveal: Animation { .spring(response: 0.34, dampingFraction: 0.86) }

    // MARK: - Island

    @ViewBuilder
    var islandPane: some View {
        Section {
            IslandPreview(style: settings.islandStyle,
                          tuningKey: [settings.islandWidthScale, settings.islandHeightScale, settings.glassTransparency,
                                      settings.notchWidthAdjust, settings.notchHeightAdjust, settings.emulateNotch ? 1 : 0])
                .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            Picker("Style", selection: $settings.islandStyle.animation(reveal)) {
                ForEach(IslandStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.islandStyle.isGlass {
                sliderRow("Transparency", value: $settings.glassTransparency, in: 0...1,
                          low: "Frosted", high: "Clear", readout: transparencyLabel)
            }
        } footer: {
            if settings.islandStyle.isGlass, IsletGlass.isLiquid {
                Text("The middle of the transparency slider is Apple's standard Liquid Glass.")
            }
        }
        .animation(reveal, value: settings.islandStyle.isGlass)

        Section("Size") {
            sliderRow("Width", value: $settings.islandWidthScale, in: AppSettings.sizeRange,
                      low: "Narrow", high: "Wide", readout: percent(settings.islandWidthScale))
            if !hasNotch {
                sliderRow("Height", value: $settings.islandHeightScale, in: AppSettings.sizeRange,
                          low: "Slim", high: "Tall", readout: percent(settings.islandHeightScale))
            }
            Toggle("Keep the island open while adjusting", isOn: $previewing)
        }

        if !hasHardwareNotch {
            Section {
                Toggle("Emulate a notch", isOn: $settings.emulateNotch.animation(reveal))
            } header: {
                Text("Notch")
            } footer: {
                Text("Shapes the island like a MacBook notch: it sits flush in the menu bar, shows its content either side, and opens below. Notch Fit sizes it.")
            }
        }

        if hasNotch {
            Section {
                sliderRow("Notch width", value: $settings.notchWidthAdjust, in: AppSettings.notchRange,
                          low: "−20", high: "+20", readout: points(settings.notchWidthAdjust))
                sliderRow("Notch height", value: $settings.notchHeightAdjust, in: AppSettings.notchRange,
                          low: "−20", high: "+20", readout: points(settings.notchHeightAdjust))
            } header: {
                Text("Notch Fit")
            } footer: {
                Text(hasHardwareNotch
                     ? "Islet measures the notch itself. Nudge these only if the island doesn't line up with the camera housing."
                     : "The emulated notch's size.")
            }
        }

        Section("Behavior") {
            Toggle("Open when the pointer rests on it", isOn: $settings.expandOnHover)
        }
    }

    // MARK: - Live activities

    @ViewBuilder
    var activitiesPane: some View {
        Section {
            Toggle("Volume changes", isOn: $settings.showVolumeInIsland)
            Toggle("Brightness changes", isOn: $settings.showBrightnessInIsland)
            Toggle("Replace the macOS volume and brightness indicator",
                   isOn: $settings.replaceSystemIndicator.animation(reveal))
                .onChange(of: settings.replaceSystemIndicator) { _, on in MediaKeys.shared.setEnabled(on) }
            Picker("Position", selection: $settings.levelPosition) {
                ForEach(LevelPosition.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Show in the Island")
        } footer: {
            if settings.replaceSystemIndicator {
                Text("Needs Accessibility access: System Settings → Privacy & Security → Accessibility.")
            }
        }

        Section {
            Toggle("Headphones when they connect", isOn: $settings.showHeadphonesInIsland.animation(reveal))
            if settings.showHeadphonesInIsland {
                LabeledContent("3D models") {
                    Button("Open Models Folder") {
                        let folder = Headphone3DView.folder
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    }
                }
            }
        } footer: {
            if settings.showHeadphonesInIsland {
                Text("To show a 3D model, add a .usdz file named after the headphones, like airpods-max.usdz or sony-ult-wear.usdz.")
            }
        }

        Section {
            Toggle("Dot while the microphone or camera is in use", isOn: $settings.showPrivacyDots)
            Toggle("Warn at 20% and 10% battery", isOn: $settings.showLowBattery)
        }
    }

    // MARK: - Shelf

    @ViewBuilder
    var shelfPane: some View {
        Section {
            Toggle("Keep files dragged to the island", isOn: $settings.shelfEnabled.animation(reveal))
            if settings.shelfEnabled {
                Toggle("Store copies", isOn: $settings.shelfKeepsCopies)
                Toggle("Clipboard history", isOn: $settings.clipboardHistory)
            }
        } footer: {
            Text(settings.shelfEnabled && settings.shelfKeepsCopies
                 ? "The shelf keeps its own copies, so you can move or delete the originals. Removing a file from the shelf deletes only its copy."
                 : "Drag files onto the island to set them aside, then drag them out wherever you need them, or AirDrop them.")
                .contentTransition(.opacity)
        }
    }

    // MARK: - Music

    @ViewBuilder
    var musicPane: some View {
        Section {
            Picker("Follow", selection: $settings.playerSource) {
                ForEach(PlayerSource.allCases) { Text($0.title).tag($0) }
            }
        } footer: {
            Text("\"Whatever Is Playing\" follows any app. Choosing Apple Music or Spotify follows only that app.")
        }

        Section("Lyrics") {
            Toggle("Current line in the open island", isOn: $settings.showIslandLyrics)
            sliderRow("Timing", value: $settings.lyricsOffset, in: AppSettings.lyricsOffsetRange,
                      low: "Later", high: "Earlier", readout: seconds(settings.lyricsOffset))
            if settings.lyricsOffset != 0 {
                Button("Reset Timing") { withAnimation(reveal) { settings.lyricsOffset = 0 } }
                    .transition(.opacity)
            }
        }
        .animation(reveal, value: settings.lyricsOffset == 0)

        Section {
            Toggle("Equalizer", isOn: $settings.equalizerEnabled.animation(reveal))
            if settings.equalizerEnabled {
                EqualizerEditor(settings: settings)
                    .padding(.vertical, 4)
            }
            Toggle("Live waveform", isOn: $settings.liveWaveform)
            if settings.equalizerEnabled || settings.liveWaveform {
                AudioAccessRow()
            }
        } header: {
            Text("Sound")
        } footer: {
            Text(settings.equalizerEnabled
                 ? "The equalizer shapes Apple Music and Spotify. The live waveform makes the island's bars follow the music. Both need Audio Recording access the first time; nothing is recorded or saved."
                 : "The live waveform makes the island's bars follow the music. It needs Audio Recording access the first time; nothing is recorded or saved.")
        }

        Section {
            Toggle("Motion artwork when available", isOn: $settings.animatedArtworkEnabled.animation(reveal))
            if settings.animatedArtworkEnabled {
                SecureField("Developer token", text: $token, prompt: Text("Paste your token"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Label(settings.developerToken == nil ? "No token saved" : "Token saved",
                          systemImage: settings.developerToken == nil ? "key" : "checkmark.seal.fill")
                        .foregroundStyle(settings.developerToken == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    if settings.developerToken != nil {
                        Button("Remove") {
                            settings.setDeveloperToken(nil)
                            token = ""
                        }
                    }
                    Button("Save") { settings.setDeveloperToken(token) }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || token == settings.developerToken)
                }
            }
        } header: {
            Text("Animated Artwork")
        } footer: {
            if settings.animatedArtworkEnabled {
                Text("Uses the official Apple Music API, which needs a token from a paid Apple Developer account. It stays on this Mac.")
            }
        }
    }

    // MARK: - Haptics

    @ViewBuilder
    var hapticsPane: some View {
        if TrackpadMotor.isSupported {
            Section {
                Toggle("Trackpad haptics", isOn: $settings.hapticsEnabled.animation(reveal))
                if settings.hapticsEnabled {
                    Toggle("Force-click strength", isOn: $settings.hapticsForceClick)
                    sliderRow("Detent spacing", value: $settings.detentSpacing, in: AppSettings.detentRange,
                              low: "Fine", high: "Coarse", readout: points(settings.detentSpacing, signed: false))
                }
            } footer: {
                Text("Force-click strength drives the trackpad motor directly; otherwise Islet uses the system's gentler haptic.")
            }
            if settings.hapticsEnabled {
                Section("Try It") {
                    GlassSlider(value: tryValue, restHeight: 6, thumb: .always,
                                onChange: { tryValue = $0 }, onCommit: { tryValue = $0 })
                        .frame(height: 24)
                        .padding(.horizontal, 4)
                }
            }
        } else {
            Section {
                ContentUnavailableView("No Force Touch Trackpad", systemImage: "hand.tap",
                                       description: Text("Haptics need a Force Touch trackpad. Connect one and restart Islet."))
            }
        }
    }

    // MARK: - Lock screen

    @ViewBuilder
    var lockPane: some View {
        Section {
            Toggle("Show the island and player on the lock screen", isOn: $settings.lockWidgetEnabled.animation(reveal))
            if settings.lockWidgetEnabled {
                Toggle("Weather", isOn: $settings.lockWeather)
                    .onChange(of: settings.lockWeather) { _, on in if on { WeatherService.shared.requestAccess() } }
                Toggle("Headphone battery", isOn: $settings.lockHeadphones)
                Toggle("Motion artwork behind the widgets", isOn: $settings.lockMotionBackground)
            }
        } footer: {
            if settings.lockWidgetEnabled {
                Text("Weather uses your location and Open-Meteo. Motion artwork needs the Apple Music token in Music & Lyrics.")
            }
        }
        Section("Sounds") {
            Picker("Lock and unlock", selection: $settings.lockSoundStyle.animation(reveal)) {
                ForEach(LockSoundStyle.allCases) { Text($0.title).tag($0) }
            }
            if settings.lockSoundStyle != .off {
                LabeledContent("Preview") {
                    HStack {
                        Button("Lock", systemImage: "lock.fill") { sounds.play(.lock) }
                        Button("Unlock", systemImage: "lock.open.fill") { sounds.play(.unlock) }
                    }
                }
                LabeledContent("Your own sounds") {
                    Button("Open Folder") { NSWorkspace.shared.open(settings.customSoundsDirectory) }
                }
            }
        }
    }

    // MARK: - Coding agents

    @ViewBuilder
    var agentsPane: some View {
        Section {
            Toggle("Show alerts from coding agents", isOn: $settings.showAgentAlerts)
        } footer: {
            Text("The island tells you when an agent needs permission, is waiting for you, or has finished. Click the alert to jump to its terminal.")
        }
        Section {
            agentRow("Claude Code", connected: claudeConnected) {
                try claudeConnected ? AgentSetup.disconnectClaude() : AgentSetup.connectClaude()
                claudeConnected = AgentSetup.claudeConnected
            }
            agentRow("Codex", connected: codexConnected) {
                try codexConnected ? AgentSetup.disconnectCodex() : AgentSetup.connectCodex()
                codexConnected = AgentSetup.codexConnected
            }
            if let agentError {
                Text(agentError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("Connecting adds Islet to the agent's own settings and keeps a backup of the original; disconnecting removes it.")
        }
    }

    private func agentRow(_ name: String, connected: Bool, toggle: @escaping () throws -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(connected ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button(connected ? "Disconnect" : "Connect") {
                do {
                    try withAnimation(reveal) { try toggle() }
                    agentError = nil
                } catch {
                    agentError = "Couldn't update \(name)'s settings: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - General

    @ViewBuilder
    var generalPane: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Islet").font(.title3.weight(.semibold))
                    Text("Version \(Self.version)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check for Updates") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            .padding(.vertical, 4)
            Toggle("Check for updates automatically", isOn: $autoUpdate)
                .onChange(of: autoUpdate) { _, on in updater.automaticallyChecksForUpdates = on }
        } footer: {
            Text("Every update is signed, so only genuine Islet releases are installed.")
        }

        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            Picker("Battery Saver", selection: $settings.batterySaver) {
                ForEach(BatterySaver.allCases) { Text($0.title).tag($0) }
            }
        } footer: {
            Text("Battery Saver slows the island's animations and turns off motion artwork.")
        }

        Section {
            LabeledContent("Tutorial") {
                Button("Show Again") { showTutorial() }
            }
            LabeledContent("Island and haptics") {
                Button("Reset to Defaults") {
                    withAnimation(reveal) { settings.resetAppearance() }
                    islandChanged()
                }
            }
        }
    }
}
