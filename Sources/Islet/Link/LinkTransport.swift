import CoreBluetooth
import Foundation
import IOKit
import IOKit.usb
import IsletCore
import Network

/// How a phone is connected right now. Order is preference: the first live one carries
/// the traffic (USB is the fastest and needs no radio, Bluetooth the slowest).
enum LinkTransport: String, Comparable, Sendable {
    case usb, wifi, bluetooth

    var rank: Int { switch self { case .usb: 0; case .wifi: 1; case .bluetooth: 2 } }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    var label: String { switch self { case .usb: "USB"; case .wifi: "Wi-Fi"; case .bluetooth: "Bluetooth" } }
    var symbol: String { switch self { case .usb: "cable.connector"; case .wifi: "wifi"; case .bluetooth: "dot.radiowaves.left.and.right" } }
}

/// A byte stream to one phone. Callbacks arrive on the main actor.
@MainActor
protocol LinkPipe: AnyObject {
    var transport: LinkTransport { get }
    var onBytes: (Data) -> Void { get set }
    var onClose: () -> Void { get set }
    func start()
    /// `done` runs once the bytes are handed to the system (used to pace file chunks).
    func write(_ data: Data, done: @escaping @MainActor @Sendable () -> Void)
    func close()
}

// MARK: - TCP (Wi-Fi, and USB through `adb reverse`)

/// Listens on `Link.port` and announces itself over Bonjour so the phone finds it on Wi-Fi.
/// A connection from 127.0.0.1 can only come through `adb reverse`, so it is the USB link.
@MainActor
final class LinkTCPListener {
    private var listener: NWListener?
    var onPipe: (LinkPipe) -> Void = { _ in }
    /// A browser on the phone asking for the app (`http://<mac>:47480/IsletLink.apk`).
    var onHTTP: (NWConnection) -> Void = { _ in }
    private(set) var problem: String?

    func start(name: String, macID: String) {
        guard listener == nil else { return }
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 20
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Link.port)!)
            listener.service = NWListener.Service(name: name, type: Link.bonjourType,
                                                  txtRecord: NWTXTRecord(["id": macID, "v": "\(Link.version)"]))
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case let .failed(error) = state { self?.problem = error.localizedDescription }
                    if case .ready = state { self?.problem = nil }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        var loopback = false
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case .ipv4(let address): loopback = address.isLoopback
            case .ipv6(let address): loopback = address.isLoopback
            default: break
            }
        }
        let pipe = LinkTCPPipe(connection: connection, transport: loopback ? .usb : .wifi)
        pipe.onHTTP = { [weak self] in self?.onHTTP(connection) }
        onPipe(pipe)
    }
}

@MainActor
final class LinkTCPPipe: LinkPipe {
    let transport: LinkTransport
    var onBytes: (Data) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// The first bytes were "GET ": a web browser, not the app.
    var onHTTP: () -> Void = {}
    private let connection: NWConnection
    private var closed = false
    private var sniffed = false

    init(connection: NWConnection, transport: LinkTransport) {
        self.connection = connection
        self.transport = transport
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    if !self.sniffed {
                        self.sniffed = true
                        if data.starts(with: Data("GET ".utf8)) {
                            // Hand the socket over; the browser gets the APK.
                            self.closed = true
                            self.connection.stateUpdateHandler = nil
                            self.onHTTP()
                            return
                        }
                    }
                    self.onBytes(data)
                }
                if complete || error != nil { self.finish() } else { self.receive() }
            }
        }
    }

    func write(_ data: Data, done: @escaping @MainActor @Sendable () -> Void) {
        guard !closed else { return }
        // The connection runs on the main queue, so its completions do too.
        connection.send(content: data, completion: .contentProcessed { _ in
            MainActor.assumeIsolated { done() }
        })
    }

    func close() {
        guard !closed else { return }
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose()
    }
}

// MARK: - Bluetooth (BLE L2CAP channel)

