import AppKit
import IsletCore
import SwiftUI

/// Renders the island, full player and lock widget to PNG files for layout review.
@MainActor
enum SnapshotRenderer {
    static func run(output: URL, artPath: String?, lrcPath: String?) {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let settings = AppSettings()
        let store = PlayerStore(settings: settings)

        let artData = artPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        let art = artData.flatMap(NSImage.init(data:))
        let palette = artData.map(ArtworkPixels.palette(from:)) ?? .fallback
        let lrc = lrcPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            ?? "[00:10.00]First line of the song\n[00:14.00]Second line, a bit longer than the first\n[00:18.00]Third line\n[00:22.00]Fourth line\n[00:26.00]Fifth line"
        let lines = LRCParser.parse(lrc, duration: 274)
        let elapsed = lines.dropFirst(min(4, max(lines.count - 1, 0))).first.map { $0.start + 0.5 } ?? 15

        store.loadPreview(
            NowPlayingSnapshot(title: "Not Like Us", artist: "Kendrick Lamar", album: "Not Like Us - Single",
                               duration: 274, elapsed: elapsed, timestamp: Date(), playbackRate: 0,
                               isPlaying: false, bundleIdentifier: "com.apple.Music"),
            artwork: art, palette: palette, lyrics: .synced(lines))

        // Render every island style; the setting is persisted, so restore it afterwards.
        let savedStyle = settings.islandStyle
        let desktop = LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
        for style in IslandStyle.allCases {
            settings.islandStyle = style
            let metrics = IslandMetrics.make(for: NSScreen.screens.first!, style: style)
            for presentation in [IslandPresentation.compact, .expanded, .controls] {
                let model = IslandModel(metrics: metrics)
                model.presentation = presentation
                let name = "island-\(style.rawValue)-\(presentation == .compact ? "compact" : presentation == .expanded ? "expanded" : "controls").png"
                save(IslandView(model: model, store: store, settings: settings).background(desktop),
                     size: metrics.windowSize, to: output.appending(path: name))
            }
        }
        settings.islandStyle = savedStyle

        let screen = CGSize(width: 1440, height: 900)
        for lyrics in [false, true] {
            let model = FullPlayerModel()
            model.isPresented = true
            model.isOpen = true
            model.showLyrics = lyrics
            save(FullPlayerView(model: model, store: store), size: screen,
                 to: output.appending(path: lyrics ? "player-lyrics.png" : "player.png"))
        }
        let lockModel = LockModel()
        lockModel.isPresented = true
        lockModel.battery = BatteryState(level: 0.82, isCharging: false, isPluggedIn: false)
        let lockBackground = Color(red: 0.12, green: 0.14, blue: 0.22)
        save(LockWidgetsRow(store: store, model: lockModel, settings: settings).background(lockBackground),
             size: LockLayout.widgetsSize, to: output.appending(path: "lock-widgets.png"))
        save(LockPlayerPlatter(store: store, model: lockModel).background(lockBackground),
             size: LockLayout.playerSize, to: output.appending(path: "lock-player.png"))

        let palettePreview = HStack(spacing: 0) {
            ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, color in Color(rgb: color) }
            Color(rgb: palette.accent).overlay(Text("accent").foregroundStyle(.black))
        }
        save(palettePreview, size: CGSize(width: 600, height: 80), to: output.appending(path: "palette.png"))
        print("Rendered snapshots to \(output.path)")
    }

    private static func save(_ view: some View, size: CGSize, to url: URL) {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .environment(\.isSnapshotRendering, true))
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            print("Could not render \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
