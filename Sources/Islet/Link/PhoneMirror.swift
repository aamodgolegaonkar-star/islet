import AppKit
import AVFoundation
import CoreMedia
import Network
import Observation

/// Phone Mirroring: the Android phone in a window, used with the Mac's pointer and keyboard,
/// like iPhone Mirroring. Over USB, Islet starts a small server from the phone app (as the
/// adb shell) that runs a second, private screen on the phone and streams it here as
/// H.264; clicks, drags, scrolls and typing go back as touches and keys. Meanwhile the
/// phone itself shows "Phone in use" and goes dark; using it ends mirroring and locks it.
@MainActor @Observable
final class PhoneMirror {
    enum State: Equatable { case idle, connecting, unlock, live }

    private(set) var state: State = .idle
    var running: Bool { state != .idle }

    @ObservationIgnored private var server: Process?
    @ObservationIgnored private var feed: MirrorFeed?
    @ObservationIgnored private var window: MirrorWindow?
    @ObservationIgnored private var adb: String?

    nonisolated static let port: UInt16 = 47490

    func toggle() { running ? stop() : start() }

    func start() {
        if running { window?.show(); return }
        guard let adb = LinkUSB.adbPath else { return }
        self.adb = adb
        state = .connecting
        let window = MirrorWindow { [weak self] in self?.stop() }
        self.window = window
        window.message = "Connecting to your phone…"
        window.show()
        Task { await connect(adb: adb, window: window) }
    }

    func stop() {
        guard running else { return }
        state = .idle
        feed?.send(MirrorFeed.stop)
        let feed = feed, server = server, adb = adb
        self.feed = nil
        self.server = nil
        window?.close()
        window = nil
        // Give the phone a moment to lock and tidy up before the connection goes.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            feed?.close()
            if server?.isRunning == true { server?.terminate() }
            if let adb { _ = await LinkUSB.run(adb, ["forward", "--remove", "tcp:\(Self.port)"]) }
        }
    }

    private func connect(adb: String, window: MirrorWindow) async {
        let listing = await LinkUSB.run(adb, ["shell", "pm", "path", "local.islet.link"])
        // The APK's path changes with every install, so it's looked up each time.
        guard state == .connecting else { return }
        guard let path = listing.text.split(separator: "\n").first(where: { $0.hasPrefix("package:") }).map({ String($0.dropFirst(8)) }) else {
            fail(listing.text.contains("no devices") || listing.status != 0
                 ? "Plug your phone in with USB debugging on." : "Install Islet on your phone first.")
            return
        }
        // A fresh socket name per session, so no other app on the phone can reach the server.
        let socket = "islet-mirror-\(UUID().uuidString.prefix(8).lowercased())"
        _ = await LinkUSB.run(adb, ["forward", "tcp:\(Self.port)", "localabstract:\(socket)"])
        let mac = (Host.current().localizedName ?? "your Mac").replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(filePath: adb)
        // nohup: if the cable or adb goes first, the server outlives it, sees its socket close,
        // and still tidies up and locks the phone.
        process.arguments = ["shell", "CLASSPATH=\(path) nohup app_process / local.islet.link.mirror.Server 0 0 0 12000000 \(socket) '\(mac)' >/dev/null 2>&1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.ended() } }
        do { try process.run() } catch { fail("Couldn't reach your phone."); return }
        server = process

        let feed = MirrorFeed(port: Self.port, renderer: window.view.renderer) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.feed = feed
        window.view.send = { [weak feed] data in feed?.send(data) }
        feed.start()
    }

    private func handle(_ event: MirrorFeed.Event) {
        guard running, let window else { return }
        switch event {
        case .unlock:
            state = .unlock
            window.message = "Unlock your phone to start mirroring."
        case .live(let width, let height):
            state = .live
            window.message = nil
            window.videoSize = CGSize(width: width, height: height)
        case .ended:
            ended()
        }
    }

    /// The phone ended it (it was used, locked or unplugged), or the server stopped.
    private func ended() {
        guard running else { return }
        stop()
    }

    private func fail(_ text: String) {
        window?.message = text
        server?.terminate()
        server = nil
        feed?.close()
        feed = nil
        // The window stays to say why; closing it returns to idle.
    }
}

/// The two connections to the phone's server, on a queue of their own: video in (status,
/// size, then H.264 packets, decoded by an AVSampleBufferDisplayLayer), input out.
final class MirrorFeed: @unchecked Sendable {
    enum Event: Sendable { case unlock, live(Int, Int), ended }

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
                packet(bytes[offset ..< offset + size], flags: flags)
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

/// The phone-shaped window: the screen fills it, with the phone's own rounded corners.
@MainActor
final class MirrorWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view = MirrorView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let closed: () -> Void
    private var closing = false

    var message: String? {
        didSet {
            label.stringValue = message ?? ""
            label.isHidden = message == nil
        }
    }

    var videoSize = CGSize(width: 1080, height: 2336) {
        didSet {
            view.videoSize = videoSize
            window.contentAspectRatio = videoSize
            fit()
        }
    }

    init(closed: @escaping () -> Void) {
        self.closed = closed
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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
        window.contentAspectRatio = videoSize
        window.contentView = view
        window.collectionBehavior = [.fullScreenNone]

        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        let home = button("house.fill", help: "Home (⌘1)") { [weak self] in self?.view.send?(Data([5])) }
        let back = button("chevron.backward", help: "Back (⌘[)") { [weak self] in self?.view.send?(Data([6])) }
        let stack = NSStackView(views: [back, home])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        stack.frame = NSRect(x: 0, y: 0, width: 68, height: 28)
        accessory.view = stack
        window.addTitlebarAccessoryViewController(accessory)
        fit()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func close() {
        closing = true
        window.close()
    }

    /// About three quarters of the screen's height, like iPhone Mirroring.
    private func fit() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let height = min(screen.visibleFrame.height * 0.78, 900)
        let width = height * videoSize.width / videoSize.height
        var frame = window.frame
        let center = frame.width > 1 ? CGPoint(x: frame.midX, y: frame.midY) : CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        frame.size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
        frame.origin = CGPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        window.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        if !closing { closed() }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }
}

private final class ClosureButton: NSButton {
    private let run: () -> Void
    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// The phone's screen. Clicks and drags are touches; scrolling scrolls; typing types.
final class MirrorView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    var renderer: AVSampleBufferVideoRenderer { display.sampleBufferRenderer }
    var send: ((Data) -> Void)?
    var videoSize = CGSize(width: 1080, height: 2336) { didSet { needsLayout = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = bounds
        // The phone's own corner (113 px on a 1080 px wide screen).
        layer?.cornerRadius = bounds.width * 0.105
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
