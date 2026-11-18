import CryptoKit
import Foundation
import Testing
@testable import IsletCore

/// The Android app's `WireTest.kt` checks the same `link-vectors.json`, so both sides
/// agree on keys, codes and ciphertext byte for byte.
@Suite("Islet Link wire format")
struct LinkTests {
    static let vectors: [String: String] = {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "link-vectors.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: String] ?? [:]
    }()

    func hex(_ key: String) -> Data { Data(hexString: Self.vectors[key] ?? "") }

    @Test func pairingMatchesVectors() throws {
        let mac = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex("macPrivate"))
        let phone = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex("phonePrivate"))
        #expect(mac.publicKey.x963Representation == hex("macPublic"))
        #expect(phone.publicKey.x963Representation == hex("phonePublic"))
        let shared = try mac.sharedSecretFromKeyAgreement(with: phone.publicKey).withUnsafeBytes { Data($0) }
        #expect(shared == hex("shared"))
        let pairing = LinkCrypto.pairing(shared: shared, macKey: hex("macPublic"), phoneKey: hex("phonePublic"))
        #expect(pairing.secret == hex("secret"))
        #expect(pairing.code == Self.vectors["code"])
    }

    @Test func sessionAndCipherMatchVectors() throws {
        let keys = LinkCrypto.session(secret: hex("secret"), macNonce: hex("macNonce"), phoneNonce: hex("phoneNonce"))
        #expect(keys.macToPhone == hex("macToPhone"))
        #expect(keys.phoneToMac == hex("phoneToMac"))
        var seal = LinkCipher(key: keys.macToPhone)
        let first = try seal.seal(Data("hello".utf8))
        let second = try seal.seal(Data("hello".utf8))
        #expect(first == hex("sealed0"))
        #expect(second == hex("sealed1"))
        #expect(first != second)
        var open = LinkCipher(key: keys.macToPhone)
        #expect(try open.open(first) == Data("hello".utf8))
        #expect(try open.open(second) == Data("hello".utf8))
    }

    @Test func replayedOrTamperedFramesFail() throws {
        let key = Data(repeating: 7, count: 32)
        var seal = LinkCipher(key: key)
        let frame = try seal.seal(Data("x".utf8))
        var open = LinkCipher(key: key)
        _ = try open.open(frame)
        #expect(throws: (any Error).self) { try open.open(frame) }
        var tampered = frame
        tampered[tampered.startIndex] ^= 1
        var fresh = LinkCipher(key: key)
        #expect(throws: (any Error).self) { try fresh.open(tampered) }
    }

    @Test func messageRoundTripAndFraming() {
        let message = LinkMessage("media.state", ["title": "Song", "playing": true], body: Data([1, 2, 3]))
        let frame = LinkFrameReader.frame(message.encoded())
        var reader = LinkFrameReader()
        // Arrives in awkward pieces.
        #expect(reader.push(frame.prefix(3)).isEmpty)
        let frames = reader.push(frame.dropFirst(3) + frame)
        #expect(frames.count == 2)
        let decoded = LinkMessage.decode(frames[0])
        #expect(decoded?.type == "media.state")
        #expect(decoded?.fields["title"] as? String == "Song")
        #expect(decoded?.body == Data([1, 2, 3]))
        #expect(Self.vectors["message"] == message.encoded().hexString)
    }

    @Test func oversizedFrameFails() {
        var reader = LinkFrameReader()
        var bad = Data()
        bad.appendBigEndian(UInt32(Link.maxFrame + 1))
        _ = reader.push(bad)
        #expect(reader.failed)
    }
}

extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex, let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) {
            bytes.append(UInt8(hexString[index ..< next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
