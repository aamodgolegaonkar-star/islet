import Foundation

/// Parser for the TTML lyrics Apple Music serves. Word-timed ("syllable") lyrics put each
/// word or syllable in a timed `<span>`; line-timed lyrics only time each `<p>`.
///
///     <p begin="13.4" end="16.5"><span begin="13.4" end="13.7">I've</span> <span …>been</span></p>
///
/// Background vocals (`ttm:role="x-bg"`), translations and the `<head>` are left out.
public enum TTMLParser {
    public static func parse(_ ttml: String) -> [LyricLine] {
        guard let data = ttml.data(using: .utf8) else { return [] }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), !reader.untimed, !reader.entries.isEmpty else { return [] }
        return LRCParser.buildLines(reader.entries, duration: reader.duration)
    }

    /// "13.4", "1:02.345", "01:02:03.456" or "13.4s", in seconds.
    static func seconds(_ text: String?) -> TimeInterval? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix("s") { text.removeLast() }
        var total: TimeInterval = 0
        for part in text.split(separator: ":", omittingEmptySubsequences: false) {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var entries: [TimedEntry] = []
        var duration: TimeInterval?
        /// A line without times: the song's lyrics aren't synced at all.
        var untimed = false

        private var inBody = false
        private var line: (start: TimeInterval, end: TimeInterval?)?
        private var pieces: [TimedPiece] = []
        private var lineText = ""
        /// Open spans; true for one whose words are left out (background vocals).
        private var spans: [Bool] = []
        private var span: (start: TimeInterval, end: TimeInterval?, text: String)?
        /// Whitespace between spans: the next span starts a new word.
        private var spaceBefore = false

        private var skipping: Bool { spans.contains(true) }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch localName(name) {
            case "body":
                inBody = true
                duration = TTMLParser.seconds(attributes["dur"])
            case "p" where inBody:
                guard let start = TTMLParser.seconds(attributes["begin"]) else {
                    untimed = true
                    return
                }
                line = (start, TTMLParser.seconds(attributes["end"]))
                pieces = []
                lineText = ""
                spaceBefore = false
            case "span" where line != nil:
                let role = attributes.first { localName($0.key) == "role" }?.value ?? ""
                let skip = role.hasPrefix("x-bg") || role.hasPrefix("x-translation") || role.hasPrefix("x-roman")
                spans.append(skip)
                if !skipping, let start = TTMLParser.seconds(attributes["begin"]) {
                    span = (start, TTMLParser.seconds(attributes["end"]), "")
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard line != nil, !skipping else { return }
            if span != nil {
                span?.text += string
            } else {
                lineText += string
                if string.contains(where: \.isWhitespace) { spaceBefore = true }
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch localName(name) {
            case "span" where !spans.isEmpty:
                if let span, !skipping {
                    pieces.append(TimedPiece(start: span.start, end: span.end,
                                             text: (spaceBefore ? " " : "") + span.text))
                    lineText += (spaceBefore ? " " : "") + span.text
                    spaceBefore = false
                    self.span = nil
                }
                spans.removeLast()
            case "p":
                guard let line else { return }
                let text = lineText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                entries.append(TimedEntry(time: line.start, end: line.end, text: text, pieces: pieces))
                self.line = nil
            case "body":
                inBody = false
            default:
                break
            }
        }

        private func localName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }
    }
}

