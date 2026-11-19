import AppKit
import SwiftUI

/// The first-launch tutorial: a few pages that zoom in and out of each other, each with a
/// live demo (hover the island, drag a slider and feel it click, watch the lock sequence).
@MainActor
final class OnboardingController {
    private let settings: AppSettings
    private let openSettings: () -> Void
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(settings: AppSettings, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.openSettings = openSettings
    }

    /// The whole tutorial: every feature.
    func show() {
        present(pages: Page.full, whatsNew: nil)
    }

    /// Only what's new since `version` (the last release whose tutorial was seen).
    func showWhatsNew(since version: String) {
        let pages = Page.added(after: version)
        guard !pages.isEmpty else { return }
        present(pages: [.whatsNew] + pages + [.done], whatsNew: Self.currentVersion)
    }

    /// From the menu: the latest release's features, whenever asked.
    func showLatest() {
        let releases = Set(Page.allCases.compactMap(\.since))
        guard let latest = releases.max(by: { Page.isVersion($1, newerThan: $0) }) else { return show() }
        let pages = Page.allCases.filter { $0.since == latest }
        present(pages: [.whatsNew] + pages + [.done], whatsNew: latest)
    }

    /// After an update: the new features' pages, once per release.
    func showWhatsNewIfUpdated() {
        let current = Self.currentVersion
        // Before this was tracked, everyone who had finished the tutorial was on 1.5.4 or 1.6.0.
        let seen = settings.tutorialVersion ?? (settings.onboardingDone ? "1.5.4" : current)
        settings.tutorialVersion = current
        guard Page.isVersion(current, newerThan: seen) else { return }
        showWhatsNew(since: seen)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func present(pages: [Page], whatsNew: String?) {
        if let window { window.close() }
        let window = makeWindow(pages: pages, whatsNew: whatsNew)
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Seen; and a closed tutorial keeps nothing alive (its demos animate constantly).
    private func closed() {
        settings.onboardingDone = true
        settings.tutorialVersion = Self.currentVersion
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window?.contentView = nil
        window = nil
    }

    private func makeWindow(pages: [Page], whatsNew: String?) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("onboarding")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(
            pages: pages, whatsNew: whatsNew,
            finish: { [weak window] in window?.close() },
            openSettings: { [weak self, weak window] in
                window?.close()
                self?.openSettings()
            }))
        window.center()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        return window
    }
}

/// One page of the tutorial: a feature, its live demo, and the release it arrived in.
/// When a release adds a feature, it gets a page here with `since` set to that version:
/// the full tutorial shows every page, and after updating, "What's New" shows the new ones.
enum Page: Int, CaseIterable {
    case welcome, whatsNew
    case island, swipeSkip, scrollingTitles, islandWeather, outOfTheWay, motion, colors, corners, feel, player, wordLyrics, screenLyrics, wallLyrics, edgeGlow, glowBeat, activities, focus, levels, controls, sound, perAppEQ, shelf, portal, portalIncoming, androidPhone, androidRemote, phoneMirroring, androidDot, webPlayers, lock, lockWidgets, lockCustomize, lockPlayer, aurora, standby, faceID, agents
    case done

    /// The full tutorial, in order.
    static var full: [Page] { allCases.filter { $0 != .whatsNew } }