/// When there is no Wi-Fi or USB link, the Mac advertises a small BLE service whose one
/// characteristic holds an L2CAP channel number; the phone opens that channel and speaks
/// the same framed protocol over it. Slow (tens of KB/s), but enough for notifications,
/// battery, music and the remote. Advertising stops whenever a faster link is up.
@MainActor
final class LinkBluetooth: NSObject {
    static let service = CBUUID(string: "6E1A0001-6C69-4E6B-8A1E-15E7E0000001")
    static let psmCharacteristic = CBUUID(string: "6E1A0002-6C69-4E6B-8A1E-15E7E0000001")

    var onPipe: (LinkPipe) -> Void = { _ in }
    private var manager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    private var wanted = false
    private(set) var unauthorized = false

    /// Advertise (or stop). Creating the manager the first time asks for Bluetooth access.
    func setAdvertising(_ on: Bool) {
        wanted = on
        if on, manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main)
            return
        }
        apply()
    }

    private func apply() {
        guard let manager, manager.state == .poweredOn else { return }
        if wanted {
            if psm == nil {
                manager.publishL2CAPChannel(withEncryption: false)
            } else if !manager.isAdvertising {
                manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service],
                                          CBAdvertisementDataLocalNameKey: "Islet"])
            }
        } else if manager.isAdvertising {
            manager.stopAdvertising()
        }
    }

    private func published(_ psm: CBL2CAPPSM) {
        self.psm = psm
        var value = Data()
        value.append(UInt8(psm >> 8))
        value.append(UInt8(psm & 0xFF))
        let characteristic = CBMutableCharacteristic(type: Self.psmCharacteristic, properties: [.read],
                                                     value: value, permissions: [.readable])
        let service = CBMutableService(type: Self.service, primary: true)
        service.characteristics = [characteristic]
        manager?.removeAllServices()
        manager?.add(service)
        apply()
    }
}

extension LinkBluetooth: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        MainActor.assumeIsolated {
            unauthorized = state == .unauthorized
            if state != .poweredOn { psm = nil }
            apply()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        MainActor.assumeIsolated {
            if error == nil { published(PSM) } else { Log.media.error("Link: L2CAP publish failed") }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else { return }
        nonisolated(unsafe) let opened = channel
        MainActor.assumeIsolated { onPipe(LinkStreamPipe(channel: opened)) }
    }
}

/// An L2CAP channel's input and output streams as a pipe.
@MainActor
final class LinkStreamPipe: NSObject, LinkPipe, StreamDelegate {
    let transport = LinkTransport.bluetooth
    var onBytes: (Data) -> Void = { _ in }
    var onClose: () -> Void = {}
    private let channel: CBL2CAPChannel
    private var pending: [(Data, @MainActor @Sendable () -> Void)] = []
    private var offset = 0
    private var closed = false

    init(channel: CBL2CAPChannel) {
        self.channel = channel
    }

    func start() {
        for case let stream? in [channel.inputStream as Stream?, channel.outputStream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
    }

    nonisolated func stream(_ stream: Stream, handle event: Stream.Event) {
        nonisolated(unsafe) let stream = stream
        MainActor.assumeIsolated {
            switch event {
            case .hasBytesAvailable: read()
            case .hasSpaceAvailable: flush()
            case .errorOccurred, .endEncountered: close()
            default: break
            }
        }
        _ = stream
    }

    private func read() {
        guard let input = channel.inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            onBytes(Data(buffer[0 ..< count]))
        }
    }

    func write(_ data: Data, done: @escaping @MainActor @Sendable () -> Void) {
        guard !closed else { return }
        pending.append((data, done))
        flush()
    }

    private func flush() {
        guard let output = channel.outputStream else { return }
        while let (data, done) = pending.first, output.hasSpaceAvailable {
            let written = data.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress! + offset, maxLength: data.count - offset)
            }
            guard written > 0 else { break }
            offset += written
            if offset == data.count {
                pending.removeFirst()
                offset = 0
                done()
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        channel.inputStream?.close()
        channel.outputStream?.close()
        pending = []
        onClose()
    }
}

// MARK: - USB (adb reverse)

