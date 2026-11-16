import AppKit
import IsletCore
import SwiftUI

/// The contents of each Settings page. Options that only matter when another one is on
/// appear beneath it (and slide away when it's turned off) instead of sitting there greyed out.
extension SettingsView {
    private var reveal: Animation { IslandMotion.subtle }

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
            if settings.islandStyle.isGlass {
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

        Section {
            Toggle("Open when the pointer rests on it", isOn: $settings.expandOnHover)
            Toggle("Swipe left or right to skip songs", isOn: $settings.swipeToSkip)
            Toggle("Show a small clock when nothing is playing", isOn: $settings.islandClock)
            Picker("Hide a paused song", selection: $settings.hidePausedPlayer) {
                ForEach(PausedPlayerHide.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Hide from screenshots and screen sharing", isOn: $settings.hideFromScreenCapture)
        } header: {
            Text("Behavior")
        } footer: {
            Text("Swipe with two fingers over the island: left for the next song, right for the previous one. A hidden song comes back as soon as music plays.")
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

        Section("Charging") {
            Toggle("Show when a charger is connected", isOn: $settings.showChargingAlert.animation(reveal))
            if settings.showChargingAlert {
                Picker("Battery", selection: $settings.batteryIconStyle) {
                    ForEach(BatteryIconStyle.allCases) { Text($0.title).tag($0) }
                }
                sliderRow("Stays for", value: $settings.chargingAlertDuration, in: 1.5...10,
                          low: "Brief", high: "Long",
                          readout: String(format: "%.1f s", settings.chargingAlertDuration))
            }
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

    // MARK: - Portal

    @ViewBuilder
    var portalPane: some View {
        Section {
            Toggle("Portal", isOn: $settings.portalEnabled.animation(reveal))
        } footer: {
            Text("Fling photos, videos, files, text and links between your phone (iPhone or Android) and this Mac over your Wi-Fi. No app to install: your phone uses a page this Mac serves. Off stops this Mac listening on the network.")
        }
        if settings.portalEnabled {
            Section {
                if let problem = portal.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let url = portal.pairingURL, let qr = PortalController.qrCode(for: url) {
                    HStack(alignment: .center, spacing: 18) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 170, height: 170)
                            .padding(10)
                            .background(.white, in: .rect(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(portal.pairingAndroid ? "Scan with your Android phone's camera" : "Scan with your iPhone's Camera").font(.headline)
                            Text(portal.pairingAndroid
                                 ? "Open the link in Chrome, tap Pair, then ⋮ → Add to Home screen. The code works once, for five minutes. Your phone needs to be on the same Wi-Fi."
                                 : "Open the link, tap Pair, then Share → Add to Home Screen. The code works once, for five minutes. Your iPhone needs to be on the same Wi-Fi.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Done") { portal.endPairing() }
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    LabeledContent("Pair a phone") {
                        HStack {
                            Button("iPhone") { portal.beginPairing() }
                            Button("Android") { portal.beginPairing(android: true) }
                        }
                        .disabled(!portal.isRunning)
                    }
                }
                if portal.devices.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(portal.devices) { device in
                    LabeledContent {
                        Button("Forget") { portal.forget(device) }
                    } label: {
                        Label(device.name, systemImage: "smartphone")
                        Text("Paired \(device.added.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
            } header: {
                Text("Paired phones")
            }
            .onDisappear { portal.endPairing() }

            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(settings.portalSaveFolder.lastPathComponent).foregroundStyle(.secondary)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.directoryURL = settings.portalSaveFolder
                            if panel.runModal() == .OK, let url = panel.url { settings.portalSaveFolder = url }
                        }
                    }
                }
                Picker("After receiving", selection: $settings.portalAfterReceive) {
                    ForEach(PortalAfterReceive.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Open links in the browser", isOn: $settings.portalOpenLinks)
            } header: {
                Text("Receiving")
            } footer: {
                Text("Photos, videos and files are saved to this folder. Text always goes on the clipboard; with links off, links are only copied too.")
            }

            Section {
                Toggle("Drag to the screen's right edge to send", isOn: $settings.portalEdgeSend)
            } header: {
                Text("Sending")
            } footer: {
                Text("Drag files, links or text to the right edge of your screen, where your phone sits, and let go. The trackpad ticks faster as you near the edge. Your phone collects them when Portal is open.")
            }

            Section("Effect") {
                Picker("Style", selection: $settings.portalEffect) {
                    ForEach(PortalEffect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Match Appearance colors", isOn: Binding(
                    get: { settings.portalTheme == nil },
                    set: { settings.portalTheme = $0 ? nil : settings.accentTheme }).animation(reveal))
                if let theme = settings.portalTheme {
                    LabeledContent("Colors") {
                        ThemePicker(selection: Binding(get: { theme }, set: { settings.portalTheme = $0 }))
                    }
                }
                Toggle("Show the effect on this Mac", isOn: $settings.portalShowEffect)
                Toggle("Trackpad haptics", isOn: $settings.portalHaptics)
                LabeledContent("Preview") {
                    Button("Try It") { portal.demo() }
                }
            }
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    var appearancePane: some View {
        Section {
            ThemeHero(theme: settings.accentTheme)
                .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            LabeledContent("Colors") {
                ThemePicker(selection: $settings.accentTheme)
            }
        } footer: {
            Text("Used for switches and sliders, Portal, Standby and the sidebar. \(settings.accentTheme.title) is on.")
        }
    }

    // MARK: - Standby

    @ViewBuilder
    var standbyPane: some View {
        Section {
            Toggle("Standby", isOn: $settings.standbyEnabled.animation(reveal))
        } footer: {
            Text("While your Mac is charging and nobody's using it, the screen turns into a big clock with what's playing, the weather and the battery. Move the mouse or press any key to leave.")
        }
        if settings.standbyEnabled {
            Section {
                Picker("Start after", selection: $settings.standbyIdleMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) min idle").tag($0) }
                }
                Toggle("Keep the display on", isOn: $settings.standbyKeepAwake)
            } footer: {
                Text(settings.standbyKeepAwake ? "While Standby is up the display never sleeps, so your Mac won't lock itself. Turn this off if anyone else could reach it." : "The display sleeps on its usual schedule, which ends Standby, and your Mac locks as it normally would.")
            }
        }
        Section {
            LabeledContent("Preview") {
                Button("Start Standby") { StandbyController.shared?.start(manually: true) }
            }
        } footer: {
            Text("You can also start it any time from the menu bar.")
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

        Section {
            Picker("Style", selection: $settings.lyricStyle.animation(reveal)) {
                ForEach(LyricStyle.allCases) { Text($0.title).tag($0) }
            }
            if settings.lyricStyle != .classic {
                Toggle("Icons for words", isOn: $settings.lyricWordIcons)
            }
            Toggle("Current line in the open island", isOn: $settings.showIslandLyrics)
            sliderRow("Timing", value: $settings.lyricsOffset, in: AppSettings.lyricsOffsetRange,
                      low: "Later", high: "Earlier", readout: seconds(settings.lyricsOffset))
            if settings.lyricsOffset != 0 {
                Button("Reset Timing") { withAnimation(reveal) { settings.lyricsOffset = 0 } }
                    .transition(.opacity)
            }
        } header: {
            Text("Lyrics")
        } footer: {
            switch settings.lyricStyle {
            case .classic: Text("The whole line lights up as it's sung.")
            case .wordByWord: Text("Each word lights up as it's sung. Words are timed by Apple Music when you add your tokens below, and otherwise estimated from LRCLIB's line timing.")
            case .fisheye: Text("The word being sung swells, like a lens moving along the line. Words are timed by Apple Music when you add your tokens below, and otherwise estimated from LRCLIB's line timing.")
            }
        }
        .animation(reveal, value: settings.lyricsOffset == 0)

        Section {
            Toggle("Show lyrics on screen", isOn: $settings.screenLyrics.animation(reveal))
            if settings.screenLyrics {
                Picker("Where", selection: $settings.screenLyricsPlace) {
                    ForEach(ScreenLyricsPlace.allCases) { Text($0.title).tag($0) }
                }
                Picker("Style", selection: $settings.screenLyricsStyle) {
                    ForEach(ScreenLyricsStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Font", selection: $settings.screenLyricsFont) {
                    ForEach(ScreenLyricsFont.allCases) { Text($0.title).tag($0) }
                }
                sliderRow("Size", value: $settings.screenLyricsSize, in: AppSettings.screenLyricsSizeRange,
                          low: "Smaller", high: "Larger", readout: "\(Int((settings.screenLyricsSize * 100).rounded()))%")
                Toggle("Icons for words", isOn: $settings.lyricWordIcons)
                Toggle("Match album colors", isOn: $settings.screenLyricsAutoColors.animation(reveal))
                if !settings.screenLyricsAutoColors {
                    ColorPicker("Lyric text", selection: color(\.screenLyricsTextColor), supportsOpacity: false)
                    ColorPicker("Highlight", selection: color(\.screenLyricsHighlightColor), supportsOpacity: false)
                    ColorPicker("Highlighted text", selection: color(\.screenLyricsHighlightTextColor), supportsOpacity: false)
                    Button("Reset Colors") { settings.resetScreenLyricsColors() }
                }
                Toggle("Keep the screen on while they show", isOn: $settings.screenLyricsKeepAwake)
            }
        } header: {
            Text("On Screen")
        } footer: {
            Text(settings.screenLyricsStyle == .wall
                 ? "Big lyrics while music with synced lyrics plays: the last few lines on a wall that drifts in 3D, each word popping in as it's sung. The full-screen player's Fisheye stage uses the same style."
                 : "Big lyrics while music with synced lyrics plays, a word at a time through a glass lens: the word being sung appears in a highlight box, then rolls up and grows as the next one comes. The full-screen player's Fisheye stage uses the same style.")
        }

        Section {
            Toggle("Glow around the screen while music plays", isOn: $settings.edgeGlow.animation(reveal))
            if settings.edgeGlow {
                sliderRow("Strength", value: $settings.edgeGlowStrength, in: AppSettings.edgeGlowStrengthRange,
                          low: "Subtle", high: "Bright", readout: "\(Int((settings.edgeGlowStrength * 100).rounded()))%")
                sliderRow("Width", value: $settings.edgeGlowWidth, in: AppSettings.edgeGlowWidthRange,
                          low: "Thin", high: "Wide", readout: "\(Int((settings.edgeGlowWidth * 100).rounded()))%")
                Picker("Colors", selection: $settings.edgeGlowColors.animation(reveal)) {
                    ForEach(EdgeGlowColors.allCases) { Text($0.title).tag($0) }
                }
                if settings.edgeGlowColors != .album {
                    ColorPicker(settings.edgeGlowColors == .two ? "First color" : "Color",
                                selection: color(\.edgeGlowColor1), supportsOpacity: false)
                }
                if settings.edgeGlowColors == .two {
                    ColorPicker("Second color", selection: color(\.edgeGlowColor2), supportsOpacity: false)
                }
                Toggle("Pulse to the beat", isOn: $settings.edgeGlowBeat.animation(reveal))
                if settings.edgeGlowBeat {
                    AudioAccessRow()
                }
                if hasHardwareNotch {
                    Toggle("Wrap around the notch", isOn: $settings.edgeGlowNotch)
                }
                if NSScreen.screens.count > 1 {
                    Toggle("On every display", isOn: $settings.edgeGlowAllDisplays)
                }
            }
        } header: {
            Text("Edge Glow")
        } footer: {
            Text(settings.edgeGlowBeat
                 ? "A soft light around the edges of the screen that flares with the bass of the music. Following the beat needs Audio Recording access, like the live waveform; nothing is recorded or saved."
                 : "A soft light around the edges of the screen in the colors of the album cover. It breathes while the music plays and fades away when it stops.")
        }

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
            Toggle("Motion artwork when available", isOn: $settings.animatedArtworkEnabled)
        } header: {
            Text("Animated Artwork")
        } footer: {
            Text("Needs the developer token below.")
        }

        Section {
            tokenRow("Developer token", text: $token, saved: settings.developerToken,
                     save: settings.setDeveloperToken)
            tokenRow("Music User Token", text: $userToken, saved: settings.musicUserToken,
                     save: settings.setMusicUserToken)
        } header: {
            Text("Apple Music API")
        } footer: {
            Text("The developer token comes from a paid Apple Developer account and turns on motion artwork. Add your Music User Token too, and lyrics are timed word by word by Apple Music for the songs it has. Both stay on this Mac.")
        }
    }

    /// A color well bound to one of the settings' saved colors.
    private func color(_ keyPath: ReferenceWritableKeyPath<AppSettings, RGB>) -> Binding<Color> {
        Binding {
            Color(rgb: settings[keyPath: keyPath])
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            settings[keyPath: keyPath] = RGB(Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
        }
    }

    private func tokenRow(_ title: String, text: Binding<String>, saved: String?,
                          save: @escaping (String?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(title, text: text, prompt: Text("Paste your token"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Label(saved == nil ? "Not saved" : "Saved",
                      systemImage: saved == nil ? "key" : "checkmark.seal.fill")
                    .foregroundStyle(saved == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                    .contentTransition(.symbolEffect(.replace))
                Spacer()
                if saved != nil {
                    Button("Remove") {
                        save(nil)
                        text.wrappedValue = ""
                    }
                }
                Button("Save") { save(text.wrappedValue) }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || text.wrappedValue == saved)
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
                Toggle("Motion artwork behind the widgets", isOn: $settings.lockMotionBackground)
            }
        } footer: {
            if settings.lockWidgetEnabled {
                Text("Motion artwork needs the Apple Music token in Music & Lyrics.")
            }
        }
        if settings.lockWidgetEnabled {
            Section {
                LockWidgetsEditor(settings: settings)
            } header: {
                Text("Widgets")
            } footer: {
                Text("Widgets with nothing to show, like headphones that aren't connected, step aside until they do. Weather uses your location and Open-Meteo.")
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
