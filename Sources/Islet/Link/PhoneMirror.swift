import AppKit
import AVFoundation
import LocalAuthentication
import CoreMedia
import Network
import Observation
import SwiftUI

/// Phone Mirroring: the Android phone in a window, used with the Mac's pointer and keyboard,
/// modelled on iPhone Mirroring. Over USB or Wi-Fi (adb), Islet starts a small server from
/// the phone app (as the adb shell) that runs a second, private screen on the phone and
/// streams it here as H.264, with the phone's sound; clicks, swipes and typing go back as
/// touches and keys. Meanwhile the phone shows "Phone in use"; using it ends mirroring and
/// locks it. The window stays to say why, with Try Again, as iPhone Mirroring's does.
@MainActor @Observable
final class PhoneMirror {
    enum Ending: Equatable { case used, locked, lost(String), setup }
    enum State: Equatable { case idle, connecting, unlock, live, paused, ended(Ending) }

    private(set) var state: State = .idle
    /// The window is open (connecting, live, paused or showing why it ended).
    var running: Bool { state != .idle }
    /// A session is up or on its way.
    var streaming: Bool { [.connecting, .unlock, .live, .paused].contains(state) }
    var phoneName = "Phone"

    /// Set by the Link: drops on the window go to the phone like any other file.
    @ObservationIgnored var sendFiles: (([URL]) -> Void)?
    @ObservationIgnored var usbAttached: () -> Bool = { false }
    /// Asks the phone app (over the Link) to switch on Wireless debugging for a Wi-Fi session.
    @ObservationIgnored var requestWireless: (() -> Void)?
    /// Mirroring can start: adb is here and the phone is plugged in or paired for Wi-Fi.
    var available: Bool { LinkUSB.adbPath != nil && (usbAttached() || LinkUSB.wirelessPaired) }
    /// The phone is unlocked with Touch ID here, then its PIN typed there, as iPhone Mirroring does.
    var canUnlock: Bool { PhonePIN.stored }
    @ObservationIgnored private var unlockTried = false

    @ObservationIgnored private var window: MirrorWindow?
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var pendingLaunch: String?
    @ObservationIgnored private var lastInput = Date()
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var hiddenPause = false
    @ObservationIgnored private var previousMenu: NSMenu?
    @ObservationIgnored private lazy var menu = MirrorMenu(mirror: self)

    nonisolated static let port: UInt16 = 47490
    /// Like iPhone Mirroring, an idle connection pauses (sound still playing keeps it going).
    private static let idleAfter: TimeInterval = 5 * 60

    private struct Session {
        let adb: String
        var serial: String?
        var wireless = false
        var server: Process?
        var feed: MirrorFeed?
        var reason = 0
    }

    func toggle() { streaming ? stop() : start() }

    /// Opens the window and connects, or brings it forward when it's already open.
    func start() {
        if streaming { window?.show(); return }
        guard let adb = LinkUSB.adbPath else { return }
        let window = self.window ?? MirrorWindow(mirror: self)
        if self.window == nil {
            self.window = window
            enterApp()
        }
        window.show()
        connect(adb: adb)
    }

    /// Closes the window and ends the session; the phone locks.
    func stop() {
        guard running else { return }
        endSession(nil)
        idleTimer?.invalidate()
        idleTimer = nil
        window?.close()
        window = nil
        leaveApp()
    }

    /// The phone said it's being used (the Link can say so before the session's own socket does).
    func phoneUsed() {
        guard streaming else { return }
        endSession(.used)
    }

    func retry() {
        guard let adb = LinkUSB.adbPath, !streaming else { return }
        connect(adb: adb)
    }

    /// A phone notification clicked on the Mac: its app opens in the mirror (starting it if needed).
    func open(app package: String) {
        if state == .live { send(Self.launch(package)) } else { pendingLaunch = package; start() }
    }

    func home() { input(); send(Data([5])) }
    func back() { input(); send(Data([6])) }
    func switcher() { input(); send(Data([11])) }
    func search() { input(); send(Data([12])) }
    func zoom(_ step: Int) { window?.zoom(step) }