/// Watches for an Android phone with USB debugging plugged in, then runs
/// `adb reverse tcp:47480 tcp:47480` so the app reaches the Mac at 127.0.0.1 over the
/// cable. Matching on the ADB interface (class 255/66/1) means keyboards, drives and
/// iPhones never wake adb. Needs Android platform-tools; without them USB is just off.
@MainActor
final class LinkUSB {
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var retryTask: Task<Void, Never>?
    private(set) var lastResult: String?
    /// Set when `adb reverse` succeeds; the phone then connects through 127.0.0.1.
    private(set) var forwarding = false

    static var adbPath: String? {
        let candidates = [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        guard port == nil, Self.adbPath != nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        // Plain property matching: USB's own class matching ignores vendor-specific
        // class 255 unless a vendor ID is given too, and ADB phones come from every vendor.
        match["IOPropertyMatch"] = ["bInterfaceClass": 255, "bInterfaceSubClass": 66, "bInterfaceProtocol": 1]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, match, { context, iterator in
            // Drain the iterator to re-arm the notification.
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            guard let context else { return }
            let usb = Unmanaged<LinkUSB>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { usb.attached() }
        }, context, &iterator)
        self.port = port
        guard result == KERN_SUCCESS else { return }
        var found = false
        while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry); found = true }
        if found { attached() }
    }

    func stop() {
        retryTask?.cancel()
        if iterator != 0 { IOObjectRelease(iterator); iterator = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    /// A phone appeared: the user may still be tapping "Allow USB debugging", so retry for a minute.
    private func attached() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            for _ in 0 ..< 20 {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                if await self.reverse() { await self.prepareWireless(); return }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func reverse() async -> Bool {
        guard let adb = Self.adbPath else { return false }
        // Plugged in, the cable is the one connection: drop any Wi-Fi one (it would make adb ambiguous).
        _ = await Self.run(adb, ["disconnect"])
        let output = await Self.run(adb, ["reverse", "tcp:\(Link.port)", "tcp:\(Link.port)"])
        forwarding = output.status == 0
        lastResult = output.text
        return forwarding
    }

    /// Where wireless Phone Mirroring finds the phone: its Wi-Fi address, saved while it was plugged in.
    static let wirelessPort = 5555
    static var wirelessHost: String? { UserDefaults.standard.string(forKey: "mirrorWirelessHost") }

    /// Lets Phone Mirroring work over Wi-Fi later: adb listens on the network too (until the
    /// phone restarts; plugging it in turns it back on). The phone still asks before trusting a
    /// new computer, as over USB.
    private func prepareWireless() async {
        guard let adb = Self.adbPath else { return }
        let address = await Self.run(adb, ["shell", "ip", "-f", "inet", "addr", "show", "wlan0"]).text
        if let match = address.firstMatch(of: /inet (\d+\.\d+\.\d+\.\d+)\//) {
            UserDefaults.standard.set(String(match.1), forKey: "mirrorWirelessHost")
        }
        let port = await Self.run(adb, ["shell", "getprop", "service.adb.tcp.port"]).text
        guard port != "\(Self.wirelessPort)" else { return }
        _ = await Self.run(adb, ["tcpip", "\(Self.wirelessPort)"])
        // adb restarts on the phone, which drops the cable's reverse port: set it up again.
        for _ in 0 ..< 10 {
            try? await Task.sleep(for: .seconds(1))
            if await reverse() { return }
        }
    }

    /// Installs the app over USB (Settings → Phone).
    func install(apk: URL) async -> (ok: Bool, message: String) {
        guard let adb = Self.adbPath else { return (false, "Android platform-tools aren't installed.") }
        let output = await Self.run(adb, ["install", "-r", apk.path])
        if output.status == 0 { _ = await reverse() }
        return (output.status == 0, output.status == 0 ? "Installed" : output.text)
    }

    var phoneAttached: Bool { forwarding }

    nonisolated static func run(_ tool: String, _ arguments: [String]) async -> (status: Int32, text: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try process.run() } catch { continuation.resume(returning: (-1, error.localizedDescription)) }
        }
    }
}