    /// Feature pages added in releases after `version`.
    static func added(after version: String) -> [Page] {
        allCases.filter { page in page.since.map { isVersion($0, newerThan: version) } ?? false }
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// The release that introduced the feature (nil: not a feature page).
    var since: String? {
        switch self {
        case .welcome, .whatsNew, .done: nil
        case .island, .feel, .player, .lock, .agents, .activities: "1.0"
        case .controls, .sound, .levels, .webPlayers, .lockWidgets: "1.6.0"
        case .shelf: "1.6.0"
        case .lockCustomize: "1.7.0"
        case .wordLyrics, .screenLyrics, .edgeGlow: "1.8.0"
        case .wallLyrics, .glowBeat: "1.9.0"
        case .swipeSkip, .outOfTheWay, .portal, .faceID, .motion, .colors, .standby: "2.0"
        case .focus, .scrollingTitles, .islandWeather, .corners, .perAppEQ, .portalIncoming, .lockPlayer, .aurora, .androidPhone, .androidRemote: "2.1"
        case .androidDot, .phoneMirroring: "2.2"
        }
    }

    var title: String {
        switch self {
        case .welcome: "Welcome to Islet"
        case .whatsNew: "What's New in Islet"
        case .island: "Your music lives in the island"
        case .swipeSkip: "Swipe to skip"
        case .scrollingTitles: "Long titles, in full"
        case .islandWeather: "The weather, a click away"
        case .corners: "Rounded corners everywhere"
        case .perAppEQ: "An equalizer for each app"
        case .portalIncoming: "Watch it come through"
        case .androidPhone: "Your Android phone, in the island"
        case .androidRemote: "Your phone runs your Mac"
        case .androidDot: "A Dynamic Dot on your phone"
        case .phoneMirroring: "Your phone, in a window"
        case .lockPlayer: "Your lock-screen player"
        case .aurora: "An aurora from your album"
        case .outOfTheWay: "Out of the way when you want"
        case .motion: "Smoother, everywhere"
        case .colors: "Your colors"
        case .feel: "Controls you can feel"
        case .player: "A full-screen player"
        case .wordLyrics: "Lyrics, word by word"
        case .screenLyrics: "Lyrics on your screen"
        case .edgeGlow: "Your screen glows with the music"
        case .wallLyrics: "A wall of lyrics"
        case .glowBeat: "Glow to the beat"
        case .activities: "Live activities"
        case .focus: "Focus, in the island"
        case .levels: "Volume and brightness, your way"
        case .controls: "Pick where sound plays"
        case .sound: "Equalizer and live waveform"
        case .shelf: "A shelf for files and copies"
        case .portal: "Portal to your iPhone"
        case .webPlayers: "Web players, by name"
        case .lock: "Made for the lock screen"
        case .lockWidgets: "Lock-screen widgets"
        case .lockCustomize: "Make the lock screen yours"
        case .standby: "Standby"
        case .faceID: "Face ID for your Mac"
        case .agents: "Your coding agents, in the island"
        case .done: "You're all set"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "A Dynamic Island for your Mac, in real Liquid Glass."
        case .whatsNew: "Here's what this update adds. It only takes a moment."
        case .island: "Hover over the island at the top of your screen to open it. Try this one."
        case .swipeSkip: "Swipe two fingers over the island: left for the next song, right for the previous one."
        case .scrollingTitles: "When a song's name is too long to fit, it glides past so you can read all of it, then rests. Point at it to see it again."
        case .islandWeather: "Click the weather button under the open island and the card flips to the weather where you are, with the next six hours. Turn it off in Settings → Island."
        case .corners: "Round off the square bottom corners of your MacBook screen, or all four on another display, to match the curved top. Settings → Appearance."
        case .perAppEQ: "Give Apple Music and Spotify each their own equalizer curve: turn on Separate for Apple Music and Spotify in Music & Lyrics → Sound."
        case .androidPhone: "Install Islet on your Android phone and pair it in Settings → Android Phone. Its notifications and calls appear in the island, with Reply, Answer and Decline, and its Live Activities (a ride, a delivery, directions, a stopwatch) stay in the island while they last. The round button beside the open island shows the phone's battery and opens the phone page."
        case .androidRemote: "Your Mac's music plays on the phone's lock screen with its controls. The app is a trackpad, keyboard and slide clicker for the Mac, and sends files at full quality over USB, Wi-Fi or Bluetooth."
        case .phoneMirroring: "Choose Mirror on the phone page, or click a phone notification, and your Android phone opens in a window with its sound: tap, swipe and type. ⌘1 Home, ⌘2 App Switcher, ⌘3 Search; drop files on it to send them. Pair it once in Settings for encrypted Wi-Fi, and save its PIN to unlock it with Touch ID. Using the phone ends mirroring and locks it."
        case .androidDot: "The Islet app can turn your phone's front camera into an island too. Music shows its art and level bars, and calls, notifications and charging grow out of the camera. Tap it for controls, swipe up to close. Turn it on in the app's Settings → Dynamic Dot."
        case .portalIncoming: "When your iPhone sends something big, the portal opens on the right edge of your screen and widens as it comes in, then closes as it lands."
        case .lockPlayer: "Move the lock-screen player higher or lower, pick which display it's on, and keep the display awake while music plays. Settings → Lock Screen → Player."
        case .aurora: "Songs without motion artwork fill the lock screen with their cover, turned, mirrored and flowing like an aurora, and it crossfades to the next song's."
        case .outOfTheWay: "Islet can hide a paused song from the island, right away or after a while, and stay out of screenshots and screen sharing. Both are in Settings → Island."
        case .motion: "Every animation in Islet was retuned to feel like one object. Swipe between desktops and the island rides along with the old one, then drops onto the new one. Reduce Motion in System Settings calms it all down."
        case .colors: "Pick a color theme in Settings → Appearance. It tints switches and sliders, Portal, Standby and the sidebar. Portal can have its own colors too. Click a color here."
        case .feel: "Sliders click through detents like a dial on your trackpad. Drag this one."
        case .player: "Click the artwork in the island for the full-screen player, with synced lyrics. In Fisheye, click the cover and it tucks into the corner while the lyrics take the stage; click it again to bring it back."
        case .wordLyrics: "Each word lights up as it's sung. Fisheye swells the word being sung, and icons can rise over words like \"fire\" or \"night\". Pick a style in Music & Lyrics → Lyrics."
        case .screenLyrics: "Lock your Mac while music plays: the album cover fills the lock screen and big lyrics roll past a word at a time, in its colors. Click the arrow in the top-left corner to hide them until the next lock. Change it in Music & Lyrics → On Screen."
        case .edgeGlow: "While a song plays, a soft light runs around the edges of your screen in the colors of its cover. Make it wider, pick your own colors, or wrap it around the notch in Music & Lyrics → Edge Glow."
        case .wallLyrics: "A second look for the big lyrics: the last few lines on a wall drifting in 3D, each word popping in as it's sung. Pick Wall in Music & Lyrics → On Screen."
        case .glowBeat: "Turn on Pulse to the beat and the edge glow flares with the bass of whatever's playing."
        case .activities: "Charging, headphones connecting, timers and low battery pop up in the island, and a dot shows when the mic or camera is on. Pick how the charging battery looks and how long it stays in Live Activities → Charging."
        case .focus: "Turn on a Focus and the island shows its icon and name; on the lock screen, add the Focus widget. Choose which alerts stay quiet while a Focus is on in Live Activities → Focus."
        case .levels: "Islet replaces the macOS volume and brightness indicator. Show it in the island or as a slider on either edge of the screen (Live Activities → Position)."
        case .controls: "Click the speaker button in the open island to switch between speakers, AirPods, HomePod or paired headphones, and set AirPods noise control."
        case .sound: "Shape Apple Music and Spotify with a 10-band equalizer, and let the island's bars follow the real music. Turn them on in Music & Lyrics → Sound, then allow Islet once in Privacy & Security."
        case .shelf: "Drag files onto the island to keep them handy. The Clipboard tab keeps what you copied; click a card to copy it again."
        case .portal: "Fling photos, videos, files and links between your iPhone and Mac through a portal, with no app to install. Turn it on in Settings → Portal, scan the code, and drag things to the right edge of your screen to send them back."
        case .webPlayers: "Playing in a browser? Islet names the service: YouTube Music, Deezer, Qobuz, Tidal, SoundCloud and more."
        case .lock: "Your music stays on the lock screen. A wrong finger shakes the padlock; the right one opens it."
        case .lockWidgets: "Small widgets sit under the clock: battery, what's playing, volume, your headphones and more, with motion artwork behind them."
        case .lockCustomize: "Drag widgets in, out and around in Settings → Lock Screen. Besides the basics there are Date, World Clock, CPU and Focus. Click a tile here to take it away."
        case .standby: "Leave your Mac on its charger and walk away: after a few minutes the screen becomes a big clock with what's playing, the weather and the battery. Touch anything to come back. Settings → Standby, or Start Standby in the menu bar."
        case .faceID: "Look at your Mac to unlock it: Islet types your password for you. The island shows the Face ID mark when it's your face, and the fingerprint when it's Touch ID. Strict liveness adds a quick colour flash that photos and videos can't fake. Set it up in Settings → Face ID; it's for convenience, not security."
        case .agents: "Claude Code and Codex tell you in the island when they need you or finish. Click to jump to the terminal."
        case .done: "Everything can be tuned in Settings: island size, glass, colors, sound, haptics, Portal, your Android phone, Standby, Face ID and more."
        }
    }
}

struct OnboardingView: View {
    let pages: [Page]
    /// Set for "What's New": the version being introduced.
    let whatsNew: String?
    let finish: () -> Void
    let openSettings: () -> Void
    @State private var index = 0
    private var page: Page { pages[index] }
    @State private var forward = true
    @State private var drift = false