/// Word-timed lyrics from the Apple Music API, with the user's own tokens: a developer
/// token (paid Apple Developer Program) and a Music User Token (their subscription).
/// Without both, Islet uses LRCLIB alone.
///
/// Lyrics endpoints are not in Apple's public documentation and may change; any failure
/// here just falls back to LRCLIB. Results are cached like `LRCLIBClient`'s.
public actor AppleMusicLyricsClient {
    public enum Failure: Error, Equatable {
        /// Apple refused the tokens (expired, revoked, or no lyrics access).
        case unauthorized
        case badStatus(Int)
    }

    public struct Credentials: Sendable, Equatable {
        public var developerToken: String
        public var userToken: String
        public var storefront: String

        public init(developerToken: String, userToken: String, storefront: String) {
            self.developerToken = developerToken
            self.userToken = userToken
            self.storefront = storefront
        }
    }

    private struct CacheEntry: Codable {
        var ttml: String?
        var savedAt: Date
    }

    private let session: URLSession
    private let cacheDirectory: URL?
    private var memory: [String: String?] = [:]
    private let negativeTTL: TimeInterval = 24 * 60 * 60

    public init(session: URLSession = .shared, cacheDirectory: URL? = nil) {
        self.session = session
        self.cacheDirectory = cacheDirectory
    }

    /// The song's lyrics as TTML, or nil when Apple has none for it.
    public func ttml(title: String, artist: String, duration: TimeInterval, credentials: Credentials) async throws -> String? {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty,
              !artist.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let key = "am-" + LRCLIBClient.cacheKey(title: title, artist: artist, album: credentials.storefront, duration: duration)
        if let cached = memory[key] { return cached }
        if let cached = readDisk(key) {
            memory[key] = .some(cached.ttml)
            return cached.ttml
        }

        var ttml: String?
        if let id = try await songID(title: title, artist: artist, duration: duration, credentials: credentials) {
            // Word timing first; plain "lyrics" may still be timed by line.
            ttml = try await lyrics(id: id, kind: "syllable-lyrics", credentials: credentials)
            if ttml == nil { ttml = try await lyrics(id: id, kind: "lyrics", credentials: credentials) }
        }
        memory[key] = .some(ttml)
        writeDisk(key, CacheEntry(ttml: ttml, savedAt: Date()))
        return ttml
    }

    // MARK: - Requests

    private struct Search: Decodable {
        struct Results: Decodable { var songs: Songs? }
        struct Songs: Decodable { var data: [Song] }
        var results: Results
    }

    struct Song: Decodable {
        struct Attributes: Decodable {
            var name: String?
            var artistName: String?
            var durationInMillis: Double?
        }
        var id: String
        var attributes: Attributes?
    }

    private struct LyricsResponse: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable { var ttml: String? }
            var attributes: Attributes?
        }
        var data: [Item]
    }

    private func songID(title: String, artist: String, duration: TimeInterval, credentials: Credentials) async throws -> String? {
        let clean = MusicText.lyricsTitle(title)
        let items = [
            URLQueryItem(name: "term", value: "\(clean) \(MusicText.primaryArtist(artist))"),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let search = try await fetch("search", items, credentials, as: Search.self) else { return nil }
        return Self.bestMatch(search.results.songs?.data ?? [], title: clean, artist: artist, duration: duration)
    }

    private func lyrics(id: String, kind: String, credentials: Credentials) async throws -> String? {
        let response = try await fetch("songs/\(id)/\(kind)", [], credentials, as: LyricsResponse.self)
        return response?.data.first?.attributes?.ttml.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func fetch<T: Decodable>(_ path: String, _ items: [URLQueryItem], _ credentials: Credentials,
                                     as type: T.Type) async throws -> T? {
        let storefront = credentials.storefront.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "us"
        var components = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(storefront)/\(path)")!
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer \(credentials.developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.userToken, forHTTPHeaderField: "Music-User-Token")
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try? JSONDecoder().decode(T.self, from: data)
        case 204, 400, 404: return nil
        case 401, 403: throw Failure.unauthorized
        case let status: throw Failure.badStatus(status)
        }
    }

    // MARK: - Matching

    static func bestMatch(_ songs: [Song], title: String, artist: String, duration: TimeInterval) -> String? {
        let wantTitle = MusicText.normalize(MusicText.lyricsTitle(title))
        let wantArtist = MusicText.normalize(artist)
        var best: (score: Double, id: String)?
        for song in songs {
            guard let attributes = song.attributes else { continue }
            if let millis = attributes.durationInMillis, duration > 0, abs(millis / 1000 - duration) > 3 { continue }
            let gotTitle = MusicText.normalize(MusicText.lyricsTitle(attributes.name ?? ""))
            let gotArtist = MusicText.normalize(attributes.artistName ?? "")
            var score = 0.0
            if gotTitle == wantTitle { score += 3 } else if gotTitle.contains(wantTitle) || wantTitle.contains(gotTitle) { score += 1.5 }
            if gotArtist == wantArtist { score += 3 } else if gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist) { score += 1.5 }
            if score >= 4.5, score > (best?.score ?? 0) { best = (score, song.id) }
        }
        return best?.id
    }

    // MARK: - Cache

    private func readDisk(_ key: String) -> CacheEntry? {
        guard let url = cacheDirectory?.appending(path: key + ".json"),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data)
        else { return nil }
        if entry.ttml == nil, Date().timeIntervalSince(entry.savedAt) > negativeTTL { return nil }
        return entry
    }

    private func writeDisk(_ key: String, _ entry: CacheEntry) {
        guard let url = cacheDirectory?.appending(path: key + ".json"),
              let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
