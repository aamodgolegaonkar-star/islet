import AppKit
import IsletCore
import SwiftUI

/// Right-hand lyrics column of the full-screen player.
struct LyricsPanel: View {
    let store: PlayerStore

    var body: some View {
        switch store.lyrics {
        case .synced(let lines):
            SyncedLyrics(lines: lines, store: store)
        case .plain(let text):
            ScrollView {
                Text(text)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 140)
            }
            .scrollIndicators(.hidden)
            .mask(fadeMask)
        case .loading, .idle:
            ProgressView().controlSize(.large).tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .instrumental:
            message("Instrumental", symbol: "music.note")
        case .unavailable:
            message("Lyrics aren't available for this song.", symbol: "quote.bubble")
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 34, weight: .semibold))
            Text(text).font(.system(size: 22, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Follows playback through synced lyrics, waking only when the highlighted line changes —
/// never in between, never while paused. A sleeping task rather than a TimelineView, which
/// would redraw every frame (see `PlaybackClock`).
private struct SyncedLyrics: View {
    let lines: [LyricLine]
    let store: PlayerStore
    @State private var active: Int

    /// Matches `LRCParser.activeIndex`'s default: lines light up just before they're sung.
    private static let lead: TimeInterval = 0.15

    private struct Key: Equatable {
        var timing: PlaybackTiming?
        var count: Int
        var offset: Double
    }

    init(lines: [LyricLine], store: PlayerStore) {
        self.lines = lines
        self.store = store
        // Start on the right line, so opening the panel doesn't animate from the top.
        _active = State(initialValue: LRCParser.activeIndex(in: lines, at: store.lyricsPosition(at: Date())) ?? -1)
    }

    var body: some View {
        LyricsStage(lines: lines, active: active, store: store).equatable()
            .task(id: Key(timing: store.timing, count: lines.count, offset: LiveTuning.shared.lyricsOffset)) {
                while !Task.isCancelled {
                    let offset = LiveTuning.shared.lyricsOffset
                    let position = store.lyricsPosition(at: Date())
                    let index = LRCParser.activeIndex(in: lines, at: position, lead: Self.lead) ?? -1
                    if index != active { active = index }
                    guard let timing = store.timing,
                          let start = lines.first(where: { $0.start > position + Self.lead })?.start,
                          let date = timing.date(reaching: start - Self.lead - offset)
                    else { return }
                    // A hair late, so the new line is certainly active when it's drawn.
                    try? await Task.sleep(until: .now + .seconds(max(date.timeIntervalSinceNow, 0) + 0.004),
                                          tolerance: .milliseconds(10))
                }
            }
    }
}

let fadeMask = LinearGradient(
    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
            .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
    startPoint: .top, endPoint: .bottom)

/// Lays out lyric rows individually so each can spring into place with its own delay,
/// producing the cascading "wave" of Apple Music when the active line advances.
struct LyricsStage: View, Equatable {
    let lines: [LyricLine]
    let active: Int
    let store: PlayerStore

    nonisolated static func == (a: LyricsStage, b: LyricsStage) -> Bool {
        a.active == b.active && a.lines == b.lines && a.store === b.store
    }

    @State private var heights: [Int: CGFloat] = [:]
    @State private var userOffset: CGFloat = 0
    @State private var frozenAnchor: Int?
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fontSize = min(max(width / 17, 24), 40)
            let spacing = fontSize * 0.62
            let anchor = frozenAnchor ?? max(active, 0)
            let anchorY = geo.size.height * 0.3
            let visible = max(0, anchor - 6)...min(lines.count - 1, anchor + 12)

            ZStack(alignment: .topLeading) {
                ForEach(lines[visible]) { line in
                    let distance = line.id - max(active, 0)
                    LyricRow(line: line, distance: distance, isActive: line.id == active,
                             fontSize: fontSize, store: store)
                        .frame(width: width, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[line.id] = $0 }
                        .offset(y: anchorY + offset(of: line.id, from: anchor, spacing: spacing,
                                                    estimate: fontSize * 1.5) + userOffset)
                        // Battery saver: one short ease instead of a staggered cascade of springs.
                        .animation(LiveTuning.shared.batterySaving
                                   ? .easeOut(duration: 0.25)
                                   : .spring(response: 0.62, dampingFraction: 0.84)
                                       .delay(distance > 0 ? min(Double(distance) * 0.045, 0.4) : 0),
                                   value: active)
                        .onTapGesture {
                            store.seek(to: line.start)
                            resumeFollowing(after: .zero)
                        }
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .mask(fadeMask)
            .overlay {
                if !snapshot { ScrollWheelCatcher { delta in scrolled(by: delta) } }
            }
        }
    }

    @Environment(\.isSnapshotRendering) private var snapshot

    private func offset(of index: Int, from anchor: Int, spacing: CGFloat, estimate: CGFloat) -> CGFloat {
        let height = { (i: Int) in (heights[i] ?? estimate) + spacing }
        if index >= anchor {
            return (anchor..<index).reduce(0) { $0 + height($1) }
        }
        return -(index..<anchor).reduce(0) { $0 + height($1) }
    }

    private func scrolled(by delta: CGFloat) {
        if frozenAnchor == nil { frozenAnchor = max(active, 0) }
        userOffset += delta
        resumeFollowing(after: .seconds(3))
    }

    private func resumeFollowing(after delay: Duration) {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                userOffset = 0
                frozenAnchor = nil
            }
        }
    }
}