    /// Debug: `islet-debug.sh tutorial.next` steps through the pages.
    static let debugNext = Notification.Name("IsletTutorialNext")

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                ZStack {
                    PageView(page: page, version: whatsNew, newPages: pages.filter { $0.since != nil })
                        .id(page)
                        .transition(zoom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .padding(.horizontal, 32)
                    .padding(.bottom, 26)
            }
        }
        .frame(width: 760, height: 540)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { go(+1); return .handled }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onReceive(NotificationCenter.default.publisher(for: Self.debugNext)) { _ in go(+1) }
        .onAppear {
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    /// Pages zoom out of the screen toward you as the next one zooms up from depth
    /// (reversed when going back).
    private var zoom: AnyTransition {
        let near = AnyTransition.scale(scale: 1.5).combined(with: .opacity).combined(with: .blurred)
        let far = AnyTransition.scale(scale: 0.55).combined(with: .opacity).combined(with: .blurred)
        return forward ? .asymmetric(insertion: far, removal: near) : .asymmetric(insertion: near, removal: far)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.1, blue: 0.3), Color(red: 0.05, green: 0.06, blue: 0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(Color(red: 0.95, green: 0.35, blue: 0.55).opacity(0.35))
                .frame(width: 420)
                .blur(radius: 90)
                .offset(x: drift ? -180 : 120, y: drift ? -120 : 60)
            Circle()
                .fill(Color(red: 0.3, green: 0.55, blue: 1).opacity(0.3))
                .frame(width: 380)
                .blur(radius: 90)
                .offset(x: drift ? 200 : -100, y: drift ? 140 : -40)
        }
        .scaleEffect(drift ? 1.12 : 1)
        .ignoresSafeArea()
    }

