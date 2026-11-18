import CryptoKit
import Foundation
import IsletCore

/// One connection to the phone app over one pipe: the handshake, then sealed messages.
///
/// Handshake (plain frames): both sides send `hello` {id, name, nonce}. The phone then
/// sends `auth` (it holds this Mac's pair secret) or `pair.request` {pub}. For `auth` the
/// Mac switches to encryption at once; a phone it doesn't know gets `pair.needed`. For a
/// pairing the Mac answers `pair.key` {pub}, both screens show the same six digits, and
/// once the user accepts on the Mac it sends a sealed `pair.ok`; `pair.no` if declined.
///
/// Outgoing messages wait in two queues: controls first, file chunks when the link is
/// free, so a big transfer never holds up a tap on the remote. Messages are sealed as
/// they go onto the wire, which keeps the counter nonces in wire order.
@MainActor
final class LinkSession {
    enum Phase: Equatable { case hello, pairing(code: String), ready, closed }

    let pipe: LinkPipe
    let macID: String
    let macName: String
    private(set) var phase: Phase = .hello
    private(set) var phoneID = ""
    private(set) var phoneName = "Phone"
    private(set) var phoneModel = ""
    private(set) var lastHeard = Date()
    var transport: LinkTransport { pipe.transport }

    /// The pair secret for a phone id, if it is paired with this Mac.
    var secretFor: (String) -> Data? = { _ in nil }
    var onPairRequest: (LinkSession, String) -> Void = { _, _ in }
    var onPaired: (LinkSession, Data) -> Void = { _, _ in }
    var onReady: (LinkSession) -> Void = { _ in }
    var onMessage: (LinkSession, LinkMessage) -> Void = { _, _ in }
    var onClose: (LinkSession) -> Void = { _ in }
    var onFile: (LinkSession, IncomingFile) -> Void = { _, _ in }
    var onProgress: (LinkSession) -> Void = { _ in }

    private var reader = LinkFrameReader()
    private var sealer: LinkCipher?
    private var opener: LinkCipher?
    private let macNonce = LinkCrypto.randomNonce()
    private var phoneNonce = Data()
    private var pairingKey: P256.KeyAgreement.PrivateKey?
    private var pairing: LinkCrypto.Pairing?

    private var controls: [LinkMessage] = []
    private(set) var outgoing: [OutgoingFile] = []
    private(set) var incoming: [String: IncomingFile] = [:]
    private var inFlight = 0
    private static let maxInFlight = 6

    init(pipe: LinkPipe, macID: String, macName: String) {
        self.pipe = pipe
        self.macID = macID
        self.macName = macName
    }

    func start() {
        pipe.onBytes = { [weak self] in self?.received($0) }
        pipe.onClose = { [weak self] in self?.closed() }
        pipe.start()
        writePlain(LinkMessage("hello", ["v": Link.version, "id": macID, "name": macName, "kind": "mac",
                                         "nonce": macNonce.base64EncodedString()]))
    }

    func close() { pipe.close() }

    // MARK: - Pairing

