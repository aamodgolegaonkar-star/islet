import IsletCore
import SwiftUI

/// Volume or brightness: the glyph, a glass level bar and the percentage, sized to the
/// pill like the iPhone's Dynamic Island volume indicator.
/// Volume or brightness: the glyph, Apple's own slider and the percentage, sized to the
/// pill like the iPhone's Dynamic Island volume indicator. The slider is drawn by AppKit,
/// so it moves smoothly however fast the level changes, and it can be dragged.
struct LevelContent: View {
    /// Read here (not by the island) so a change of level redraws only this pill's content.
    let model: IslandModel
    private var hud: LevelHUD { model.level }
    /// Beside a notch: icon and percentage in the wings, the slider in a strip below the notch.
    var notchHeight: CGFloat?

    var body: some View {
        Group {
            if let notchHeight {
                VStack(spacing: 0) {
                    HStack {
                        glyph
                        Spacer()
                        percentage
                    }
                    .frame(height: notchHeight)
                    bar.padding(.bottom, 4)
                }
            } else {
                HStack(spacing: 8) {
                    glyph
                    bar
                    percentage
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 22)
    }

    private var bar: some View {
        GlassSlider(value: shown, tint: hud.kind == .brightness ? .yellow : .white, restHeight: 4, thumb: .always,
                    onEditingChanged: { model.isInteracting = $0 },
                    onChange: { drag(to: $0) }, onCommit: { drag(to: $0) })
    }

    private func drag(to value: Double) {
        model.level.value = value
        model.level.muted = false
        model.onLevelDrag(hud.kind, value)
    }

    private var percentage: some View {
        Text("\(Int((shown * 100).rounded()))")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 26, alignment: .trailing)
            .contentTransition(.numericText())
    }

    private var shown: Double { hud.muted ? 0 : min(max(hud.value, 0), 1) }

    private var symbol: String {
        switch hud.kind {
        case .brightness: hud.value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if hud.muted || hud.value == 0 { "speaker.slash.fill" }
            else if hud.value < 0.34 { "speaker.wave.1.fill" }
            else if hud.value < 0.67 { "speaker.wave.2.fill" }
            else { "speaker.wave.3.fill" }
        }
    }
}

/// Headphones just connected: the model's picture, the name its owner gave it, and battery
/// (left, right and case for earbuds; one level for over-ears) when the device reports it.
struct HeadphoneContent: View {
    let card: HeadphoneCard
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 14) {
            Headphone3DView(model: card.model)
                .frame(width: 86, height: 86)
                .scaleEffect(appeared ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.deviceName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            batteries
        }
        .padding(.horizontal, 20)
        .onAppear {
            withAnimation(IslandMotion.playful.delay(0.05)) { appeared = true }
        }
    }

    /// "AirPods Max · Connected" — or just "Connected" when the name already says the model.
    private var subtitle: String {
        guard let model = card.model?.name,
              !card.deviceName.localizedCaseInsensitiveContains(model) else { return "Connected" }
        return "\(model) · Connected"
    }

    @ViewBuilder
    private var batteries: some View {
        let battery = card.battery
        HStack(spacing: 8) {
            if let left = battery.left { ring(left, label: "L") }
            if let right = battery.right { ring(right, label: "R") }
            if let box = battery.case { ring(box, label: "Case") }
            if battery.left == nil, battery.right == nil, let single = battery.single { ring(single, label: nil) }
        }
    }

    private func ring(_ percent: Int, label: String?) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: appeared ? Double(percent) / 100 : 0)
                    .stroke(percent <= 20 ? Color.red : Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percent)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            if let label {
                Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .animation(.easeOut(duration: 0.8).delay(0.2), value: appeared)
    }
}

/// Claude Code or Codex needs attention: a coloured badge for what it wants, the title, and
/// the project and message. Clicking it brings the agent's terminal forward.
struct AgentContent: View {
    let alert: AgentAlert
    let tap: () -> Void
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.gradient)
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: appeared)
            }
            .frame(width: 44, height: 44)
            .scaleEffect(appeared ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if !alert.subtitle.isEmpty {
                    Text(alert.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .routedClick("agent", action: tap)
        .onTapGesture(perform: tap)
        .onAppear {
            withAnimation(IslandMotion.playful) { appeared = true }
        }
    }

    private var symbol: String {
        switch alert.event.kind {
        case .permission: "hand.raised.fill"
        case .waiting: "ellipsis.bubble.fill"
        case .done: "checkmark"
        }
    }

    private var tint: Color {
        switch alert.event.kind {
        case .permission: .orange
        case .waiting: .blue
        case .done: .green
        }
    }
}

/// Battery at 20% or 10%: the charging card in reverse, in red.
struct LowBatteryContent: View {
    let percent: Int
    /// Beside a notch the label won't fit in a wing: icon left, percentage right.
    var besideNotch = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "battery.25percent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeat(2))
            if !besideNotch {
                Text("Low Battery")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 6)
            Text("\(percent)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 14)
    }
}

/// The resting island's small clock: the date at the leading edge, the time at the
/// trailing (beside a notch, one in each wing). Redraws once a minute, on the minute.
struct IdleClockContent: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack {
                Text(context.date, format: .dateTime.weekday(.abbreviated).day())
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 12)
        }
    }
}

