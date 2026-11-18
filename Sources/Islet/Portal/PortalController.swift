import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import IsletCore
import SystemConfiguration
import UniformTypeIdentifiers

/// Portal on the Mac: runs the server while the setting is on, pairs phones from a QR
/// code, saves what arrives (and shows it coming through in the island), and queues what
/// is dragged to the screen's right edge for the phone to collect.
@MainActor
@Observable
final class PortalController {
    private(set) var devices: [PortalDevice] = []
    /// The address in the pairing QR code, while Settings is showing it.
    private(set) var pairingURL: URL?
    /// The code on show is for an Android phone (it gets the Mac's IP address).
    private(set) var pairingAndroid = false
    /// Why the server isn't running, if it failed.
    private(set) var problem: String?
    var isRunning: Bool { server != nil && problem == nil }

    @ObservationIgnored let settings: AppSettings
    /// Islet Link, when an Android phone is connected: true if it took the items.
    @ObservationIgnored var sendThroughLink: (([URL], String?) -> Bool)?
    @ObservationIgnored private weak var island: IslandController?
    @ObservationIgnored private var server: PortalServer?
    @ObservationIgnored private lazy var edge = PortalEdge(controller: self)
    @ObservationIgnored private var devicesFile: URL { settings.supportDirectory.appending(path: "portal-devices.json") }
    /// Items wait this long for the phone to collect them.
    private static let outboxLifetime: TimeInterval = 30 * 60

    init(settings: AppSettings, island: IslandController) {
        self.settings = settings
        self.island = island
        devices = (try? JSONDecoder().decode([PortalDevice].self, from: Data(contentsOf: devicesFile))) ?? []
    }

    func start() { follow() }

    /// Keeps the server and the edge in step with the settings; re-runs when they change.
    private func follow() {
        let (enabled, effect, edgeOn) = withObservationTracking {
            (settings.portalEnabled, settings.portalEffect, settings.portalEdgeSend)
        } onChange: {
            Task { @MainActor [weak self] in self?.follow() }
        }
        if enabled, server == nil { startServer() }
        if !enabled, server != nil { stopServer() }
        let style = effect.rawValue
        server?.effect.withLock { $0 = style }
        edge.setEnabled(enabled && edgeOn)
    }

    private func startServer() {
        problem = nil
        let server = PortalServer(
            assets: .init(page: Data(PortalPage.html.utf8), icon: Self.iconPNG()),
            onDelivery: { delivery in Task { @MainActor [weak self] in self?.deliver(delivery) } },
            onPaired: { device in Task { @MainActor [weak self] in self?.paired(device) } },
            onState: { problem in Task { @MainActor [weak self] in self?.problem = problem } })
        let known = devices, effect = settings.portalEffect.rawValue
        server.onIncoming = { name, progress in
            Task { @MainActor [weak self] in self?.edge.incoming(from: name, progress: progress) }
        }
        server.devices.withLock { $0 = known }
        server.effect.withLock { $0 = effect }
        server.start()
        self.server = server
        Log.media.notice("Portal listening on port \(Portal.port)")
    }

    private func stopServer() {
        server?.stop()
        server = nil
        pairingURL = nil
        Log.media.notice("Portal stopped")
    }

    // MARK: - Pairing

    /// A fresh one-time code and the address the QR code opens on the phone.
    /// Android often can't look up `.local` names, so its code carries the Mac's IP address
    /// instead (pair again if that changes); iPhones get the Bonjour name, which never does.
    func beginPairing(android: Bool = false) {
        guard let server else { return }
        let host = android ? (Self.wifiAddress ?? Self.localHostName) : Self.localHostName
        let code = PortalPairingCode()
        server.pairing.withLock { $0 = code }
        pairingAndroid = android
        pairingURL = URL(string: "http://\(host):\(Portal.port)/?pair=\(code.code)")
    }

    func endPairing() {
        server?.pairing.withLock { $0 = nil }
        pairingURL = nil
    }

    private func paired(_ device: PortalDevice) {
        if !devices.contains(where: { $0.id == device.id }) { devices.append(device) }
        save()
        endPairing()
        island?.showPortal(PortalArrival(direction: .received, title: "\(device.name) paired",
                                         detail: "Portal is ready", preview: nil, symbol: "iphone.gen3",
                                         effect: settings.portalEffect))
        hapticBurst()
    }

    func forget(_ device: PortalDevice) {
        devices.removeAll { $0.id == device.id }
        server?.devices.withLock { $0.removeAll { $0.id == device.id } }
        save()
    }

    /// Whether a paired phone has its Portal page open (it checks in every few seconds).
    var phoneIsListening: Bool {
        guard let server else { return false }
        let recent = Date().addingTimeInterval(-15)
        return server.lastSeen.withLock { $0.values.contains { $0 > recent } }
    }

    var hasDevices: Bool { !devices.isEmpty }

