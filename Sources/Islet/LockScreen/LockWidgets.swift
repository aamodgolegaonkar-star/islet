import Darwin
import IsletCore
import SwiftUI

/// One widget of the lock-screen row, drawn the same on the lock screen and in the
/// Settings preview. Returns nothing when the widget has nothing to show right now
/// (no headphones connected, no battery, nothing playing), so the row closes up.
struct LockWidgetTile: View {
    let widget: LockWidget
    let store: PlayerStore
    @Bindable var model: LockModel
    let settings: AppSettings

    var body: some View {
        switch widget {
        case .weather:
            if let weather = model.weather {
                WeatherTile(report: weather).circleTile()
            }
        case .battery:
            if let battery = model.battery {
                BatteryRing(battery: battery).circleTile()
            }
        case .nowPlaying:
            if store.hasTrack {
                NowPlayingMini(store: store, model: model)
                    .frame(width: widget.width, height: 66)
                    .lockGlass(cornerRadius: 24)
            }
        case .volume:
            VolumeRing(level: store.volume).circleTile()
        case .headphones:
            if let headphones = model.headphones {
                HeadphoneRing(status: headphones).circleTile()
            }
        case .date:
            DateTile().circleTile()
        case .worldClock:
            WorldClockTile(zone: TimeZone(identifier: settings.worldClockZone) ?? .current).circleTile()
        case .cpu:
            CPURing(load: model.cpuLoad ?? 0).circleTile()
        case .focus:
            if let focus = model.focus {
                FocusTile(mode: focus).circleTile()
            }
        }
    }
}

private extension View {
    func circleTile() -> some View {
        frame(width: 66, height: 66)
            .lockGlass(cornerRadius: 33)
            .transition(.scale.combined(with: .opacity))
    }
}

/// Today: the weekday over the day of the month, like the Calendar icon.
struct DateTile: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: -1) {
                Text(context.date, format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.red)
                Text(context.date, format: .dateTime.day())
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .padding(8)
    }
}

/// The time in another city, with its name and how far it is from here.
struct WorldClockTile: View {
    let zone: TimeZone

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 1) {
                Text(Self.city(of: zone))
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(context.date, format: Self.time(in: zone))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Self.offset(of: zone, at: context.date))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(9)
    }

    static func city(of zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier)
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func time(in zone: TimeZone) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
        style.timeZone = zone
        return style
    }

    /// "+4h", "−30m", "Same time".
    static func offset(of zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        if seconds == 0 { return "Same time" }
        let sign = seconds > 0 ? "+" : "−"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        if minutes == 0 { return "\(sign)\(hours)h" }
        return hours == 0 ? "\(sign)\(minutes)m" : "\(sign)\(hours):\(String(format: "%02d", minutes))"
    }

    /// Time zones for the picker, by city name.
    static let zones: [(id: String, city: String)] = TimeZone.knownTimeZoneIdentifiers
        .filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
        .compactMap { id in TimeZone(identifier: id).map { (id, city(of: $0)) } }
        .sorted { $0.city < $1.city }
}

/// How busy the processor is, as a ring.
struct CPURing: View {
    let load: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: 5)
            Circle()
                .trim(from: 0, to: load)
                .stroke(load > 0.85 ? Color.orange : .white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("CPU")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                Text("\(Int((load * 100).rounded()))")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .padding(10)
        .animation(.easeInOut(duration: 0.6), value: load)
    }
}

/// Whole-machine CPU load from the kernel's tick counters, measured between samples.
@MainActor
final class CPULoadSampler {
    private var last: (busy: UInt64, total: UInt64)?

    /// 0…1 since the previous call; nil on the first call.
    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let user = UInt64(ticks.0), system = UInt64(ticks.1), idle = UInt64(ticks.2), nice = UInt64(ticks.3)
        let now = (busy: user + system + nice, total: user + system + idle + nice)
        defer { last = now }
        guard let last, now.total > last.total else { return nil }
        return min(max(Double(now.busy - last.busy) / Double(now.total - last.total), 0), 1)
    }
}

/// The Focus mode that's on: its icon in its colour over its name.
struct FocusTile: View {
    let mode: FocusMode

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: mode.displaySymbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(mode.color)
                .contentTransition(.symbolEffect(.replace))
            Text(mode.name)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(8)
    }
}
