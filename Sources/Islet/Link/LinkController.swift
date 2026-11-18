import AppKit
import IsletCore
import Network
import Observation

/// A phone paired with this Mac through the Islet app for Android.
struct LinkDevice: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var model: String
    /// The pair secret (base64). Lives in Islet's support folder, readable only by this user.
    var secret: String
}

/// A notification mirrored from the phone.
struct PhoneNotification: Identifiable, Equatable {
    struct Action: Equatable {
        let index: Int
        let title: String
        let reply: Bool
    }

    let id: String
    let package: String
    let app: String
    var title: String
    var text: String
    var time: Date
    var actions: [Action]
    var isCall: Bool
    var icon: NSImage?

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.title == b.title && a.text == b.text && a.actions == b.actions && a.isCall == b.isCall
    }
}

/// What the phone is playing.
struct PhoneMedia: Equatable {
    var title: String
    var artist: String
    var app: String
    var duration: TimeInterval
    var position: TimeInterval
    var stamp: Date
    var playing: Bool
    var art: NSImage?

    func elapsed(at date: Date) -> TimeInterval {
        let moved = playing ? date.timeIntervalSince(stamp) : 0
        return duration > 0 ? min(position + moved, duration) : position + moved
    }

    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.artist == b.artist && a.playing == b.playing && a.position == b.position
            && a.duration == b.duration && (a.art == nil) == (b.art == nil)
    }
}

/// Something about the phone that the island shows as a card.
enum PhoneAlert: Equatable {
    case notification(PhoneNotification)
    case call(PhoneNotification)
    case pairing(name: String, code: String)
    case transfer(name: String, progress: Double, incoming: Bool)
}

/// The phone that is connected now.
struct ConnectedPhone: Equatable {
    var id: String
    var name: String
    var model: String
    var transport: LinkTransport
    var battery: Int?
    var charging = false
    var network: String?
    var media: PhoneMedia?
    var notifications: [PhoneNotification] = []
}

/// Islet Link on the Mac: finds and pairs the Android app, keeps one live connection per
/// phone (USB, then Wi-Fi, then Bluetooth), and joins the phone into the island: its
/// notifications and calls as cards, its battery and music on the phone page, the Mac's
/// music as a media session on the phone, files through Portal, a shared clipboard, and
/// the phone as a remote for the Mac.
@MainActor
@Observable
final class LinkController {
    private(set) var devices: [LinkDevice] = []
    private(set) var phone: ConnectedPhone?
    /// A pairing waiting for the user to compare codes and accept.
    private(set) var pendingPairing: (name: String, code: String)?
    private(set) var problem: String?
    let settings = LinkSettings()

    @ObservationIgnored private weak var island: IslandController?
    @ObservationIgnored private let store: PlayerStore
    @ObservationIgnored private weak var portal: PortalController?
    @ObservationIgnored private let tcp = LinkTCPListener()
    @ObservationIgnored private let bluetooth = LinkBluetooth()
    @ObservationIgnored let usb = LinkUSB()
    @ObservationIgnored private var sessions: [LinkSession] = []
    @ObservationIgnored private var pairingSession: LinkSession?
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var sentArtRevision = -1
    @ObservationIgnored private var clipboardTimer: Timer?
    @ObservationIgnored private var clipboardCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var pausedForCall = false
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var running = false

    let macID: String
    let macName = Host.current().localizedName ?? "Mac"

    @ObservationIgnored private let devicesFile: URL

    init(store: PlayerStore, island: IslandController, portal: PortalController) {
        self.store = store
        self.island = island
        self.portal = portal
        devicesFile = portal.settings.supportDirectory.appending(path: "link-devices.json")
        if let saved = UserDefaults.standard.string(forKey: "linkMacID") {
            macID = saved
        } else {
            macID = UUID().uuidString
            UserDefaults.standard.set(macID, forKey: "linkMacID")
        }
        devices = (try? JSONDecoder().decode([LinkDevice].self, from: Data(contentsOf: devicesFile))) ?? []
    }

    func start() { follow() }

    private func follow() {
        let on = withObservationTracking { settings.enabled } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        on ? begin() : end()
        followBluetooth()
    }