    /// Touch ID (or the Mac's password), then the phone's PIN goes to the phone over the
    /// encrypted connection (USB, or paired Wireless debugging) and is typed on its lock screen.
    func unlock() {
        guard state == .unlock else { return }
        Task {
            guard let pin = await PhonePIN.read(reason: "unlock \(phoneName) for Phone Mirroring"), state == .unlock else { return }
            let bytes = Array(pin.utf8.prefix(64))
            var data = Data([13, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
            data.append(contentsOf: bytes)
            send(data)
        }
    }

    func resume() {
        guard state == .paused else { return }
        send(Data([10]))
        state = .live
        lastInput = Date()
    }

    /// Hidden (minimised or covered) there's nothing to draw, so the phone stops encoding.
    func visibilityChanged(_ visible: Bool) {
        guard state == .live else { return }
        if !visible, !hiddenPause { hiddenPause = true; send(Data([9])) }
        if visible, hiddenPause { hiddenPause = false; send(Data([10])) }
    }

    /// Any click, swipe or key counts as use; it also wakes a paused connection.
    func input() {
        lastInput = Date()
        if state == .paused { resume() }
    }

    // MARK: Session

    private func connect(adb: String) {
        session = Session(adb: adb)
        unlockTried = false
        state = .connecting
        Task { await run(adb: adb) }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    private func checkIdle() {
        guard state == .live, Date().timeIntervalSince(lastInput) > Self.idleAfter,
              Date().timeIntervalSince(session?.feed?.lastSound ?? .distantPast) > 30 else { return }
        send(Data([9]))
        state = .paused
    }

    private func run(adb: String) async {
        // The cable if it's plugged in; otherwise Android's encrypted Wireless debugging (paired
        // once in Settings → Android Phone), which the phone app switches on when asked.
        let devices = await LinkUSB.run(adb, ["devices"]).text.split(separator: "\n").dropFirst()
            .map { $0.split(whereSeparator: \.isWhitespace) }
        var serial: String
        var wireless = false
        if let usb = devices.first(where: { $0.count >= 2 && $0[1] == "device" && !$0[0].contains(":") && !$0[0].contains("_adb-tls") }) {
            serial = String(usb[0])
        } else if LinkUSB.wirelessPaired {
            requestWireless?()
            guard let tls = await LinkUSB.wirelessDevice() else {
                guard state == .connecting else { return }
                return endSession(.lost("Make sure \(phoneName) is on the same Wi-Fi as this Mac and Islet is open on it, or plug it in."))
            }
            guard state == .connecting else { return }
            serial = tls
            wireless = true
        } else {
            return endSession(.setup)
        }
        session?.serial = serial
        session?.wireless = wireless

        let listing = await LinkUSB.run(adb, ["-s", serial, "shell", "pm", "path", "local.islet.link"])
        guard state == .connecting else { return }
        // The APK's path changes with every install, so it's looked up each time.
        guard let path = listing.text.split(separator: "\n").first(where: { $0.hasPrefix("package:") }).map({ String($0.dropFirst(8)) }) else {
            return endSession(.lost(listing.status != 0 ? "\(phoneName) isn't reachable." : "Install Islet on \(phoneName) first."))
        }
        // A fresh socket name per session, so no other app on the phone can reach the server.
        let socket = "islet-mirror-\(UUID().uuidString.prefix(8).lowercased())"
        _ = await LinkUSB.run(adb, ["-s", serial, "forward", "tcp:\(Self.port)", "localabstract:\(socket)"])
        let mac = (Host.current().localizedName ?? "your Mac").replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(filePath: adb)
        // Wi-Fi gets a lighter stream. nohup: if the cable or adb goes first, the server outlives
        // it, sees its socket close, and still tidies up and locks the phone.
        let bitrate = wireless ? 8_000_000 : 12_000_000
        process.arguments = ["-s", serial, "shell", "ISLET_WIRELESS=\(wireless ? 1 : 0) CLASSPATH=\(path) nohup app_process / local.islet.link.mirror.Server 0 0 0 \(bitrate) \(socket) '\(mac)' >/dev/null 2>&1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.lost() } }
        do { try process.run() } catch { return endSession(.lost("Couldn't reach \(phoneName).")) }
        session?.server = process

        guard let window else { return }
        let feed = MirrorFeed(port: Self.port, renderer: window.screen.renderer) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        session?.feed = feed
        window.screen.send = { [weak self, weak feed] data in
            self?.input()
            feed?.send(data)
        }
        feed.start()
    }

    private func handle(_ event: MirrorFeed.Event) {
        guard streaming else { return }
        switch event {
        case .unlock:
            state = .unlock
            // Once per wait: ask for Touch ID straight away, like iPhone Mirroring's
            // "Authenticate Automatically"; the button on the card asks again.
            if canUnlock, !unlockTried { unlockTried = true; unlock() }
        case .live(let width, let height):
            state = .live
            lastInput = Date()
            window?.videoSize = CGSize(width: width, height: height)
            if let pendingLaunch { send(Self.launch(pendingLaunch)); self.pendingLaunch = nil }
        case .finished(let reason):
            session?.reason = reason
        case .ended:
            lost()
        }
    }

    /// The phone ended it (it was used, locked or unplugged), or the server stopped.
    private func lost() {
        guard streaming else { return }
        switch session?.reason {
        case 1: endSession(.used)
        case 2: endSession(.locked)
        default: endSession(.lost("The connection to \(phoneName) was lost."))
        }
    }

    /// Tears the session down; `ending` nil means the window is closing.
    private func endSession(_ ending: Ending?) {
        if let session {
            self.session = nil
            session.feed?.send(MirrorFeed.stop)
            // Give the phone a moment to lock and tidy up before the connection goes.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                session.feed?.close()
                if session.server?.isRunning == true { session.server?.terminate() }
                guard let serial = session.serial else { return }
                _ = await LinkUSB.run(session.adb, ["-s", serial, "forward", "--remove", "tcp:\(Self.port)"])
                if session.wireless { _ = await LinkUSB.run(session.adb, ["disconnect", serial]) }
            }
        }
        pendingLaunch = nil
        hiddenPause = false
        state = ending.map { .ended($0) } ?? .idle
    }

    private func send(_ data: Data) { session?.feed?.send(data) }

    private static func launch(_ package: String) -> Data {
        let bytes = Array(package.utf8.prefix(200))
        var data = Data([8, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        data.append(contentsOf: bytes)
        return data
    }

    // MARK: App

    /// Like iPhone Mirroring, it's an app while it's open: in the Dock, with its own menus.
    private func enterApp() {
        previousMenu = NSApp.mainMenu
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = menu.bar
    }

    private func leaveApp() {
        NSApp.mainMenu = previousMenu
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The two connections to the phone's server, on a queue of their own: video in (status,
/// size, then H.264 packets, decoded by an AVSampleBufferDisplayLayer), input out.
final class MirrorFeed: @unchecked Sendable {
    enum Event: Sendable { case unlock, live(Int, Int), finished(Int), ended }

    static let stop = Data([7])

    private let port: NWEndpoint.Port
    private let renderer: AVSampleBufferVideoRenderer
    private let events: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "local.islet.mirror", qos: .userInteractive)
    private var video: NWConnection?
    private var control: NWConnection?
    private var attempts = 0
    private var heard = false
    private var closed = false

    private var bytes: [UInt8] = []
    private var offset = 0
    private enum Phase { case status, size, header, body(flags: Int32, size: Int) }
    private var phase = Phase.status
    private var format: CMVideoFormatDescription?
    private let sound = MirrorSound()
    /// When the phone last sent sound (read on the main actor for the idle check; a stale read is harmless).
    nonisolated(unsafe) private(set) var lastSound = Date.distantPast

    init(port: UInt16, renderer: AVSampleBufferVideoRenderer, events: @escaping @Sendable (Event) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.renderer = renderer
        self.events = events
    }

    func start() { queue.async { self.dial() } }

    func send(_ data: Data) {
        queue.async { self.control?.send(content: data, completion: .idempotent) }
    }

    func close() {
        queue.async {
            self.closed = true
            self.video?.cancel()
            self.control?.cancel()
            self.sound.stop()
        }
    }

    /// adb accepts the connection before the server listens, then drops it: retry until the phone answers.
    private func dial() {
        guard !closed else { return }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        video = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.retry() }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    private func retry() {
        video?.cancel()
        attempts += 1
        guard !heard, !closed, attempts < 40 else { if !closed { events(.ended) }; return }
        queue.asyncAfter(deadline: .now() + 0.25) { self.dial() }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self, connection === self.video else { return }
            if let data, !data.isEmpty {
                if !self.heard {
                    self.heard = true
                    let control = NWConnection(host: "127.0.0.1", port: self.port, using: .tcp)
                    self.control = control
                    control.start(queue: self.queue)
                }
                self.bytes.append(contentsOf: data)
                self.parse()
            }
            if complete || error != nil {
                if self.heard { if !self.closed { self.events(.ended) } } else { self.retry() }
                return
            }
            self.receive(connection)
        }
    }

    private func parse() {
        while true {
            let available = bytes.count - offset
            switch phase {
            case .status:
                guard available >= 4 else { return compact() }
                let status = int32(at: offset)
                offset += 4
                if status == 1 { phase = .size } else if status == 0 { events(.unlock) } // 2 is the phone's hello
            case .size:
                guard available >= 8 else { return compact() }
                events(.live(Int(int32(at: offset)), Int(int32(at: offset + 4))))
                offset += 8
                phase = .header
            case .header:
                guard available >= 16 else { return compact() }
                let flags = int32(at: offset + 8)
                let size = Int(int32(at: offset + 12))
                offset += 16
                phase = .body(flags: flags, size: size)
            case .body(let flags, let size):
                guard available >= size else { return compact() }
                if flags & 8 != 0 {
                    events(.finished(size > 0 ? Int(bytes[offset]) : 0))
                } else if flags & 4 != 0 {
                    lastSound = Date()
                    sound.play(bytes[offset ..< offset + size])
                } else {
                    packet(bytes[offset ..< offset + size], flags: flags)
                }
                offset += size
                phase = .header
            }
        }
    }

    private func compact() {
        if offset > 0 { bytes.removeFirst(offset); offset = 0 }
    }

    private func int32(at index: Int) -> Int32 {
        Int32(bitPattern: UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3]))
    }

    // MARK: H.264

    /// Annex-B (start codes) into NAL units.
    static func units(_ data: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var start: Int?
        var i = data.startIndex
        while i + 2 < data.endIndex {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if let start { units.append(data[start ..< (data[i - 1] == 0 && i - 1 >= start ? i - 1 : i)]) }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let start, start < data.endIndex { units.append(data[start ..< data.endIndex]) }
        return units.filter { !$0.isEmpty }
    }

    private func packet(_ data: ArraySlice<UInt8>, flags: Int32) {
        let units = Self.units(data)
        let sps = units.first { $0.first! & 0x1F == 7 }
        let pps = units.first { $0.first! & 0x1F == 8 }
        if let sps, let pps { format = Self.format(sps: Array(sps), pps: Array(pps)) ?? format }
        guard let format else { return }
        var avcc = Data()
        for unit in units where ![7, 8, 9].contains(unit.first! & 0x1F) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: unit)
        }
        guard !avcc.isEmpty, let sample = Self.sample(avcc, format: format) else { return }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    private static func format(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return format
    }

    private static func sample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block
        else { return nil }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
        else { return nil }
        // Show each frame the moment it arrives: this is a live screen, not a movie.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// The phone's PIN for unlocking it from the Mac, in this Mac's keychain, handed out only after
/// Touch ID or the Mac's password.
enum PhonePIN {
    private static let service = "local.islet.phone-pin"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "phone"]
    }

    static var stored: Bool { SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess }

    @discardableResult
    static func save(_ pin: String) -> Bool {
        delete()
        var item = query
        item[kSecValueData as String] = Data(pin.utf8)
        item[kSecAttrLabel as String] = "Islet phone PIN"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(query as CFDictionary) }

    @MainActor
    static func read(reason: String) async -> String? {
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        var item = query
        item[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The phone's sound (48 kHz stereo 16-bit PCM) on the Mac's output, kept within about
/// 120 ms of live: if the queue grows past that (a Wi-Fi hiccup), new audio is dropped until
/// it drains, so it never lags behind the picture.
final class MirrorSound: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    private let lock = NSLock()
    private var queued = 0
    private var started = false

    func play(_ data: ArraySlice<UInt8>) {
        if !started {
            started = true
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do { try engine.start() } catch { return }
            player.play()
        }
        let frames = data.count / 4
        guard frames > 0 else { return }
        lock.lock()
        let backlog = queued
        lock.unlock()
        if backlog > 5_760 { return }
        // After a gap, a little silence first so the next packets don't stutter.
        if backlog == 0, let pad = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_920) {
            pad.frameLength = 1_920
            schedule(pad)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        var index = data.startIndex
        for frame in 0 ..< frames {
            let left = Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8)
            let right = Int16(bitPattern: UInt16(data[index + 2]) | UInt16(data[index + 3]) << 8)
            channels[0][frame] = Float(left) / 32_768
            channels[1][frame] = Float(right) / 32_768
            index += 4
        }
        schedule(buffer)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        lock.lock(); queued += frames; lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queued -= frames; self.lock.unlock()
        }
    }

    func stop() {
        guard started else { return }
        player.stop()
        engine.stop()
    }
}

/// The window, after iPhone Mirroring's: nothing but the phone's screen. Its controls (the
/// window buttons, the phone's name, Home and App Switcher) fade in above it while the
/// pointer is over it and fade away a moment after. It changes size in steps (View → Zoom)
/// rather than by dragging, so the screen keeps its exact shape.
@MainActor
final class MirrorWindow: NSObject, NSWindowDelegate {
    static let chrome: CGFloat = 34

    let window: NSWindow
    let screen = MirrorView()
    private weak var mirror: PhoneMirror?
    private var scale: CGFloat = 1
    private var closing = false

    var videoSize = CGSize(width: 1080, height: 2336) {
        didSet { if videoSize != oldValue { fit(animated: true) } }
    }

    init(mirror: PhoneMirror) {
        self.mirror = mirror
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Phone Mirroring"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenNone]
        window.setFrameAutosaveName("IsletPhoneMirroring")
        window.standardWindowButton(.zoomButton)?.isHidden = true
        screen.onDropFiles = { [weak mirror] urls in mirror?.sendFiles?(urls) }
        let content = NSHostingView(rootView: MirrorContent(mirror: mirror, screen: screen) { [weak self] visible in
            self?.showWindowButtons(visible)
        })
        content.sizingOptions = []
        window.contentView = content
        showWindowButtons(false)
        fit(animated: false)
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(screen)
    }

    func close() {
        closing = true
        window.close()
    }

    /// One step bigger (1), smaller (-1), or back to the default size (0).
    func zoom(_ step: Int) {
        scale = step == 0 ? 1 : min(max(scale * (step > 0 ? 1.15 : 1 / 1.15), 0.45), 1.4)
        fit(animated: true)
    }

    /// The default is about three quarters of the screen's height, like iPhone Mirroring.
    private func fit(animated: Bool) {
        guard let display = window.screen ?? NSScreen.main else { return }
        let available = display.visibleFrame.height - Self.chrome - 20
        let height = min(min(display.visibleFrame.height * 0.74, 860) * scale, available)
        let width = height * videoSize.width / videoSize.height
        let size = NSSize(width: width, height: height + Self.chrome)
        var frame = window.frame
        let fresh = frame.width < 2
        let top = fresh ? display.visibleFrame.midY + size.height / 2 : frame.maxY
        let midX = fresh ? display.visibleFrame.midX : frame.midX
        frame = NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        frame.origin.y = max(frame.minY, display.visibleFrame.minY)
        window.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func showWindowButtons(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton] {
                window.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !closing { mirror?.stop() }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        mirror?.visibilityChanged(window.occlusionState.contains(.visible))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window.makeFirstResponder(screen)
    }
}

/// The window's content: the floating controls, then the screen in the phone's own shape,
/// with a status card over a blurred last frame whenever it isn't live.
private struct MirrorContent: View {
    let mirror: PhoneMirror
    let screen: MirrorView
    let chromeChanged: (Bool) -> Void
    @State private var revealed = false
    @State private var overChrome = false
    @State private var hide: Task<Void, Never>?

    private var chromeShown: Bool { revealed || overChrome || mirror.state != .live }

    var body: some View {
        VStack(spacing: 0) {
            MirrorChrome(mirror: mirror)
                .frame(height: MirrorWindow.chrome)
                .opacity(chromeShown ? 1 : 0)
                .onHover { overChrome = $0 }
            GeometryReader { geometry in
                // The phone's own corner (113 px on a 1080 px wide screen).
                let shape = RoundedRectangle(cornerRadius: geometry.size.width * 0.105, style: .continuous)
                ZStack {
                    Color.black
                    MirrorScreen(view: screen)
                    if mirror.state != .live {
                        MirrorStatus(mirror: mirror).transition(.opacity)
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
        }
        .animation(.easeOut(duration: 0.2), value: chromeShown)
        .animation(.easeOut(duration: 0.25), value: mirror.state)
        .onContinuousHover { phase in
            switch phase {
            case .active: reveal()
            case .ended: schedule(after: 0.4)
            }
        }
        .onChange(of: chromeShown) { _, shown in chromeChanged(shown) }
    }

    /// Shown while the pointer moves; it fades a moment after it rests.
    private func reveal() {
        if !revealed { revealed = true }
        schedule(after: 1.8)
    }

    private func schedule(after seconds: Double) {
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { revealed = false }
        }
    }
}

private struct MirrorChrome: View {
    let mirror: PhoneMirror

    var body: some View {
        HStack(spacing: 2) {
            Spacer().frame(width: 58) // the window buttons
            Text(mirror.phoneName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            button("house.fill", "Home Screen (⌘1)") { mirror.home() }
            button("square.stack.fill", "App Switcher (⌘2)") { mirror.switcher() }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 4)
        .disabled(mirror.state != .live)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Connecting, waiting for unlock, paused, or why it ended, over a blur of the last frame.
private struct MirrorStatus: View {
    let mirror: PhoneMirror

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(.black.opacity(0.35))
            VStack(spacing: 10) {
                symbol
                Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let action {
                    Button(action.0, action: action.1).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
                }
            }
            .padding(24)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var symbol: some View {
        switch mirror.state {
        case .connecting, .idle, .live: ProgressView().controlSize(.regular).padding(.bottom, 4)
        case .unlock: icon("lock.fill")
        case .paused: icon("pause.fill")
        case .ended(.used): icon("hand.raised.fill")
        case .ended(.locked): icon("lock.fill")
        case .ended(.lost): icon("exclamationmark.triangle.fill")
        case .ended(.setup): icon("wifi")
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.9)).padding(.bottom, 4)
    }

    private var title: String {
        switch mirror.state {
        case .connecting, .idle, .live: "Connecting to \(mirror.phoneName)"
        case .unlock: "Unlock Your Phone"
        case .paused: "Connection Paused"
        case .ended(.used): "Phone in Use"
        case .ended(.locked): "Phone Locked"
        case .ended(.lost): "Unable to Connect to Phone"
        case .ended(.setup): "Set Up Wireless Mirroring"
        }
    }

    private var detail: String? {
        switch mirror.state {
        case .unlock: mirror.canUnlock ? "Use Touch ID to unlock \(mirror.phoneName)." : "Mirroring starts as soon as \(mirror.phoneName) is unlocked."
        case .ended(.setup): "Plug \(mirror.phoneName) in to mirror it now. To use it over Wi-Fi, pair it once in Settings → Android Phone."
        case .ended(.used): "Mirroring ended because \(mirror.phoneName) was used."
        case .ended(.locked): "Mirroring ended when \(mirror.phoneName) locked. Unlock it to connect again."
        case .ended(.lost(let reason)): reason
        default: nil
        }
    }

    private var action: (String, () -> Void)? {
        switch mirror.state {
        case .paused: ("Resume", { mirror.resume() })
        case .unlock where mirror.canUnlock: ("Unlock with Touch ID", { mirror.unlock() })
        case .ended(.setup): ("Open Settings", { NotificationCenter.default.post(name: .openSettingsPane, object: "phone") })
        case .ended: ("Try Again", { mirror.retry() })
        default: nil
        }
    }
}

private struct MirrorScreen: NSViewRepresentable {
    let view: MirrorView
    func makeNSView(context: Context) -> MirrorView { view }
    func updateNSView(_ nsView: MirrorView, context: Context) {}
}

/// The menus while mirroring: View has Home Screen, App Switcher and Search (⌘1–3, as on
/// iPhone Mirroring) and the zoom steps.
@MainActor
final class MirrorMenu: NSObject {
    private weak var mirror: PhoneMirror?
    private(set) var bar = NSMenu()

    init(mirror: PhoneMirror) {
        self.mirror = mirror
        super.init()
        let app = NSMenu(title: "Islet")
        app.addItem(item("Hide Islet", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        app.addItem(.separator())
        app.addItem(item("Quit Islet", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        let view = NSMenu(title: "View")
        view.addItem(item("Home Screen", #selector(home), "1"))
        view.addItem(item("App Switcher", #selector(switcher), "2"))
        view.addItem(item("Search", #selector(search), "3"))
        view.addItem(item("Back", #selector(back), "["))
        view.addItem(.separator())
        view.addItem(item("Zoom In", #selector(zoomIn), "+"))
        view.addItem(item("Zoom Out", #selector(zoomOut), "-"))
        view.addItem(item("Actual Size", #selector(actual), "0"))
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil))
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w", target: nil))
        for menu in [app, view, window] {
            let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            bar.addItem(holder)
        }
    }

    private func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func home() { mirror?.home() }
    @objc private func switcher() { mirror?.switcher() }
    @objc private func search() { mirror?.search() }
    @objc private func back() { mirror?.back() }
    @objc private func zoomIn() { mirror?.zoom(1) }
    @objc private func zoomOut() { mirror?.zoom(-1) }
    @objc private func actual() { mirror?.zoom(0) }
}

/// The phone's screen. Clicks and drags are touches; scrolling scrolls; typing types.
final class MirrorView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    var renderer: AVSampleBufferVideoRenderer { display.sampleBufferRenderer }
    var send: ((Data) -> Void)?
    /// Files dropped on the screen go to the phone (Downloads), like dragging onto iPhone Mirroring.
    var onDropFiles: (([URL]) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard onDropFiles != nil else { return [] }
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 3
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { layer?.borderWidth = 0 }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = bounds
        CATransaction.commit()
    }

    // MARK: Pointer

    private func point(_ event: NSEvent) -> (Float, Float) {
        let location = convert(event.locationInWindow, from: nil)
        let x = min(max(location.x / max(bounds.width, 1), 0), 1)
        let y = min(max(1 - location.y / max(bounds.height, 1), 0), 1)
        return (Float(x), Float(y))
    }

    private func touch(_ action: UInt8, _ event: NSEvent) {
        let (x, y) = point(event)
        var data = Data([1, action])
        data.appendFloat(x)
        data.appendFloat(y)
        send?(data)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); touch(0, event) }
    override func mouseDragged(with event: NSEvent) { touch(2, event) }
    override func mouseUp(with event: NSEvent) { touch(1, event) }

    /// Where the finger is during a two-finger swipe (0…1), while one is down.
    private var swipe: (x: Float, y: Float)?

    /// A trackpad swipe is a finger on the phone: it goes down where the pointer is, moves
    /// with your fingers, and lifts when they do, so the phone flings it its own way (the
    /// Mac's momentum events are ignored). A mouse wheel scrolls in notches.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return wheel(event) }
        if !event.momentumPhase.isEmpty { return }
        // Content follows scrollingDelta's sign in both scroll directions, as a dragged finger does.
        let gain: CGFloat = 1.15
        let dx = Float(event.scrollingDeltaX * gain / max(bounds.width, 1))
        let dy = Float(event.scrollingDeltaY * gain / max(bounds.height, 1))
        switch event.phase {
        case .began:
            let start = point(event)
            swipe = start
            finger(0, start)
        case .changed:
            guard var at = swipe else { return }
            at.x = min(max(at.x + dx, 0), 1)
            at.y = min(max(at.y + dy, 0), 1)
            swipe = at
            finger(2, at)
        case .ended, .cancelled:
            if let at = swipe { finger(1, at) }
            swipe = nil
        default:
            if swipe == nil, event.phase.isEmpty { wheel(event) }
        }
    }

    private func finger(_ action: UInt8, _ at: (x: Float, y: Float)) {
        var data = Data([1, action])
        data.appendFloat(at.x)
        data.appendFloat(at.y)
        send?(data)
    }

    private func wheel(_ event: NSEvent) {
        let (x, y) = point(event)
        var data = Data([2])
        data.appendFloat(x)
        data.appendFloat(y)
        data.appendFloat(Float(-event.scrollingDeltaX))
        data.appendFloat(Float(event.scrollingDeltaY))
        send?(data)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if command {
            switch event.charactersIgnoringModifiers {
            case "1": send?(Data([5]))
            case "[": send?(Data([6]))
            case "v":
                if let text = NSPasteboard.general.string(forType: .string) { type(text) }
            case "w": window?.performClose(nil)
            default: super.keyDown(with: event)
            }
            return
        }
        if let code = Self.keys[event.keyCode] {
            key(0, code, event)
        } else if let text = event.characters, !text.isEmpty, !event.modifierFlags.contains(.control) {
            type(text)
        }
    }

    override func keyUp(with event: NSEvent) {
        if !event.modifierFlags.contains(.command), let code = Self.keys[event.keyCode] { key(1, code, event) }
    }

    private func key(_ action: UInt8, _ code: Int32, _ event: NSEvent) {
        var meta: Int32 = 0
        if event.modifierFlags.contains(.shift) { meta |= 0x1 }   // META_SHIFT_ON
        if event.modifierFlags.contains(.option) { meta |= 0x2 }  // META_ALT_ON
        var data = Data([3, action])
        data.appendInt(code)
        data.appendInt(meta)
        send?(data)
    }

    private func type(_ text: String) {
        let bytes = Array(text.utf8.prefix(4000))
        var data = Data([4, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        data.append(contentsOf: bytes)
        send?(data)
    }

    /// Mac virtual key codes → Android KeyEvent codes, for keys that aren't plain characters.
    private static let keys: [UInt16: Int32] = [
        36: 66,   // Return → ENTER
        76: 66,   // keypad Enter
        51: 67,   // Delete → DEL
        117: 112, // Forward delete → FORWARD_DEL
        48: 61,   // Tab
        53: 4,    // Escape → BACK
        123: 21, 124: 22, 125: 20, 126: 19, // arrows
        115: 122, 119: 123, // Home, End → MOVE_HOME, MOVE_END
        116: 92, 121: 93,   // Page up, down
    ]
}

private extension Data {
    mutating func appendFloat(_ value: Float) { appendInt(Int32(bitPattern: value.bitPattern)) }
    mutating func appendInt(_ value: Int32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