    private func save() {
        try? FileManager.default.createDirectory(at: settings.supportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(devices).write(to: devicesFile, options: [.atomic])
    }

    // MARK: - Receiving

    private func deliver(_ delivery: PortalDelivery) {
        switch delivery {
        case let .file(temporary, name, from):
            receiveFile(temporary, name: name, from: from)
        case let .text(text, from):
            receiveText(text, from: from)
        }
    }

    func receiveFile(_ temporary: URL, name: String, from device: String) {
        let folder = settings.portalSaveFolder
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = PortalFilename.unique(name, in: folder) { manager.fileExists(atPath: $0.path) }
        do {
            try manager.moveItem(at: temporary, to: destination)
        } catch {
            try? manager.removeItem(at: temporary)
            Log.media.error("Portal couldn't save \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let type = UTType(filenameExtension: destination.pathExtension)
        let kind = type?.conforms(to: .image) == true ? "Photo" : type?.conforms(to: .movie) == true ? "Video" : nil
        var afterwards = "Saved to \(folder.lastPathComponent)"
        switch settings.portalAfterReceive {
        case .shelf where settings.shelfEnabled:
            island?.model.shelf.add([destination])
            afterwards = "On the shelf"
        case .shelf, .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        case .open:
            NSWorkspace.shared.open(destination)
        case .nothing:
            break
        }
        arrive(title: kind ?? destination.lastPathComponent, detail: "From \(device) · \(afterwards)",
               preview: Self.preview(of: destination, type: type), symbol: "doc.fill")
    }

    func receiveText(_ text: String, from device: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let link = portalOpenableLink(text) {
            if settings.portalOpenLinks { NSWorkspace.shared.open(link) }
            arrive(title: link.host ?? "Link",
                   detail: "From \(device) · \(settings.portalOpenLinks ? "Opened and copied" : "Copied")",
                   preview: nil, symbol: "link")
        } else {
            arrive(title: String(text.prefix(40)), detail: "From \(device) · Copied", preview: nil, symbol: "text.quote")
        }
    }

    private func arrive(title: String, detail: String, preview: NSImage?, symbol: String) {
        if settings.portalShowEffect {
            island?.showPortal(PortalArrival(direction: .received, title: title, detail: detail, preview: preview,
                                             symbol: symbol, effect: settings.portalEffect))
        }
        hapticBurst()
    }

    // MARK: - Sending (the screen's right edge)

    /// Puts files, text or a link in the portal for the phone.
    func send(files: [URL], text: String?) {
        // An Android phone on Islet Link takes it straight away, at full quality.
        if sendThroughLink?(files, text) == true {
            hapticBurst()
            return
        }
        guard let server else { return }
        var queued: [PortalOutboxItem] = []
        for url in files where (try? url.checkResourceIsReachable()) == true {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            queued.append(PortalOutboxItem(id: UUID().uuidString, url: url, name: url.lastPathComponent, size: size, added: Date()))
        }
        if let text, !text.isEmpty, queued.isEmpty {
            // Text and links travel as a small file the phone can open.
            let isLink = portalOpenableLink(text) != nil
            let url = FileManager.default.temporaryDirectory.appending(path: "Portal \(UUID().uuidString.prefix(6)).txt")
            if (try? Data(text.utf8).write(to: url)) != nil {
                queued.append(PortalOutboxItem(id: UUID().uuidString, url: url, name: isLink ? "Link.txt" : "Text.txt",
                                               size: Int64(text.utf8.count), added: Date()))
            }
        }
        guard !queued.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Self.outboxLifetime), adding = queued
        server.outbox.withLock { items in
            items.removeAll { $0.added < cutoff }
            items.append(contentsOf: adding)
        }
        let first = queued[0]
        let title = queued.count > 1 ? "\(queued.count) items" : first.name
        let device = devices.last?.name ?? "your phone"
        island?.showPortal(PortalArrival(
            direction: .sent, title: title,
            detail: phoneIsListening ? "Sent to \(device)" : "Waiting for \(device) to open Portal",
            preview: Self.preview(of: first.url, type: UTType(filenameExtension: first.url.pathExtension)),
            symbol: "paperplane.fill", effect: settings.portalEffect))
        hapticBurst()
    }

    // MARK: - Preview

    /// Settings → Portal → Try It: a photo coming through, as it would from a phone.
    func demo(direction: PortalArrival.Direction = .received) {
        let photo = NSImage(size: NSSize(width: 120, height: 120), flipped: false) { rect in
            NSGradient(colors: [.systemPink, .systemOrange, .systemPurple])?.draw(in: rect, angle: -60)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: 70, y: 70, width: 24, height: 24)).fill()
            return true
        }
        island?.showPortal(PortalArrival(
            direction: direction, title: direction == .received ? "Photo" : "Holiday.jpg",
            detail: direction == .received ? "From your phone · On the shelf" : "Sent to your phone",
            preview: photo, symbol: "photo", effect: settings.portalEffect))
        hapticBurst()
    }

    /// Debug: the edge portal held open at `near` (0…1).
    func debugEdge(_ near: CGFloat) { edge.debugShow(near) }

    // MARK: - Feel and look

    /// Three quickening taps, like something landing.
    private func hapticBurst() {
        guard settings.portalHaptics else { return }
        Task { @MainActor in
            for delay in [0, 140, 230] {
                try? await Task.sleep(for: .milliseconds(delay))
                Haptics.detent()
            }
        }
    }

    func edgeTick() {
        guard settings.portalHaptics else { return }
        Haptics.detent()
    }

    /// A small thumbnail for photos, otherwise the file's icon.
    private static func preview(of url: URL, type: UTType?) -> NSImage? {
        if type?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 160,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary) {
            return NSImage(cgImage: image, size: .zero)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// The Mac's IPv4 address on Wi-Fi or Ethernet (`en…`), for phones that can't use Bonjour.
    static var wifiAddress: String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    /// The Mac's Bonjour name, which iPhones on the same network can reach.
    static var localHostName: String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : "\(name).local"
    }

    /// The pairing QR code.
    static func qrCode(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// The app icon as the phone's Home Screen icon.
    private static func iconPNG() -> Data {
        let size = NSSize(width: 180, height: 180)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            NSApp.applicationIconImage.draw(in: rect.insetBy(dx: 8, dy: 8))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