/// One lyric line (or interlude). Inactive lines dim and blur with distance.
struct LyricRow: View {
    let line: LyricLine
    let distance: Int
    let isActive: Bool
    let fontSize: CGFloat
    let store: PlayerStore
    @State private var hovering = false

    var body: some View {
        Group {
            if line.isInterlude {
                InterludeDots(line: line, isActive: isActive, store: store, dotSize: fontSize * 0.36)
                    .frame(height: isActive ? fontSize * 1.1 : fontSize * 0.2, alignment: .leading)
            } else if LiveTuning.shared.lyricStyle != .classic, !line.words.isEmpty {
                WordLyricLine(line: line, isActive: isActive, fontSize: fontSize, store: store)
            } else {
                Text(line.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.white)
            }
        }
        .opacity(rowOpacity)
        .blur(radius: isActive || hovering ? 0 : min(CGFloat(abs(distance)) * 0.75, 4))
        .scaleEffect(isActive ? 1 : 0.965, anchor: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        // Hovering a line lifts a pane of Liquid Glass behind it (click to jump there);
        // inside a glass card it's a soft highlight instead, since glass shouldn't stack.
        .modifier(LyricHoverSurface(active: hovering && !line.isInterlude))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var rowOpacity: Double {
        if line.isInterlude { return isActive ? 1 : 0 }
        if isActive { return 1 }
        if hovering { return 0.7 }
        return distance < 0 ? 0.26 : 0.34
    }
}

/// Three dots that fill across an instrumental break and breathe, then fold away.
struct InterludeDots: View {
    let line: LyricLine
    let isActive: Bool
    let store: PlayerStore
    let dotSize: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: !isActive || !store.isPlaying || LiveTuning.shared.batterySaving)) { context in
            let now = store.lyricsPosition(at: context.date)
            let length = max(line.end - line.start, 0.01)
            let progress = min(max((now - line.start) / length, 0), 1)
            let breathe = 1 + 0.12 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.4)
            let ending = progress > 0.9 ? max(0, 1 - (progress - 0.9) / 0.1) : 1
            HStack(spacing: dotSize * 0.7) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(0.28 + 0.72 * min(max(progress * 3 - Double(i), 0), 1)))
                        .frame(width: dotSize, height: dotSize)
                }
            }
            .scaleEffect(isActive ? breathe * ending : 0.5, anchor: .leading)
        }
    }
}

/// Transparent overlay that receives only scroll-wheel events; clicks pass through.
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            onScroll?(delta)
        }
    }
}

private struct LyricHoverSurface: ViewModifier {
    let active: Bool
    @Environment(\.insideGlass) private var insideGlass

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if insideGlass {
            content.background(shape.fill(.white.opacity(active ? 0.1 : 0)))
        } else {
            content.snapshotSafeGlass(active ? .clear.interactive() : .identity, visible: active, in: shape)
        }
    }
}

/// The line being sung, as one line under the artist in the open island. Wakes only when
/// the line changes, like `SyncedLyrics`; shows nothing without synced lyrics. In the
/// word-by-word styles the line runs a timeline while it's shown and music plays, sliding
/// along to keep the word being sung in view.
struct LiveLyricLine: View {
    let store: PlayerStore
    @State private var line: LyricLine?

    private struct Key: Equatable {
        var timing: PlaybackTiming?
        var lyrics: LyricsState
        var offset: Double
    }

    init(store: PlayerStore) {
        self.store = store
        // Start on the current line, so the island doesn't open blank.
        _line = State(initialValue: Self.line(in: store, at: store.lyricsPosition(at: Date())))
    }

    private static func line(in store: PlayerStore, at position: TimeInterval) -> LyricLine? {
        guard case .synced(let lines) = store.lyrics else { return nil }
        return LRCParser.activeIndex(in: lines, at: position).map { lines[$0] }
    }

    private var text: String {
        guard let line else { return "" }
        return line.isInterlude ? "♪" : line.text
    }

    @ViewBuilder
    private var content: some View {
        if let line, !line.words.isEmpty, LiveTuning.shared.lyricStyle != .classic {
            TimelineView(.animation(minimumInterval: LiveTuning.shared.batterySaving ? 1.0 / 20 : 1.0 / 60,
                                    paused: !store.isPlaying)) { context in
                SungWords(words: line.words,
                          focus: WordTiming.focus(in: line.words, at: store.lyricsPosition(at: context.date) + 0.05),
                          fontSize: 12,
                          fisheye: LiveTuning.shared.lyricStyle == .fisheye,
                          icons: LiveTuning.shared.lyricWordIcons,
                          singleLine: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    var body: some View {
        content
            .id("\(line?.id ?? -1) \(text)")
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: line)
            // Room above for a swelling word, then clip the line change's slide.
            .padding(.top, 4)
            .clipped()
            .padding(.top, -4)
            .task(id: Key(timing: store.timing, lyrics: store.lyrics, offset: LiveTuning.shared.lyricsOffset)) {
                guard case .synced(let lines) = store.lyrics else { line = nil; return }
                let lead: TimeInterval = 0.15
                while !Task.isCancelled {
                    let offset = LiveTuning.shared.lyricsOffset
                    let position = store.lyricsPosition(at: Date())
                    let next = Self.line(in: store, at: position)
                    if next != line { line = next }
                    guard let timing = store.timing,
                          let start = lines.first(where: { $0.start > position + lead })?.start,
                          let date = timing.date(reaching: start - lead - offset)
                    else { return }
                    try? await Task.sleep(until: .now + .seconds(max(date.timeIntervalSinceNow, 0) + 0.004),
                                          tolerance: .milliseconds(10))
                }
            }
    }
}
