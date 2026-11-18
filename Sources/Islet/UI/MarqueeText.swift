import SwiftUI

/// One line of text that, when it doesn't fit, scrolls sideways to show the rest: a pause,
/// a steady glide to a second copy (so it ends where it began), twice, then it rests
/// truncated. Hovering it plays it again. Fits exactly like a plain one-line `Text`, so it
/// drops into any layout; font and colour come from the environment as usual.
struct MarqueeText: View {
    let text: String
    var gap: CGFloat = 32
    /// Points per second.
    var speed: CGFloat = 30
    var passes = 2

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var run = 0
    @State private var scrolling = false

    private var overflows: Bool { textWidth > boxWidth + 1 && boxWidth > 0 }

    var body: some View {
        // The truncated line sets the size, exactly as a plain Text would.
        Text(text)
            .lineLimit(1)
            .opacity(overflows ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background(alignment: .leading) {
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if overflows {
                    HStack(spacing: gap) {
                        Text(text).lineLimit(1).fixedSize()
                        Text(text).lineLimit(1).fixedSize()
                    }
                    .offset(x: offset)
                    .frame(width: boxWidth, alignment: .leading)
                    .clipped()
                    .mask(fade)
                    .allowsHitTesting(false)
                }
            }
            .onHover { inside in if inside, !scrolling { run += 1 } }
            .task(id: TaskKey(text: text, fits: !overflows, run: run)) { await scroll() }
    }

    /// Soft edges: the trailing one always (more is coming), the leading one while moving.
    private var fade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: scrolling ? 10 : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
        }
    }

    private struct TaskKey: Equatable {
        var text: String
        var fits: Bool
        var run: Int
    }

    private func scroll() async {
        offset = 0
        scrolling = false
        guard overflows, !IslandMotion.reduced else { return }
        let distance = textWidth + gap
        let duration = Double(distance / speed)
        for _ in 0..<passes {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            scrolling = true
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // The second copy now sits where the first began: jump back unseen.
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { offset = 0 }
            scrolling = false
        }
    }
}
