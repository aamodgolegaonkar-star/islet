import SwiftUI

/// The Standby screen: a huge clock in the theme's colors on black, with the song, the
/// weather and the battery beside it. Everything rises into place when it appears; the
/// background is a few slow, dim glows of the theme, drawn as plain gradients (no blur
/// filters), so a whole night of it costs almost nothing.
struct StandbyView: View {
    let model: StandbyModel
    let store: PlayerStore
    let settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: AccentTheme { settings.accentTheme }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack {
                Color.black
                ambient(geo.size)
                HStack(alignment: .center, spacing: height * 0.08) {
                    clock(height: height)
                    if hasSide {
                        side(height: height)
                    }
                }
                .padding(.horizontal, height * 0.1)
                .offset(model.drift)
                .opacity(nightDim)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(IslandMotion.panel, value: store.hasTrack)
        .animation(IslandMotion.panel, value: theme)
    }

    private var hasSide: Bool { store.hasTrack || model.weather != nil || model.battery != nil }

    /// Late at night the whole screen dims, like a bedside clock.
    private var nightDim: Double {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 23 || hour < 6 ? 0.55 : 1
    }

    // MARK: - Clock

    private func clock(height: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let date = context.date
            VStack(alignment: .leading, spacing: height * 0.01) {
                Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: height * 0.3, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(-height * 0.006)
                    .foregroundStyle(theme.gradient)
                    .contentTransition(.numericText(countsDown: false))
                    .animation(IslandMotion.playful, value: Calendar.current.component(.minute, from: date))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: height * 0.035, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, height * 0.012)
            }
            .rise(model.shown, order: 0, reduceMotion: reduceMotion)
        }
    }

    // MARK: - Side cards

    private func side(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: height * 0.03) {
            if store.hasTrack {
                nowPlaying(height: height)
                    .rise(model.shown, order: 1, reduceMotion: reduceMotion)
                    .transition(.blurReplace)
            }
            HStack(spacing: height * 0.025) {
                if let weather = model.weather {
                    card {
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: weather.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: height * 0.04))
                            Text("\(weather.temperature)°")
                                .font(.system(size: height * 0.055, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("H \(weather.high)°  L \(weather.low)°")
                                .font(.system(size: height * 0.018, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .rise(model.shown, order: 2, reduceMotion: reduceMotion)
                }
                if let battery = model.battery {
                    card { batteryRing(battery, size: height * 0.12) }
                        .rise(model.shown, order: 3, reduceMotion: reduceMotion)
                }
            }
        }
        .frame(maxWidth: height * 0.5, alignment: .leading)
    }

    private func nowPlaying(height: CGFloat) -> some View {
        card(stretch: true) {
            HStack(spacing: height * 0.022) {
                CoverArtView(image: store.artwork)
                    .frame(width: height * 0.11, height: height * 0.11)
                    .clipShape(.rect(cornerRadius: height * 0.018, style: .continuous))
                    .scaleEffect(store.isPlaying ? 1 : 0.92)
                    .animation(IslandMotion.playful, value: store.isPlaying)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.title)
                        .font(.system(size: height * 0.026, weight: .semibold))
                    Text(store.subtitle)
                        .font(.system(size: height * 0.021))
                        .foregroundStyle(.white.opacity(0.6))
                    PlaybackClock(timing: store.timing, steps: 2) { date in
                        let duration = store.duration
                        let fraction = duration > 0 ? store.elapsed(at: date) / duration : 0
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.18))
                                Capsule().fill(theme.gradient)
                                    .frame(width: bar.size.width * min(max(fraction, 0), 1))
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(.top, 6)
                }
                .lineLimit(1)
                .contentTransition(.interpolate)
            }
        }
    }

    private func batteryRing(_ battery: BatteryState, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: size * 0.09)
            Circle()
                .trim(from: 0, to: battery.level)
                .stroke(theme.ring, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Image(systemName: battery.isCharging ? "bolt.fill" : "powerplug.fill")
                    .font(.system(size: size * 0.16, weight: .bold))
                    .foregroundStyle(theme.tint)
                    .symbolEffect(.pulse, options: .repeat(reduceMotion ? 0 : 2), value: battery.isCharging)
                Text("\(Int((battery.level * 100).rounded()))%")
                    .font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(width: size, height: size)
        .animation(IslandMotion.panel, value: battery)
    }

    private func card<Content: View>(stretch: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: stretch ? .infinity : nil, alignment: .leading)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
    }

    // MARK: - Background

    private func ambient(_ size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 0.04
            ZStack {
                ForEach(Array(theme.colors.enumerated()), id: \.offset) { index, color in
                    let phase = t + Double(index) * 2.1
                    RadialGradient(colors: [color.opacity(0.22), .clear], center: .center,
                                   startRadius: 0, endRadius: size.height * 0.55)
                        .frame(width: size.height * 1.1, height: size.height * 1.1)
                        .offset(x: cos(phase) * size.width * 0.3, y: sin(phase * 1.3) * size.height * 0.25)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .opacity(model.shown ? 1 : 0)
        .animation(.easeOut(duration: 1.6), value: model.shown)
    }
}

private extension View {
    /// Rises out of a soft blur into place, each piece a beat after the one before.
    func rise(_ shown: Bool, order: Int, reduceMotion: Bool) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 10)
            .offset(y: shown || reduceMotion ? 0 : 24)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: .bottom)
            .animation(IslandMotion.playful.delay(reduceMotion ? 0 : Double(order) * 0.07), value: shown)
    }
}