    private func begin() {
        guard !running else { return }
        running = true
        tcp.onPipe = { [weak self] in self?.adopt($0) }
        tcp.onHTTP = { [weak self] in self?.serveApp(on: $0) }
        bluetooth.onPipe = { [weak self] in self?.adopt($0) }
        tcp.start(name: macName, macID: macID)
        problem = tcp.problem
        usb.start()
        watchMacMusic()
        watchMacStatus()
        // Closes links that went quiet (the phone pings every 25 s).
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                let cutoff = Date().addingTimeInterval(-75)
                self?.sessions.filter { $0.lastHeard < cutoff }.forEach { $0.close() }
            }
        }
        watchdog?.tolerance = 10
    }

    private func end() {
        guard running else { return }
        running = false
        sessions.forEach { $0.close() }
        sessions = []
        tcp.stop()
        usb.stop()
        bluetooth.setAdvertising(false)
        watchdog?.invalidate()
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        phone = nil
    }

    /// Bluetooth only while a paired phone has no faster link (advertising costs power).
    private func followBluetooth() {
        let wanted = withObservationTracking {
            settings.enabled && settings.useBluetooth && !devices.isEmpty
                && !(phone.map { $0.transport != .bluetooth } ?? false)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followBluetooth() }
        }
        bluetooth.setAdvertising(wanted)
    }

    // MARK: - Sessions

    private func adopt(_ pipe: LinkPipe) {
        Log.media.notice("Link: new \(pipe.transport.label, privacy: .public) connection")
        let session = LinkSession(pipe: pipe, macID: macID, macName: macName)
        session.secretFor = { [weak self] id in
            self?.devices.first { $0.id == id }.flatMap { Data(base64Encoded: $0.secret) }
        }
        session.onPairRequest = { [weak self] session, code in self?.pairingRequested(session, code: code) }
        session.onPaired = { [weak self] session, secret in self?.paired(session, secret: secret) }
        session.onReady = { [weak self] in self?.ready($0) }
        session.onMessage = { [weak self] in self?.handle($1, from: $0) }
        session.onClose = { [weak self] in self?.closed($0) }
        session.onFile = { [weak self] in self?.received($1, from: $0) }
        session.onProgress = { [weak self] in self?.progress($0) }
        sessions.append(session)
        session.start()
    }

    /// The best ready link for the current phone.
    private var active: LinkSession? {
        sessions.filter { $0.phase == .ready && $0.phoneID == phone?.id }.min { $0.transport < $1.transport }
    }

    private func ready(_ session: LinkSession) {
        if var device = devices.first(where: { $0.id == session.phoneID }) {
            device.name = session.phoneName
            device.model = session.phoneModel
            update(device)
        }
        let best = sessions.filter { $0.phase == .ready && $0.phoneID == session.phoneID }.map(\.transport).min() ?? session.transport
        if phone?.id == session.phoneID {
            phone?.transport = best
        } else {
            phone = ConnectedPhone(id: session.phoneID, name: session.phoneName, model: session.phoneModel, transport: best)
        }
        session.send(statusMessage())
        sentArtRevision = -1
        sendMacMusic(to: session)
        session.send(LinkMessage("settings", ["remote": settings.allowRemote, "clipboard": settings.syncClipboard]))
        Task { @MainActor [weak session] in
            let names = await LinkRemote.shortcutNames()
            session?.send(LinkMessage("shortcuts", ["names": names]))
        }
        followClipboard()
        Log.media.notice("Link: \(session.phoneName, privacy: .public) connected over \(session.transport.label, privacy: .public)")
    }

    private func closed(_ session: LinkSession) {
        Log.media.notice("Link: \(session.transport.label, privacy: .public) connection closed (phase \(String(describing: session.phase), privacy: .public))")
        sessions.removeAll { $0 === session }
        if pairingSession === session {
            pairingSession = nil
            pendingPairing = nil
        }
        guard let id = phone?.id, session.phoneID == id else { return }
        if let best = sessions.filter({ $0.phase == .ready && $0.phoneID == id }).map(\.transport).min() {
            phone?.transport = best
        } else {
            phone = nil
            followClipboard()
            if case .phone? = island?.model.activity { island?.dismissActivity() }
        }
    }

    private var portalEffect: PortalEffect { portal?.settings.portalEffect ?? .vortex }

    // MARK: - Pairing

    private func pairingRequested(_ session: LinkSession, code: String) {
        Log.media.notice("Link: pairing requested by \(session.phoneName, privacy: .public) over \(session.transport.label, privacy: .public)")
        pairingSession?.answerPairing(false)
        pairingSession = session
        pendingPairing = (session.phoneName, code)
        island?.showPhone(.pairing(name: session.phoneName, code: code), for: .seconds(90))
        NSSound(named: "Glass")?.play()
    }

    /// The user compared the codes (island card or Settings).
    func answerPairing(_ accept: Bool) {
        pairingSession?.answerPairing(accept)
        pairingSession = nil
        pendingPairing = nil
        if case .phone(.pairing)? = island?.model.activity { island?.dismissActivity() }
    }

    private func paired(_ session: LinkSession, secret: Data) {
        update(LinkDevice(id: session.phoneID, name: session.phoneName, model: session.phoneModel,
                          secret: secret.base64EncodedString()))
        island?.showPortal(PortalArrival(direction: .received, title: "\(session.phoneName) paired",
                                         detail: "Notifications, music and files are connected",
                                         preview: nil, symbol: "iphone.gen3", effect: portalEffect))
    }

    func forget(_ device: LinkDevice) {
        devices.removeAll { $0.id == device.id }
        save()
        for session in sessions where session.phoneID == device.id {
            session.send(LinkMessage("unpair"))
            session.close()
        }
    }

    private func update(_ device: LinkDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            guard devices[index] != device else { return }
            devices[index] = device
        } else {
            devices.append(device)
        }
        save()
    }

    private func save() {
        let manager = FileManager.default
        try? manager.createDirectory(at: devicesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(devices).write(to: devicesFile, options: [.atomic])
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devicesFile.path)
    }

    // MARK: - From the phone

    private func handle(_ message: LinkMessage, from session: LinkSession) {
        let fields = message.fields
        switch message.type {
        case "status":
            phone?.battery = (fields["battery"] as? NSNumber)?.intValue
            phone?.charging = fields["charging"] as? Bool ?? false
            phone?.network = fields["network"] as? String
        case "notif.post":
            posted(fields, icon: message.body)
        case "notif.remove":
            guard let key = fields["key"] as? String else { return }
            let call = phone?.notifications.first { $0.id == key && $0.isCall }
            phone?.notifications.removeAll { $0.id == key }
            if case let .phone(.notification(shown))? = island?.model.activity, shown.id == key { island?.dismissActivity() }
            if case let .phone(.call(shown))? = island?.model.activity, shown.id == key { island?.dismissActivity() }
            if call != nil, pausedForCall {
                pausedForCall = false
                if !store.isPlaying { store.togglePlayPause() }
            }
        case "media.state":
            phoneMedia(fields, art: message.body)
        case "media.clear":
            phone?.media = nil
        case "mac.cmd":
            command(fields)
        case "input":
            input(fields)
        case "clip":
            guard settings.syncClipboard, let text = fields["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            clipboardCount = NSPasteboard.general.changeCount
            island?.showPortal(PortalArrival(direction: .received, title: String(text.prefix(40)),
                                             detail: "Clipboard from \(session.phoneName)", preview: nil,
                                             symbol: "doc.on.clipboard", effect: portalEffect))
        case "text":
            // Shared text or a link from the phone's share sheet: Portal's handling.
            if let text = fields["text"] as? String { portal?.receiveText(text, from: session.phoneName) }
        case "find":
            LinkRemote.ring()
        case "unpair":
            if let device = devices.first(where: { $0.id == session.phoneID }) { forget(device) }
        default:
            break
        }
    }

    private func posted(_ fields: [String: Any], icon: Data) {
        guard let key = fields["key"] as? String else { return }
        let package = fields["pkg"] as? String ?? ""
        if !icon.isEmpty, let image = NSImage(data: icon) { icons[package] = image }
        let actions = (fields["actions"] as? [[String: Any]] ?? []).compactMap { action -> PhoneNotification.Action? in
            guard let index = (action["i"] as? NSNumber)?.intValue, let title = action["title"] as? String else { return nil }
            return .init(index: index, title: title, reply: action["reply"] as? Bool ?? false)
        }
        let note = PhoneNotification(
            id: key, package: package, app: fields["app"] as? String ?? "",
            title: fields["title"] as? String ?? "", text: fields["text"] as? String ?? "",
            time: Date(timeIntervalSince1970: ((fields["time"] as? NSNumber)?.doubleValue ?? 0) / 1000),
            actions: actions, isCall: fields["call"] as? Bool ?? false, icon: icons[package])
        let isUpdate = phone?.notifications.contains { $0.id == key } ?? false
        phone?.notifications.removeAll { $0.id == key }
        phone?.notifications.insert(note, at: 0)
        if (phone?.notifications.count ?? 0) > 30 { phone?.notifications.removeLast() }
        // Silent updates (a progress bar ticking) don't pop the island again.
        let alert = fields["alert"] as? Bool ?? !isUpdate
        if note.isCall {
            // A call's notification updates while it rings; only its arrival pops the card.
            guard settings.showCalls, alert else { return }
            if settings.pauseForCalls, store.isPlaying {
                store.togglePlayPause()
                pausedForCall = true
            }
            island?.showPhone(.call(note), for: .seconds(40))
        } else if alert, settings.showNotifications {
            island?.showPhone(.notification(note), for: .seconds(6))
        }
    }

    private func phoneMedia(_ fields: [String: Any], art: Data) {
        let title = fields["title"] as? String ?? ""
        var media = PhoneMedia(
            title: title, artist: fields["artist"] as? String ?? "", app: fields["app"] as? String ?? "",
            duration: ((fields["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
            position: ((fields["position"] as? NSNumber)?.doubleValue ?? 0) / 1000,
            stamp: Date(), playing: fields["playing"] as? Bool ?? false, art: nil)
        if !art.isEmpty {
            media.art = NSImage(data: art)
        } else if phone?.media?.title == title {
            media.art = phone?.media?.art
        }
        phone?.media = media
    }

    private func command(_ fields: [String: Any]) {
        guard settings.allowRemote, let action = fields["action"] as? String else { return }
        let value = (fields["value"] as? NSNumber)?.doubleValue ?? 0
        switch action {
        case "toggle": store.togglePlayPause()
        case "play": if !store.isPlaying { store.togglePlayPause() }
        case "pause": if store.isPlaying { store.togglePlayPause() }
        case "next": store.next()
        case "previous": store.previous()
        case "seek": store.seek(to: value)
        case "volume": store.setVolume(value)
        case "brightness": BrightnessMonitor.shared.set(value)
        case "lock": SystemControls.shared.lockScreen()
        case "sleep": LinkRemote.sleepDisplay()
        case "screenshot": SystemControls.shared.screenshot()
        case "shortcut": if let name = fields["name"] as? String { LinkRemote.runShortcut(name) }
        default: break
        }
        active?.send(statusMessage())
    }

    private func input(_ fields: [String: Any]) {
        guard settings.allowRemote else { return }
        guard LinkRemote.trusted else {
            LinkRemote.askForAccess()
            active?.send(LinkMessage("remote.denied"))
            return
        }
        let number = { (key: String) in (fields[key] as? NSNumber)?.doubleValue ?? 0 }
        switch fields["kind"] as? String {
        case "move": LinkRemote.move(dx: number("dx"), dy: number("dy"))
        case "click": LinkRemote.click(button: fields["button"] as? String ?? "left", count: Int(number("count")))
        case "scroll": LinkRemote.scroll(dx: number("dx"), dy: number("dy"))
        case "drag": LinkRemote.drag(fields["state"] as? String ?? "up")
        case "text": LinkRemote.type(fields["text"] as? String ?? "")
        case "key": LinkRemote.key(fields["key"] as? String ?? "", modifiers: fields["mods"] as? [String] ?? [])
        default: break
        }
    }

    // MARK: - Files

    private func received(_ file: IncomingFile, from session: LinkSession) {
        if case .phone(.transfer)? = island?.model.activity { island?.dismissActivity() }
        portal?.receiveFile(file.url, name: file.name, from: session.phoneName)
    }

    private func progress(_ session: LinkSession) {
        if let file = session.incoming.values.first, file.size > 0 {
            island?.showPhone(.transfer(name: file.name, progress: Double(file.received) / Double(file.size), incoming: true),
                              for: .seconds(5))
        } else if let file = session.outgoing.first, file.size > 0 {
            island?.showPhone(.transfer(name: file.name, progress: Double(file.sent) / Double(file.size), incoming: false),
                              for: .seconds(5))
        } else if case .phone(.transfer)? = island?.model.activity {
            island?.dismissActivity()
        }
    }

    /// Sends files (and text) to the phone. False when no phone is connected.
    @discardableResult
    func send(files: [URL], text: String? = nil) -> Bool {
        guard let session = active else { return false }
        for url in files { session.send(file: url) }
        if let text, !text.isEmpty, files.isEmpty { session.send(LinkMessage("text", ["text": text])) }
        return true
    }

    func chooseFilesToSend() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Send to \(phone?.name ?? "your phone"), at full quality"
        panel.prompt = "Send"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        send(files: panel.urls)
    }

    // MARK: - To the phone

    /// Find My Phone is ringing (the phone stops by itself after a minute).
    private(set) var ringing = false
    @ObservationIgnored private var ringTask: Task<Void, Never>?

    func ringPhone() {
        ringTask?.cancel()
        if ringing {
            ringing = false
            active?.send(LinkMessage("find.stop"))
            return
        }
        guard let active else { return }
        active.send(LinkMessage("find"))
        ringing = true
        ringTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { self?.ringing = false }
        }
    }

    func sendClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        active?.send(LinkMessage("clip", ["text": text]))
    }

    func phoneMediaCommand(_ action: String, value: Double = 0) {
        active?.send(LinkMessage("media.cmd", ["action": action, "value": value]))
    }

    func act(on note: PhoneNotification, action: PhoneNotification.Action, reply: String? = nil) {
        var fields: [String: Any] = ["key": note.id, "i": action.index]
        if let reply { fields["reply"] = reply }
        active?.send(LinkMessage("notif.act", fields))
    }

    func dismiss(_ note: PhoneNotification) {
        phone?.notifications.removeAll { $0.id == note.id }
        active?.send(LinkMessage("notif.dismiss", ["key": note.id]))
    }

    /// The Mac's music as a media session on the phone (lock screen, quick settings).
    private func watchMacMusic() {
        guard running else { return }
        withObservationTracking {
            _ = (store.title, store.artist, store.isPlaying, store.duration, store.timing, store.snapshot?.artworkRevision)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let session = self.active { self.sendMacMusic(to: session) }
                self.watchMacMusic()
            }
        }
    }

    private func sendMacMusic(to session: LinkSession) {
        guard let snapshot = store.snapshot else {
            session.send(LinkMessage("media.clear"))
            return
        }
        var art = Data()
        if snapshot.artworkRevision != sentArtRevision, let data = snapshot.artwork {
            sentArtRevision = snapshot.artworkRevision
            art = Self.jpeg(data, maxPixels: 720) ?? Data()
        }
        session.send(LinkMessage("media.state", [
            "title": snapshot.title, "artist": snapshot.artist, "album": snapshot.album,
            "duration": Int(snapshot.duration * 1000), "position": Int(store.elapsed(at: Date()) * 1000),
            "playing": snapshot.isPlaying, "app": store.sourceName, "art": snapshot.artworkRevision,
        ], body: art))
    }

    private func watchMacStatus() {
        PowerMonitor.shared.onStateChange = { [weak self] in
            guard let self else { return }
            self.active?.send(self.statusMessage())
        }
    }

    private func statusMessage() -> LinkMessage {
        var fields: [String: Any] = ["name": macName, "volume": store.volume,
                                     "brightness": BrightnessMonitor.shared.level ?? -1]
        if let battery = PowerMonitor.shared.state {
            fields["battery"] = Int((battery.level * 100).rounded())
            fields["charging"] = battery.isCharging || battery.isPluggedIn
        }
        return LinkMessage("status", fields)
    }

    /// Mac → phone clipboard: checked every two seconds, and only while a phone is connected.
    private func followClipboard() {
        let wanted = phone != nil && settings.syncClipboard
        if wanted, clipboardTimer == nil {
            clipboardCount = NSPasteboard.general.changeCount
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.checkClipboard() }
            }
            timer.tolerance = 1
            clipboardTimer = timer
        } else if !wanted {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        }
    }

    private func checkClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != clipboardCount else { return }
        clipboardCount = board.changeCount
        // Passwords from password managers are marked concealed: never sent.
        let types = board.types ?? []
        guard !types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
              let text = board.string(forType: .string), !text.isEmpty, text.utf8.count < 200_000 else { return }
        active?.send(LinkMessage("clip", ["text": text]))
    }

    // MARK: - The app itself

    /// `http://<mac>:47480/` from the phone's browser downloads the app bundled in Islet.
    private func serveApp(on connection: NWConnection) {
        let body = Self.bundledAPK.flatMap { try? Data(contentsOf: $0) }
        var head = body == nil
            ? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
            : "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.android.package-archive\r\n"
                + "Content-Disposition: attachment; filename=\"IsletLink.apk\"\r\nContent-Length: \(body!.count)\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + (body ?? Data()), completion: .contentProcessed { _ in connection.cancel() })
    }

    static var bundledAPK: URL? { Bundle.main.url(forResource: "IsletLink", withExtension: "apk") }

    /// Where the phone's browser can download the app (for the QR code in Settings).
    var downloadURL: URL? {
        guard Self.bundledAPK != nil, let address = PortalController.wifiAddress else { return nil }
        return URL(string: "http://\(address):\(Link.port)/IsletLink.apk")
    }

    private static func jpeg(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    // MARK: - Debug

    /// `link.fake`: a pretend phone, so the island and Settings can be checked without one.
    func debugFake(_ what: String) {
        if phone == nil || what == "phone" {
            phone = ConnectedPhone(id: "debug", name: "Pixel 9 Pro", model: "Google Pixel 9 Pro", transport: .wifi,
                                   battery: 76, charging: true, network: "wifi")
        }
        let icon = NSImage(systemSymbolName: "message.fill", accessibilityDescription: nil)
        switch what {
        case "notification":
            posted(["key": UUID().uuidString, "pkg": "com.google.android.apps.messaging", "app": "Messages",
                    "title": "Maya", "text": "Are we still on for dinner at 8? I booked the place by the river.",
                    "time": Date().timeIntervalSince1970 * 1000,
                    "actions": [["i": 0, "title": "Reply", "reply": true], ["i": 1, "title": "Mark as read"]]], icon: Data())
            if let icon { phone?.notifications[0].icon = icon }
        case "call":
            posted(["key": "call", "pkg": "com.google.android.dialer", "app": "Phone", "title": "Maya",
                    "text": "Incoming call", "call": true, "time": Date().timeIntervalSince1970 * 1000,
                    "actions": [["i": 0, "title": "Decline"], ["i": 1, "title": "Answer"]]], icon: Data())
        case "media":
            phone?.media = PhoneMedia(title: "Espresso", artist: "Sabrina Carpenter", app: "Spotify", duration: 175,
                                      position: 42, stamp: Date(), playing: true, art: nil)
        case "pair":
            pendingPairing = ("Pixel 9 Pro", "482 913")
            island?.showPhone(.pairing(name: "Pixel 9 Pro", code: "482 913"), for: .seconds(20))
        case "transfer":
            island?.showPhone(.transfer(name: "PXL_20261118_0912.jpg", progress: 0.62, incoming: true), for: .seconds(5))
        case "off":
            phone = nil
            pendingPairing = nil
        default:
            break
        }
    }
}