    /// The user accepted (or declined) the code shown on the Mac.
    func answerPairing(_ accept: Bool) {
        guard case .pairing = phase, let pairing else { return }
        if accept {
            startEncryption(secret: pairing.secret)
            onPaired(self, pairing.secret)
            send(LinkMessage("pair.ok"))
            becomeReady()
        } else {
            writePlain(LinkMessage("pair.no"))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.close()
            }
        }
    }

    // MARK: - Sending

    func send(_ message: LinkMessage) {
        guard sealer != nil, phase != .closed else { return }
        controls.append(message)
        pump()
    }

    /// Queues a file; its bytes go out unchanged, in order, chunk by chunk.
    @discardableResult
    func send(file url: URL, name: String? = nil) -> OutgoingFile? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        let file = OutgoingFile(id: UUID().uuidString, name: name ?? url.lastPathComponent, size: Int64(size),
                                handle: handle, mime: Self.mime(for: url))
        outgoing.append(file)
        send(LinkMessage("file.begin", ["id": file.id, "name": file.name, "size": file.size, "mime": file.mime]))
        return file
    }

    func cancelFiles() {
        for file in outgoing { send(LinkMessage("file.cancel", ["id": file.id])) }
        outgoing.removeAll()
    }

    private func pump() {
        while inFlight < Self.maxInFlight, var sealer {
            let message: LinkMessage
            if !controls.isEmpty {
                message = controls.removeFirst()
            } else if let file = outgoing.first {
                let chunk = (try? file.handle.read(upToCount: Link.chunkSize)) ?? Data()
                if chunk.isEmpty {
                    outgoing.removeFirst()
                    try? file.handle.close()
                    message = LinkMessage("file.end", ["id": file.id, "size": file.sent])
                    file.done = true
                } else {
                    file.sent += Int64(chunk.count)
                    message = LinkMessage("file.chunk", ["id": file.id], body: chunk)
                }
                onProgress(self)
            } else {
                return
            }
            guard let sealed = try? sealer.seal(message.encoded()) else { return }
            self.sealer = sealer
            inFlight += 1
            pipe.write(LinkFrameReader.frame(sealed)) { [weak self] in
                guard let self else { return }
                self.inFlight -= 1
                self.pump()
            }
        }
    }

    private func writePlain(_ message: LinkMessage) {
        pipe.write(LinkFrameReader.frame(message.encoded())) {}
    }

    // MARK: - Receiving

    private func received(_ bytes: Data) {
        lastHeard = Date()
        for frame in reader.push(bytes) {
            guard phase != .closed else { return }
            if var opener {
                guard let plain = try? opener.open(frame), let message = LinkMessage.decode(plain) else {
                    Log.media.error("Link: a frame failed to open; closing")
                    return close()
                }
                self.opener = opener
                handle(message)
            } else if let message = LinkMessage.decode(frame) {
                handshake(message)
            }
        }
        if reader.failed { close() }
    }

    private func handshake(_ message: LinkMessage) {
        let fields = message.fields
        Log.media.notice("Link: handshake \(message.type, privacy: .public)")
        switch message.type {
        case "hello":
            phoneID = fields["id"] as? String ?? ""
            phoneName = fields["name"] as? String ?? "Phone"
            phoneModel = fields["model"] as? String ?? ""
            phoneNonce = Data(base64Encoded: fields["nonce"] as? String ?? "") ?? Data()
        case "auth":
            // Out of order (no hello yet): a broken connection, not a forgotten phone.
            guard phoneNonce.count == 32 else { return close() }
            guard let secret = secretFor(phoneID) else {
                writePlain(LinkMessage("pair.needed"))
                return
            }
            startEncryption(secret: secret)
            becomeReady()
        case "pair.request":
            guard phoneNonce.count == 32, let raw = Data(base64Encoded: fields["pub"] as? String ?? ""),
                  let phoneKey = try? P256.KeyAgreement.PublicKey(x963Representation: raw) else { return close() }
            let key = P256.KeyAgreement.PrivateKey()
            guard let shared = try? key.sharedSecretFromKeyAgreement(with: phoneKey) else { return close() }
            let secret = shared.withUnsafeBytes { Data($0) }
            let pairing = LinkCrypto.pairing(shared: secret, macKey: key.publicKey.x963Representation, phoneKey: raw)
            self.pairingKey = key
            self.pairing = pairing
            writePlain(LinkMessage("pair.key", ["pub": key.publicKey.x963Representation.base64EncodedString()]))
            phase = .pairing(code: pairing.code)
            onPairRequest(self, pairing.code)
        default:
            break
        }
    }

    private func startEncryption(secret: Data) {
        let keys = LinkCrypto.session(secret: secret, macNonce: macNonce, phoneNonce: phoneNonce)
        sealer = LinkCipher(key: keys.macToPhone)
        opener = LinkCipher(key: keys.phoneToMac)
    }

    private func becomeReady() {
        phase = .ready
        onReady(self)
    }

    private func handle(_ message: LinkMessage) {
        let fields = message.fields
        switch message.type {
        case "ping":
            send(LinkMessage("pong"))
        case "pong":
            break
        case "file.begin":
            guard let id = fields["id"] as? String else { return }
            let name = PortalFilename.sanitize(fields["name"] as? String ?? "File", fallback: "File")
            let url = FileManager.default.temporaryDirectory.appending(path: "IsletLink-\(id)")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            Log.media.notice("Link: receiving \(name, privacy: .public)")
            incoming[id] = IncomingFile(id: id, name: name, size: (fields["size"] as? NSNumber)?.int64Value ?? 0,
                                        url: url, handle: handle)
            onProgress(self)
        case "file.chunk":
            guard let id = fields["id"] as? String, let file = incoming[id] else { return }
            do {
                try file.handle.write(contentsOf: message.body)
                file.received += Int64(message.body.count)
            } catch {
                drop(id)
            }
            onProgress(self)
        case "file.end":
            guard let id = fields["id"] as? String, let file = incoming.removeValue(forKey: id) else { return }
            try? file.handle.close()
            // Every byte that was sent arrived (each chunk is authenticated, and in order).
            Log.media.notice("Link: \(file.name, privacy: .public) ended at \(file.received) of \(file.size) bytes")
            if file.received == file.size {
                onFile(self, file)
            } else {
                try? FileManager.default.removeItem(at: file.url)
            }
            onProgress(self)
        case "file.cancel":
            if let id = fields["id"] as? String {
                drop(id)
                if let index = outgoing.firstIndex(where: { $0.id == id }) {
                    try? outgoing[index].handle.close()
                    outgoing.remove(at: index)
                }
            }
            onProgress(self)
        default:
            onMessage(self, message)
        }
    }

    private func drop(_ id: String) {
        guard let file = incoming.removeValue(forKey: id) else { return }
        try? file.handle.close()
        try? FileManager.default.removeItem(at: file.url)
    }

    private func closed() {
        guard phase != .closed else { return }
        phase = .closed
        for id in incoming.keys { drop(id) }
        for file in outgoing { try? file.handle.close() }
        outgoing.removeAll()
        onClose(self)
    }

    static func mime(for url: URL) -> String {
        UTTypeLookup.mime(for: url.pathExtension) ?? "application/octet-stream"
    }
}

/// A file on its way to the phone.
@MainActor
final class OutgoingFile {
    let id: String
    let name: String
    let size: Int64
    let handle: FileHandle
    let mime: String
    var sent: Int64 = 0
    var done = false

    init(id: String, name: String, size: Int64, handle: FileHandle, mime: String) {
        self.id = id
        self.name = name
        self.size = size
        self.handle = handle
        self.mime = mime
    }
}

/// A file arriving from the phone, written straight to a temporary file.
@MainActor
final class IncomingFile {
    let id: String
    let name: String
    let size: Int64
    let url: URL
    let handle: FileHandle
    var received: Int64 = 0

    init(id: String, name: String, size: Int64, url: URL, handle: FileHandle) {
        self.id = id
        self.name = name
        self.size = size
        self.url = url
        self.handle = handle
    }
}

import UniformTypeIdentifiers

enum UTTypeLookup {
    static func mime(for pathExtension: String) -> String? {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType
    }
}
