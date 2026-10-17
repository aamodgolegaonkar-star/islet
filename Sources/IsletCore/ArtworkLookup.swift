import Foundation

/// Text helpers for matching titles across services.
public enum MusicText {
    /// Lowercases, folds diacritics, and drops edition noise such as "(Deluxe)" or " - Single".
    public static func normalize(_ text: String) -> String {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
        s = s.replacing(/\s*[\(\[][^\)\]]*[\)\]]/, with: "")
        s = s.replacing(/\s+-\s+(single|ep|deluxe.*|remaster.*)$/, with: "")
        s = s.replacing(/\s+(feat\.?|ft\.?)\s.*$/, with: "")
        s = s.replacing(/[^\p{L}\p{N}]+/, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A title as lyrics sites list it: without "(feat. …)", "- Remastered 2011",
    /// "(Live)", "[Explicit]" and similar edition tags that streaming services add.
    public static func lyricsTitle(_ title: String) -> String {
        var s = title
        s = s.replacing(/(?i)\s*[\(\[](feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]/, with: "")
        s = s.replacing(/(?i)\s*[\(\[][^\)\]]*(remaster|version|edit|mono|stereo|explicit|clean|live|mix|deluxe|bonus|sped up|slowed)[^\)\]]*[\)\]]/, with: "")
        s = s.replacing(/(?i)\s+-\s+[^-]*(remaster|version|edit|mono|stereo|live|mix|single|sped up|slowed)[^-]*$/, with: "")
        s = s.replacing(/(?i)\s+(feat\.?|ft\.?|featuring)\s.*$/, with: "")
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// The first credited artist: "A feat. B", "A, B & C" and "A x B" all give "A".
    /// Only a fallback, since some band names contain commas or ampersands.
    public static func primaryArtist(_ artist: String) -> String {
        let s = artist.replacing(/(?i)\s+(feat\.?|ft\.?|featuring|with|x)\s.*$/, with: "")
        let first = s.split(whereSeparator: { ",&".contains($0) }).first.map(String.init) ?? s
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? artist : trimmed
    }

    /// Rewrites an mzstatic artwork URL ("…/100x100bb.jpg") to the requested pixel size.
    public static func resizedArtworkURL(_ url: String, size: Int) -> URL? {
        URL(string: url.replacing(/\d+x\d+bb/, with: "\(size)x\(size)bb"))
    }
}

/// An album in the Apple catalog, found through the keyless iTunes Search API.
public struct CatalogAlbum: Sendable, Equatable {
    public var collectionID: Int
    public var name: String
    public var artist: String
    public var artworkTemplate: String?

    public func artworkURL(size: Int) -> URL? {
        artworkTemplate.flatMap { MusicText.resizedArtworkURL($0, size: size) }
    }
}

/// Finds the playing album in the iTunes catalog (≈20 requests/min limit, so results are cached).
public actor ITunesLookup {
    private struct Response: Decodable { var results: [Item] }
    private struct Item: Decodable {
        var collectionId: Int?
        var collectionName: String?
        var artistName: String?
        var trackName: String?
        var artworkUrl100: String?
    }

    private let session: URLSession
    private var cache: [String: CatalogAlbum?] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func album(title: String, artist: String, album: String, country: String) async -> CatalogAlbum? {
        let key = [artist, album, country].map(MusicText.normalize).joined(separator: "|")
        if let cached = cache[key] { return cached }

        var found = await search(term: "\(title) \(artist)", entity: "song", title: title, artist: artist, album: album, country: country)
        if found == nil, !album.isEmpty {
            found = await search(term: "\(artist) \(album)", entity: "album", title: nil, artist: artist, album: album, country: country)
        }
        cache[key] = .some(found)
        return found
    }

    private func search(term: String, entity: String, title: String?, artist: String, album: String, country: String) async -> CatalogAlbum? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return Self.best(decoded.results, title: title, artist: artist, album: album)
    }

    private static func best(_ items: [Item], title: String?, artist: String, album: String) -> CatalogAlbum? {
        let wantArtist = MusicText.normalize(artist)
        let wantAlbum = MusicText.normalize(album)
        let wantTitle = title.map(MusicText.normalize)
        var best: (score: Double, album: CatalogAlbum)?
        for item in items {
            guard let id = item.collectionId else { continue }
            let gotArtist = MusicText.normalize(item.artistName ?? "")
            let gotAlbum = MusicText.normalize(item.collectionName ?? "")
            var score = 0.0
            if gotArtist == wantArtist { score += 3 } else if gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist) { score += 1.5 } else { continue }
            if !wantAlbum.isEmpty {
                if gotAlbum == wantAlbum { score += 3 } else if gotAlbum.contains(wantAlbum) || wantAlbum.contains(gotAlbum) { score += 1.5 }
            }
            if let wantTitle, MusicText.normalize(item.trackName ?? "") == wantTitle { score += 2 }
            if score >= 4.5, score > (best?.score ?? 0) {
                best = (score, CatalogAlbum(collectionID: id, name: item.collectionName ?? "",
                                            artist: item.artistName ?? "", artworkTemplate: item.artworkUrl100))
            }
        }
        return best?.album
    }
}

/// Official Apple Music API access for motion (video) album artwork.
///
/// Requires a developer token from a paid Apple Developer Program account. Apple has said
/// `editorialVideo` is not offered to third parties, so a nil result is the expected norm.
public struct AppleMusicCatalog: Sendable {
    public var developerToken: String
    public var storefront: String

    public init(developerToken: String, storefront: String) {
        self.developerToken = developerToken
        self.storefront = storefront
    }

    public func motionArtwork(albumID: Int, session: URLSession = .shared) async -> MotionArtwork? {
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/albums/\(albumID)?extend=editorialVideo") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return MotionArtwork.parse(albumResponse: data)
    }
}

/// HLS URLs for an album's motion artwork.
public struct MotionArtwork: Sendable, Equatable {
    public var square: URL?
    public var tall: URL?

    /// Parses `data[0].attributes.editorialVideo` from an Apple Music API album response.
    public static func parse(albumResponse data: Data) -> MotionArtwork? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let first = (root["data"] as? [[String: Any]])?.first,
            let attributes = first["attributes"] as? [String: Any],
            let video = attributes["editorialVideo"] as? [String: Any]
        else { return nil }
        func url(_ keys: [String]) -> URL? {
            for key in keys {
                if let entry = video[key] as? [String: Any],
                   let string = entry["video"] as? String,
                   let url = URL(string: string) { return url }
            }
            return nil
        }
        let artwork = MotionArtwork(
            square: url(["motionDetailSquare", "motionSquareVideo1x1"]),
            tall: url(["motionDetailTall", "motionTallVideo3x4"])
        )
        return artwork.square == nil && artwork.tall == nil ? nil : artwork
    }
}