/// A running timer in the compact island: icon at the leading edge, time at the trailing.
struct TimerCompactContent: View {
    let end: Date
    @State private var now = Date()

    var body: some View {
        HStack {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
            Text(remaining)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.orange)
                .contentTransition(.numericText(countsDown: true))
        }
        .padding(.horizontal, 12)
        // One redraw per second, on the second (no animation timeline).
        .task(id: end) {
            while !Task.isCancelled {
                now = Date()
                let left = end.timeIntervalSince(now)
                guard left > 0 else { return }
                let fraction = left - left.rounded(.down)
                try? await Task.sleep(for: .seconds(fraction > 0.01 ? fraction : 1), tolerance: .milliseconds(20))
            }
        }
        .animation(IslandMotion.quick, value: remaining)
    }

    private var remaining: String {
        let seconds = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct TimerDoneContent: View {
    /// Beside a notch: icon in the left wing, "Done" in the right.
    var besideNotch = false
    @State private var ring = 0

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "timer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, value: ring)
            if besideNotch { Spacer(minLength: 0) }
            Text(besideNotch ? "Done" : "Timer Done")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if !besideNotch { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 14)
        .onAppear { ring += 1 }
    }
}

/// A Focus mode turning on or off: its icon in its colour, its name, and On or Off, with the
/// icon dropping in and the state rolling up like a reel.
struct FocusContent: View {
    let mode: FocusMode
    let on: Bool
    /// Beside a notch the name won't fit in a wing: icon left, state right.
    var besideNotch = false
    @State private var shown = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: mode.displaySymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? mode.color : .white.opacity(0.45))
                .frame(width: 24, height: 24)
                .background(Circle().fill((on ? mode.color : .white).opacity(on ? 0.22 : 0.1)))
                .scaleEffect(shown ? 1 : 0.4)
                .symbolEffect(.bounce, value: shown)
            if !besideNotch {
                Text(mode.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(on ? "On" : "Off")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? mode.color : .white.opacity(0.55))
                .offset(y: shown ? 0 : 14)
                .opacity(shown ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .clipped()
        .onAppear {
            withAnimation(IslandMotion.reduced ? nil : .spring(response: 0.45, dampingFraction: 0.62).delay(0.08)) { shown = true }
        }
    }
}

extension FocusMode {
    /// Focus uses a few private symbols (Work's lanyard, Gaming's rocket): their public
    /// look-alikes, or the moon.
    var displaySymbol: String {
        if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil { return symbol }
        let alike = ["person.lanyardcard.fill": "lanyardcard.fill", "rocket.fill": "gamecontroller.fill",
                     "apple.mindfulness": "figure.mind.and.body"][symbol]
        return alike.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil } ?? "moon.fill"
    }

    /// The mode's system colour by its name ("systemTealColor"), as Focus shows it.
    var color: Color {
        let name = tint.replacingOccurrences(of: "system", with: "").replacingOccurrences(of: "Color", with: "").lowercased()
        return switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "blue": .blue
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        case "gray", "grey": .gray
        default: .indigo
        }
    }
}

/// The open island's weather page: now, big, and the next six hours.
struct IslandWeatherPage: View {
    let report: WeatherService.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: report.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 30))
                    .frame(width: 40)
                Text("\(report.temperature)°")
                    .font(.system(size: 38, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(report.condition.isEmpty ? " " : report.condition)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text([report.place, "H:\(report.high)°  L:\(report.low)°"].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
            }
            if !report.hours.isEmpty {
                HStack(spacing: 0) {
                    ForEach(report.hours) { hour in
                        VStack(spacing: 5) {
                            Text(hour.time, format: .dateTime.hour())
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            Image(systemName: hour.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 15))
                                .frame(height: 17)
                            Text("\(hour.temperature)°")
                                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
