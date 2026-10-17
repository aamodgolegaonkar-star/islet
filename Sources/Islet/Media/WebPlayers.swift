import AppKit

/// Which web player a browser is playing (YouTube Music, Deezer, Qobuz…). macOS reports
/// only the browser, so Islet asks the browser for the tab whose title matches the song
/// (or, failing that, the front tab) and reads its address.
enum WebPlayers {
    private enum Family { case safari, chromium }

    private static let browsers: [String: Family] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "company.thebrowser.Browser": .chromium,
        "company.thebrowser.dia": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
    ]

    /// Domains (most specific first) and the service's name.
    private static let services: [(domain: String, name: String)] = [
        ("music.youtube.com", "YouTube Music"),
        ("youtube.com", "YouTube"),
        ("open.spotify.com", "Spotify"),
        ("music.apple.com", "Apple Music"),
        ("soundcloud.com", "SoundCloud"),
        ("tidal.com", "Tidal"),
        ("qobuz.com", "Qobuz"),
        ("deezer.com", "Deezer"),
        ("pandora.com", "Pandora"),
        ("bandcamp.com", "Bandcamp"),
        ("mixcloud.com", "Mixcloud"),
        ("music.amazon.", "Amazon Music"),
    ]

    static func isBrowser(_ bundle: String) -> Bool { browsers[bundle] != nil }

    /// The service playing `title` in the browser `bundle`, if it's one Islet knows.
    static func service(bundle: String, title: String) async -> String? {
        guard let family = browsers[bundle],
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
              let address = await MusicAppSource.osascript(script(bundle: bundle, family: family, title: title)),
              let host = URL(string: address)?.host()?.lowercased() else { return nil }
        return services.first { service in
            service.domain.hasSuffix(".")
                ? host.hasPrefix(service.domain) || host.contains("." + service.domain)
                : host == service.domain || host.hasSuffix("." + service.domain)
        }?.name
    }

    private static func script(bundle: String, family: Family, title: String) -> String {
        let quoted = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        switch family {
        case .safari:
            return """
            tell application id "\(bundle)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if name of t contains "\(quoted)" then return URL of t
                    end repeat
                end repeat
                return URL of current tab of front window
            end tell
            """
        case .chromium:
            return """
            tell application id "\(bundle)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if title of t contains "\(quoted)" then return URL of t
                    end repeat
                end repeat
                return URL of active tab of front window
            end tell
            """
        }
    }
}