/// Settings → Phone.
@MainActor
@Observable
final class LinkSettings {
    private let defaults = UserDefaults.standard

    var enabled: Bool { didSet { defaults.set(enabled, forKey: "linkEnabled") } }
    var showNotifications: Bool { didSet { defaults.set(showNotifications, forKey: "linkNotifications") } }
    var showCalls: Bool { didSet { defaults.set(showCalls, forKey: "linkCalls") } }
    var pauseForCalls: Bool { didSet { defaults.set(pauseForCalls, forKey: "linkPauseForCalls") } }
    var syncClipboard: Bool { didSet { defaults.set(syncClipboard, forKey: "linkClipboard") } }
    var allowRemote: Bool { didSet { defaults.set(allowRemote, forKey: "linkRemote") } }
    var useBluetooth: Bool { didSet { defaults.set(useBluetooth, forKey: "linkBluetooth") } }

    init() {
        defaults.register(defaults: [
            "linkEnabled": true, "linkNotifications": true, "linkCalls": true, "linkPauseForCalls": true,
            "linkClipboard": true, "linkRemote": true, "linkBluetooth": true,
        ])
        enabled = defaults.bool(forKey: "linkEnabled")
        showNotifications = defaults.bool(forKey: "linkNotifications")
        showCalls = defaults.bool(forKey: "linkCalls")
        pauseForCalls = defaults.bool(forKey: "linkPauseForCalls")
        syncClipboard = defaults.bool(forKey: "linkClipboard")
        allowRemote = defaults.bool(forKey: "linkRemote")
        useBluetooth = defaults.bool(forKey: "linkBluetooth")
    }
}
