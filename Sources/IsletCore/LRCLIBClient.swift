import CryptoKit
import Foundation

/// Lyrics for one track.
public enum LyricsContent: Sendable, Equatable, Codable {
    case synced(lrc: String)
    case plain(String)
    case instrumental
}

/// Client for https://lrclib.net — a free, keyless, community lyrics database (server is MIT).
///
/// Lookup order: exact `/api/get` (duration ±2 s on the server), then `/api/search`
/// scored locally. Results (including "not found") are cached in memory and on disk.
public actor LRCLIBClient {
    public enum Failure: Error, Equatable {
        case rateLimited(retryAfter: TimeInterval?)
        case badStatus(Int)
    }

    private struct Record: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    private struct CacheEntry: Codable {
        var content: LyricsContent?
        var savedAt: Date
    }

    private let session: URLSession
    private let userAgent: String
    private let cacheDirectory: URL?
    private var memory: [String: LyricsContent?] = [:]
    private let baseURL = URL(string: "https://lrclib.net/api/")!
    /// Re-query "not found" results after a day; lyrics get contributed over time.
    private let negativeTTL: TimeInterval = 24 * 60 * 60

    public init(session: URLSession = .shared, userAgent: String, cacheDirectory: URL? = nil) {
        self.session = session
        self.userAgent = userAgent
        self.cacheDirectory = cacheDirectory
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    public func lyrics(title: String, artist: String, album: String, duration: TimeInterval) async throws -> LyricsContent? {
        let key = Self.cacheKey(title: title, artist: artist, album: album, duration: duration)
        if let cached = memory[key] { return cached }
        if let cached = readDisk(key) {
            memory[key] = .some(cached.content)
            return cached.content
        }

        // As reported first; then as lyrics sites list it (no "feat." or "Remastered"
        // tags), with the full artist credit and then just the first artist.
        let cleanTitle = MusicText.lyricsTitle(title)
        let firstArtist = MusicText.primaryArtist(artist)
        var result = try await getExact(title: title, artist: artist, album: album, duration: duration)
        if result == nil, cleanTitle != title {
            result = try await getExact(title: cleanTitle, artist: artist, album: album, duration: duration)
        }
        if result == nil {
            result = try await search(title: cleanTitle, artist: artist, duration: duration)
        }
        if result == nil, firstArtist != artist {
            result = try await search(title: cleanTitle, artist: firstArtist, duration: duration)
        }
        let content = result.flatMap(Self.content(from:))
        memory[key] = .some(content)
        writeDisk(key, CacheEntry(content: content, savedAt: Date()))
        return content
    }

    // MARK: - Requests

    private func getExact(title: String, artist: String, album: String, duration: TimeInterval) async throws -> Record? {
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        let albumName = Self.cleanAlbum(album)
        if !albumName.isEmpty { items.append(URLQueryItem(name: "album_name", value: albumName)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        return try await fetch("get", items, as: Record.self)
    }

    private func search(title: String, artist: String, duration: TimeInterval) async throws -> Record? {
        let items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let records = try await fetch("search", items, as: [Record].self) else { return nil }
        return Self.bestMatch(records, title: title, artist: artist, duration: duration)
    }

    private func fetch<T: Decodable>(_ path: String, _ items: [URLQueryItem], as type: T.Type) async throws -> T? {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        var request = URLRequest(url: components.url!, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try JSONDecoder().decode(T.self, from: data)
        case 404: return nil
        case 429:
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw Failure.rateLimited(retryAfter: retry)
        default: throw Failure.badStatus(status)
        }
    }

    // MARK: - Matching

    private static func bestMatch(_ records: [Record], title: String, artist: String, duration: TimeInterval) -> Record? {
        let wantTitle = MusicText.normalize(MusicText.lyricsTitle(title))
        let wantArtist = MusicText.normalize(artist)
        var best: (score: Double, record: Record)?
        for record in records {
            if let d = record.duration, duration > 0, abs(d - duration) > 3 { continue }
            var score = 0.0
            let gotTitle = MusicText.normalize(record.trackName ?? "")
            let gotArtist = MusicText.normalize(record.artistName ?? "")
            if gotTitle == wantTitle { score += 3 } else if gotTitle.contains(wantTitle) { score += 1.5 }
            if gotArtist == wantArtist { score += 3 } else if gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist) { score += 1.5 }
            if record.syncedLyrics?.isEmpty == false { score += 1 }
            if score >= 4, score > (best?.score ?? 0) { best = (score, record) }
        }
        return best?.record
    }

    private static func content(from record: Record) -> LyricsContent? {
        if let synced = record.syncedLyrics, !synced.isEmpty { return .synced(lrc: synced) }
        if let plain = record.plainLyrics, !plain.isEmpty { return .plain(plain) }
        if record.instrumental == true { return .instrumental }
        return nil
    }

    static func cleanAlbum(_ album: String) -> String {
        album.replacing(/(?i)\s+-\s+(single|ep)$/, with: "")
    }

    // MARK: - Cache

    static func cacheKey(title: String, artist: String, album: String, duration: TimeInterval) -> String {
        let raw = [title, artist, album, String(Int(duration.rounded()))].joined(separator: "|").lowercased()
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func readDisk(_ key: String) -> CacheEntry? {
        guard let url = cacheDirectory?.appending(path: key + ".json"),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data)
        else { return nil }
        if entry.content == nil, Date().timeIntervalSince(entry.savedAt) > negativeTTL { return nil }
        return entry
    }

    private func writeDisk(_ key: String, _ entry: CacheEntry) {
        guard let url = cacheDirectory?.appending(path: key + ".json"),
              let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