    private var controls: some View {
        HStack {
            Button("Back") { go(-1) }
                .buttonStyle(.glass)
                .opacity(index == 0 ? 0 : 1)
                .disabled(index == 0)
            Spacer()
            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { item in
                    Capsule()
                        .fill(.white.opacity(item == index ? 0.95 : 0.3))
                        .frame(width: item == index ? 22 : 7, height: 7)
                        .onTapGesture { jump(to: item) }
                }
            }
            .animation(IslandMotion.subtle, value: page)
            Spacer()
            if index == pages.count - 1 {
                HStack(spacing: 10) {
                    Button("Open Settings") { openSettings() }
                        .buttonStyle(.glass)
                    Button(whatsNew == nil ? "Start Listening" : "Got It") { finish() }
                        .buttonStyle(.glassProminent)
                }
            } else {
                Button(index == 0 ? (whatsNew == nil ? "Get Started" : "Show Me") : "Continue") { go(+1) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func go(_ step: Int) {
        let next = index + step
        guard pages.indices.contains(next) else { return }
        jump(to: next)
    }

    private func jump(to next: Int) {
        guard next != index else { return }
        forward = next > index
        withAnimation(IslandMotion.panel) { index = next }
    }
}

private struct PageView: View {
    let page: Page
    var version: String?
    var newPages: [Page] = []
    @State private var shown = false

    var body: some View {
        VStack(spacing: 26) {
            hero
                .frame(height: 230)
                // The demo zooms in from far away a beat after the page arrives.
                .scaleEffect(shown ? 1 : 0.3)
                .blur(radius: shown ? 0 : 14)
                .opacity(shown ? 1 : 0)
            VStack(spacing: 10) {
                Text(page == .whatsNew ? "What's New in Islet \(version ?? "")" : page.title)
                    .font(.system(size: 30, weight: .bold))
                Text(page.subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .offset(y: shown ? 0 : 14)
            .opacity(shown ? 1 : 0)
        }
        .foregroundStyle(.white)
        .padding(.top, 40)
        .onAppear {
            withAnimation(IslandMotion.panel.delay(0.12)) { shown = true }
        }
    }

    @ViewBuilder
    private var hero: some View {
        switch page {
        case .welcome: WelcomeHero()
        case .whatsNew: WhatsNewHero(pages: newPages)
        case .island: IslandDemo()
        case .swipeSkip: SwipeSkipDemo()
        case .outOfTheWay: OutOfTheWayDemo()
        case .motion: MotionDemo()
        case .colors: ColorsDemo()
        case .feel: FeelDemo()
        case .player: PlayerDemo()
        case .wordLyrics: WordLyricsDemo()
        case .screenLyrics: ScreenLyricsDemo()
        case .edgeGlow: EdgeGlowDemo()
        case .wallLyrics: WallLyricsDemo()
        case .glowBeat: GlowBeatDemo()
        case .activities: ActivitiesDemo()
        case .scrollingTitles: ScrollingTitlesDemo()
        case .islandWeather: IslandWeatherDemo()
        case .corners: CornersDemo()
        case .perAppEQ: PerAppEQDemo()
        case .portalIncoming: PortalIncomingDemo()
        case .androidPhone: AndroidPhoneDemo()
        case .androidRemote: AndroidRemoteDemo()
        case .androidDot: AndroidDotDemo()
        case .phoneMirroring: PhoneMirroringDemo()
        case .lockPlayer: LockPlayerDemo()
        case .aurora: AuroraDemo()
        case .focus: FocusDemo()
        case .levels: LevelsDemo()
        case .controls: OutputDemo()
        case .sound: SoundDemo()
        case .shelf: ShelfDemo()
        case .portal: PortalDemo()
        case .webPlayers: WebPlayerDemo()
        case .lock: LockDemo()
        case .lockWidgets: LockWidgetsDemo()
        case .lockCustomize: LockCustomizeDemo()
        case .standby: StandbyDemo()
        case .faceID: FaceIDDemo()
        case .agents: AgentDemo()
        case .done: DoneHero()
        }
    }
}

private extension AnyTransition {
    static var blurred: AnyTransition {
        .modifier(active: BlurModifier(radius: 18), identity: BlurModifier(radius: 0))
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

// MARK: - Demos

/// A pill that breathes, like the island waking up.
private struct WelcomeHero: View {
    @State private var open = false

    var body: some View {
        Capsule()
            .fill(.clear)
            .frame(width: open ? 300 : 150, height: open ? 64 : 40)
            .glassEffect(.regular, in: Capsule())
            .overlay {
                HStack(spacing: 14) {
                    Image(systemName: "music.note")
                        .font(.system(size: open ? 26 : 16, weight: .semibold))
                    if open {
                        Text("Islet").font(.system(size: 26, weight: .bold))
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(IslandMotion.playful) { open.toggle() }
                }
            }
    }
}

/// Hover to expand, exactly like the real island: a floating glass pill, or on a notched
/// Mac a black island growing out of the notch under a strip of menu bar.
private struct IslandDemo: View {
    @State private var hovering = false
    private let notched = IslandMetrics.make(for: NSScreen.screens.first, style: .black).hasNotch

    var body: some View {
        VStack(spacing: 12) {
            if notched { notchIsland } else { pillIsland }
            Text(hovering ? "That's it." : "Hover me")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var pillIsland: some View {
        RoundedRectangle(cornerRadius: hovering ? 30 : 18, style: .continuous)
            .fill(.clear)
            .frame(width: hovering ? 380 : 190, height: hovering ? 130 : 36)
            .glassEffect(.regular, in: .rect(cornerRadius: hovering ? 30 : 18))
            .overlay(alignment: hovering ? .topLeading : .leading) { content.padding(hovering ? 22 : 7) }
            .onHover(perform: hover)
    }

    private var notchIsland: some View {
        // Square top, like the real island beside a notch.
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: hovering ? 38 : 12,
                                           bottomTrailingRadius: hovering ? 38 : 12, topTrailingRadius: 0,
                                           style: .continuous)
        return VStack(spacing: 0) {
            // A sliver of menu bar, so the island reads as hanging from the screen's top edge.
            Rectangle().fill(.white.opacity(0.12)).frame(width: 440, height: 6)
            shape
                .fill(.black)
                .frame(width: hovering ? 400 : 270, height: hovering ? 150 : 32)
                .overlay(alignment: hovering ? .bottomLeading : .leading) {
                    content.padding(.horizontal, hovering ? 24 : 8).padding(.bottom, hovering ? 20 : 0)
                }
                .overlay {
                    // The camera housing itself, which the island's wings flank.
                    if !hovering {
                        Capsule().fill(Color(white: 0.06)).frame(width: 150, height: 26).offset(y: -2)
                    }
                }
                .onHover(perform: hover)
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: hovering ? 12 : 6)
                .fill(LinearGradient(colors: [.pink, .orange], startPoint: .top, endPoint: .bottom))
                .frame(width: hovering ? 54 : 22, height: hovering ? 54 : 22)
            if hovering {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Song").font(.system(size: 15, weight: .semibold))
                    Text("Your Artist").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            Image(systemName: "waveform").foregroundStyle(.orange)
        }
    }

    private func hover(_ inside: Bool) {
        withAnimation(IslandMotion.playful) { hovering = inside }
    }
}

/// A real Islet slider: drag it and feel each detent.
private struct FeelDemo: View {
    @State private var value = 0.3

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "dial.medium")
                .font(.system(size: 54, weight: .light))
                .rotationEffect(.degrees(value * 300 - 150))
                .animation(IslandMotion.quick, value: value)
            GlassSlider(value: value, restHeight: 6, thumb: .always,
                        onChange: { value = $0 }, onCommit: { value = $0 })
                .frame(width: 360)
        }
    }
}

/// The artwork zooms up into a full-screen-style player with lyric lines.
private struct PlayerDemo: View {
    @State private var line = 0
    private let lines = ["The island opens up", "into a full-screen player", "with lyrics in time"]

    var body: some View {
        HStack(spacing: 28) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 170, height: 170)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .font(.system(size: 21, weight: .bold))
                        .opacity(index == line ? 1 : 0.3)
                        .scaleEffect(index == line ? 1.04 : 1, anchor: .leading)
                }
            }
            .frame(width: 300, alignment: .leading)
            .animation(IslandMotion.panel, value: line)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.3))
                line = (line + 1) % lines.count
            }
        }
    }
}

