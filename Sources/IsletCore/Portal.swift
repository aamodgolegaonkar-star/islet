import CryptoKit
import Foundation

/// The pure pieces of Portal (iPhone ⇄ Mac over the local network): reading HTTP requests,
/// making received file names safe, and pairing secrets. Kept here, away from sockets and
/// UI, because every one of them stands between the network and the disk.
public enum Portal {
    /// The fixed port, so a Home Screen web app saved on the iPhone keeps working.
    public static let port: UInt16 = 47474
    /// Largest request head (request line plus headers) accepted.
    public static let maxHeadBytes = 16 * 1024
    /// Largest file accepted in one request (a long 4K video fits).
    public static let maxFileBytes: Int64 = 8 * 1024 * 1024 * 1024
    /// Largest text or link accepted.
    public static let maxTextBytes = 1024 * 1024
    /// How long a QR pairing code works.
    public static let pairingLifetime: TimeInterval = 5 * 60
}

// MARK: - HTTP

/// A parsed request head. The body follows it on the connection; `contentLength` says how much.
public struct PortalRequestHead: Equatable, Sendable {
    public let method: String
    /// The path without its query, percent-decoded.
    public let path: String
    public let query: [String: String]
    /// Header names lowercased.
    public let headers: [String: String]
    public let contentLength: Int64

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public enum ParseResult: Equatable, Sendable {
        /// More bytes are needed before the head is complete.
        case incomplete
        /// The head and how many bytes of `data` it used (the body starts there).
        case complete(PortalRequestHead, headLength: Int)
        case invalid
    }

    /// Parses the head at the start of `data`, if it has all arrived.
    public static func parse(_ data: Data) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > Portal.maxHeadBytes ? .invalid : .incomplete
        }
        let headLength = end.upperBound - data.startIndex
        guard headLength <= Portal.maxHeadBytes,
              let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              let components = URLComponents(string: String(requestLine[1])),
              requestLine[1].hasPrefix("/") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { return .invalid }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // No chunked uploads: every client here (the page, Shortcuts) sends a length.
        if headers["transfer-encoding"] != nil { return .invalid }
        let length: Int64
        if let value = headers["content-length"] {
            guard let parsed = Int64(value), parsed >= 0 else { return .invalid }
            length = parsed
        } else {
            length = 0
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let head = PortalRequestHead(method: String(requestLine[0]), path: components.path,
                                     query: query, headers: headers, contentLength: length)
        return .complete(head, headLength: headLength)
    }
}

/// A response's bytes: status line, headers, then the body.
public func portalResponseHead(status: Int, reason: String, contentType: String, length: Int64,
                               extra: [String: String] = [:]) -> Data {
    var text = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\n"
    text += "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
    for (name, value) in extra.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
    return Data((text + "\r\n").utf8)
}

// MARK: - File names

public enum PortalFilename {
    /// A name that is safe to create inside the save folder: no folders, no hidden or
    /// special names, no control characters, a sane length. Falls back to `fallback`.
    public static func sanitize(_ raw: String, fallback: String = "Portal Item") -> String {
        // Only the last path component, whichever separator the sender used.
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        var name = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = fallback }
        // Keep the extension when shortening.
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var short = ""
            for character in stem where (short + String(character)).utf8.count < 180 { short.append(character) }
            name = ext.isEmpty || ext.utf8.count > 16 ? short : "\(short).\(ext)"
        }
        return name
    }

    /// `name` inside `folder`, numbered ("Photo 2.jpg") if that file already exists.
    public static func unique(_ name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        let first = folder.appending(path: name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for number in 2... {
            let candidate = folder.appending(path: ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !exists(candidate) { return candidate }
        }
        return first
    }
}

// MARK: - Secrets

public enum PortalSecret {
    /// A new random secret (256 bits), URL-safe.
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What is stored for a paired phone: the hash, never the token itself.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `token` matches a stored hash, comparing in constant time.
    public static func matches(_ token: String, hash stored: String) -> Bool {
        let computed = Array(hash(token).utf8)
        let expected = Array(stored.utf8)
        guard computed.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in computed.indices { difference |= computed[index] ^ expected[index] }
        return difference == 0
    }
}

/// The QR code's one-time pairing code: good once, for a few minutes.
public struct PortalPairingCode: Sendable {
    public let code: String
    public let expires: Date
    private(set) public var used = false

    public init(now: Date = Date()) {
        code = PortalSecret.make()
        expires = now.addingTimeInterval(Portal.pairingLifetime)
    }

    /// Accepts `candidate` once, before it expires.
    public mutating func redeem(_ candidate: String, now: Date = Date()) -> Bool {
        guard !used, now < expires, PortalSecret.matches(candidate, hash: PortalSecret.hash(code)) else { return false }
        used = true
        return true
    }
}

/// Only web links are ever opened from a phone; anything else is just copied.
public func portalOpenableLink(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false
    else { return nil }
    return url
}
