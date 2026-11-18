import CryptoKit
import Foundation

/// Islet Link: the wire format shared with the Android app (`Android/…/link/Wire.kt`).
/// Change both sides together; `Tests/IsletCoreTests/link-vectors.json` pins the crypto.
///
/// Every frame on the stream (TCP over Wi-Fi or USB, or a Bluetooth L2CAP channel) is a
/// 4-byte big-endian length and that many bytes. Before the handshake the bytes are a
/// plain message; after it they are AES-GCM sealed, each direction with its own key and a
/// counter nonce, so nothing on the network can read, change, replay or reorder them.
///
/// A message is a 4-byte big-endian header length, a JSON object (`"t"` names it), then
/// an optional binary body (artwork, an icon, a file chunk).
public enum Link {
    public static let port: UInt16 = 47480
    public static let bonjourType = "_islet-link._tcp"
    public static let version = 1
    /// Upper bound on one frame, so a broken peer can't make us allocate gigabytes.
    public static let maxFrame = 4 << 20
    /// File chunks: big enough to keep a link busy, small enough to interleave controls.
    public static let chunkSize = 512 << 10
}

/// One message: a JSON header and an optional binary body.
public struct LinkMessage: Sendable, Equatable {
    public let header: Data
    public let body: Data

    public init(header: Data, body: Data = Data()) {
        self.header = header
        self.body = body
    }

    /// `fields` must be JSON-encodable (strings, numbers, bools, arrays, dictionaries).
    public init(_ type: String, _ fields: [String: Any] = [:], body: Data = Data()) {
        var all = fields
        all["t"] = type
        self.header = (try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.body = body
    }

    public var fields: [String: Any] {
        (try? JSONSerialization.jsonObject(with: header)) as? [String: Any] ?? [:]
    }

    public var type: String { fields["t"] as? String ?? "" }

    public func encoded() -> Data {
        var out = Data(capacity: 4 + header.count + body.count)
        out.appendBigEndian(UInt32(header.count))
        out.append(header)
        out.append(body)
        return out
    }

    public static func decode(_ data: Data) -> LinkMessage? {
        guard data.count >= 4 else { return nil }
        let length = Int(data.readBigEndianUInt32(at: data.startIndex))
        let start = data.startIndex + 4
        guard length <= data.count - 4 else { return nil }
        return LinkMessage(header: Data(data[start ..< start + length]), body: Data(data[(start + length)...]))
    }
}

/// Splits a byte stream into frames.
public struct LinkFrameReader: Sendable {
    private var buffer = Data()
    public private(set) var failed = false

    public init() {}

    /// Adds received bytes; returns every complete frame. A frame over `Link.maxFrame`
    /// marks the stream as failed (the caller drops the connection).
    public mutating func push(_ bytes: Data) -> [Data] {
        guard !failed else { return [] }
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = Int(buffer.readBigEndianUInt32(at: buffer.startIndex))
            guard length <= Link.maxFrame else { failed = true; return frames }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex + 4
            frames.append(Data(buffer[start ..< start + length]))
            buffer = Data(buffer[(start + length)...])
        }
        return frames
    }

    public static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        out.appendBigEndian(UInt32(payload.count))
        out.append(payload)
        return out
    }
}

/// Pairing and session keys.
public enum LinkCrypto {
    public struct Pairing: Sendable, Equatable {
        /// The long-term key both sides keep for this pair.
        public let secret: Data
        /// Six digits both screens show; matching codes mean nobody sits in between.
        public let code: String
    }

    /// From an ECDH (P-256) shared secret and both public keys (X9.63, 65 bytes each).
    public static func pairing(shared: Data, macKey: Data, phoneKey: Data) -> Pairing {
        let salt = macKey + phoneKey
        let secret = hkdf(shared, salt: salt, info: "islet-link pair v1", count: 32)
        let sas = hkdf(shared, salt: salt, info: "islet-link code v1", count: 4)
        let number = sas.readBigEndianUInt32(at: sas.startIndex) % 1_000_000
        return Pairing(secret: secret, code: String(format: "%06u", number))
    }

    /// Per-connection keys from the pair's secret and both hello nonces.
    public static func session(secret: Data, macNonce: Data, phoneNonce: Data) -> (macToPhone: Data, phoneToMac: Data) {
        let keys = hkdf(secret, salt: macNonce + phoneNonce, info: "islet-link session v1", count: 64)
        return (Data(keys.prefix(32)), Data(keys.suffix(32)))
    }

    static func hkdf(_ input: Data, salt: Data, info: String, count: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: input), salt: salt,
                                          info: Data(info.utf8), outputByteCount: count)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

/// One direction of an encrypted stream: AES-256-GCM, nonce = 4 zero bytes + 8-byte counter.
public struct LinkCipher: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    public init(key: Data) { self.key = SymmetricKey(data: key) }

    public mutating func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce())
        counter += 1
        return box.ciphertext + box.tag
    }

    /// The counter only moves on success, so a frame that fails (a plain one arriving
    /// before the other side switched to encryption) can still be read another way.
    public mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw CryptoKitError.authenticationFailure }
        let box = try AES.GCM.SealedBox(nonce: nonce(), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let plain = try AES.GCM.open(box, using: key)
        counter += 1
        return plain
    }

    private func nonce() throws -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        bytes.appendBigEndian(counter)
        return try AES.GCM.Nonce(data: bytes)
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndianUInt32(at index: Index) -> UInt32 {
        self[index ..< index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