/// Wrong finger: red and a shake. Right finger: red to green, then the padlock opens.
private struct LockDemo: View {
    private enum Step { case locked, failed, unlocking }
    @State private var step = Step.locked
    @State private var shakes: CGFloat = 0
    @State private var run = 0

    var body: some View {
        ZStack {
            Capsule().fill(.black).frame(width: 220, height: 44)
            Group {
                switch step {
                case .locked, .failed:
                    LockedContent(failed: step == .failed)
                case .unlocking:
                    UnlockContent().id(run)
                }
            }
            .frame(width: 220, height: 44)
        }
        .modifier(DemoShake(shakes: shakes))
        .scaleEffect(1.6)
        .task {
            while !Task.isCancelled {
                step = .locked
                try? await Task.sleep(for: .seconds(1.2))
                step = .failed
                withAnimation(.linear(duration: 0.5)) { shakes += 1 }
                try? await Task.sleep(for: .seconds(1.3))
                step = .locked
                try? await Task.sleep(for: .seconds(0.7))
                run += 1
                step = .unlocking
                try? await Task.sleep(for: .seconds(2.6))
            }
        }
    }
}

private struct DemoShake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = shakes - shakes.rounded(.down)
        return ProjectionTransform(CGAffineTransform(translationX: 11 * (1 - progress) * sin(progress * .pi * 6), y: 0))
    }
}

private struct DoneHero: View {
    @State private var pop = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 96))
            .foregroundStyle(.white, .green)
            .symbolEffect(.bounce, value: pop)
            .onAppear { pop.toggle() }
    }
}
