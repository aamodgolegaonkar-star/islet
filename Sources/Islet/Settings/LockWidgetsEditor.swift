import IsletCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Lock Screen: the row under the clock, edited by drag and drop. Drag tiles
/// to reorder them, drag widgets up from the tray to add them, and back down (or click
/// their − badge) to remove them.
struct LockWidgetsEditor: View {
    @Bindable var settings: AppSettings
    /// The widget being dragged, from the row or the tray.
    @State private var dragging: LockWidget?

    var body: some View {
        LockWidgetsCanvas(settings: settings, dragging: $dragging)
            .listRowInsets(EdgeInsets())
            .onChange(of: settings.lockWidgets.contains(.weather)) { _, added in
                if added { WeatherService.shared.requestAccess() }
            }
        LockWidgetsTray(settings: settings, dragging: $dragging)
        if settings.lockWidgets.contains(.worldClock) {
            Picker("World Clock city", selection: $settings.worldClockZone) {
                ForEach(WorldClockTile.zones, id: \.id) { zone in
                    Text(zone.city).tag(zone.id)
                }
            }
        }
    }
}

private var editSpring: Animation { IslandMotion.subtle }

// MARK: - The row

/// The lock screen in miniature: the clock and the live row, scaled to fit the pane.
private struct LockWidgetsCanvas: View {
    @Bindable var settings: AppSettings
    @Binding var dragging: LockWidget?

    var body: some View {
        GeometryReader { geo in
            let scale = min(1, (geo.size.width - 40) / LockWidget.rowWidth)
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.36), Color(red: 0.42, green: 0.22, blue: 0.38)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 10) {
                    TimelineView(.everyMinute) { context in
                        Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                            .font(.system(size: 46, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    row
                        .fixedSize()
                        .scaleEffect(scale)
                        .frame(width: LockWidget.rowWidth * scale, height: 66 * scale)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onDrop(of: [.text], delegate: RowDrop(widgets: $settings.lockWidgets, dragging: $dragging))
        }
        .frame(height: 176)
        .clipped()
    }

    @ViewBuilder
    private var row: some View {
        if settings.lockWidgets.isEmpty {
            Text("Drag widgets here")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 300, height: 66)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        } else {
            HStack(spacing: LockWidget.spacing) {
                ForEach(settings.lockWidgets) { widget in
                    EditableTile(widget: widget, settings: settings, isDragged: dragging == widget) {
                        withAnimation(editSpring) { settings.lockWidgets.removeAll { $0 == widget } }
                    }
                    .onDrag {
                        dragging = widget
                        return NSItemProvider(object: widget.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: TileDrop(target: widget, widgets: $settings.lockWidgets, dragging: $dragging))
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .animation(editSpring, value: settings.lockWidgets)
        }
    }
}

/// A tile in the editor: sample content, with a − badge on hover.
private struct EditableTile: View {
    let widget: LockWidget
    let settings: AppSettings
    let isDragged: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        LockWidgetSample(widget: widget, settings: settings)
            .opacity(isDragged ? 0.35 : 1)
            .overlay(alignment: .topLeading) {
                if hovering, !isDragged {
                    Button(action: remove) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -4, y: -4)
                    .help("Remove \(widget.title)")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .onHover { over in withAnimation(IslandMotion.quick) { hovering = over } }
            .help("Drag to move, or drag down to the tray to remove")
    }
}

// MARK: - The tray

/// Widgets not in the row. Drag one up (or click it) to add it; drag a tile down here to
/// remove it.
private struct LockWidgetsTray: View {
    @Bindable var settings: AppSettings
    @Binding var dragging: LockWidget?
    @State private var targeted = false

    private var available: [LockWidget] {
        LockWidget.allCases.filter { !settings.lockWidgets.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(available) { widget in
                    chip(widget)
                }
            }
            .animation(editSpring, value: available)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(targeted ? 0.12 : 0))
            .padding(-6))
        .onDrop(of: [.text], delegate: TrayDrop(widgets: $settings.lockWidgets, dragging: $dragging, targeted: $targeted))
    }

    private var caption: String {
        if available.isEmpty { return "Every widget is in use. Drag one here to remove it." }
        if available.allSatisfy({ !LockWidget.fits($0, after: settings.lockWidgets) }) {
            return "The row is full. Drag a widget here to make room."
        }
        return "Drag widgets up to add them, and back here to remove them."
    }

    private func chip(_ widget: LockWidget) -> some View {
        let fits = LockWidget.fits(widget, after: settings.lockWidgets)
        return HStack(spacing: 7) {
            Image(systemName: widget.symbol)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(widget.title).font(.callout.weight(.medium))
                if let note = widget.note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: 46)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(fits ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture {
            guard fits else { return }
            withAnimation(editSpring) { settings.lockWidgets.append(widget) }
        }
        .onDrag {
            dragging = widget
            return NSItemProvider(object: widget.rawValue as NSString)
        }
        .help(fits ? "Drag into the row, or click to add" : "No room. Remove a widget first")
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Drop handling

/// Hovering a dragged widget over a tile moves it there (or inserts it, from the tray).
private struct TileDrop: DropDelegate {
    let target: LockWidget
    @Binding var widgets: [LockWidget]
    @Binding var dragging: LockWidget?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target, let to = widgets.firstIndex(of: target) else { return }
        withAnimation(editSpring) {
            if let from = widgets.firstIndex(of: dragging) {
                widgets.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
            } else if LockWidget.fits(dragging, after: widgets) {
                widgets.insert(dragging, at: to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Dropping in the row's empty space adds a widget from the tray at the end.
private struct RowDrop: DropDelegate {
    @Binding var widgets: [LockWidget]
    @Binding var dragging: LockWidget?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil }
        guard let dragging, !widgets.contains(dragging), LockWidget.fits(dragging, after: widgets) else { return true }
        withAnimation(editSpring) { widgets.append(dragging) }
        return true
    }
}

/// Dropping a tile on the tray removes it from the row.
private struct TrayDrop: DropDelegate {
    @Binding var widgets: [LockWidget]
    @Binding var dragging: LockWidget?
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { dragging.map(widgets.contains) ?? false }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        defer { dragging = nil }
        guard let dragging else { return false }
        withAnimation(editSpring) { widgets.removeAll { $0 == dragging } }
        return true
    }
}

// MARK: - Sample tiles

/// A widget with sample values (the real ones appear on the lock screen).
struct LockWidgetSample: View {
    let widget: LockWidget
    let settings: AppSettings

    var body: some View {
        switch widget {
        case .weather:
            circle(WeatherTile(report: .init(temperature: 21, high: 24, low: 15, symbol: "cloud.sun.fill", fetched: .now)))
        case .battery:
            circle(BatteryRing(battery: BatteryState(level: 0.8, isCharging: false, isPluggedIn: false)))
        case .nowPlaying:
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Song Title").font(.system(size: 13, weight: .semibold))
                    Text("Artist").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 50, height: 3) }
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(width: widget.width, height: 66)
            .snapshotSafeGlass(.islet, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        case .volume:
            circle(VolumeRing(level: 0.6))
        case .headphones:
            circle(HeadphoneRing(status: HeadphoneStatus(name: "Headphones", symbol: "airpods.pro",
                                                         battery: HeadphoneBattery(left: 90, right: 90))))
        case .date:
            circle(DateTile())
        case .worldClock:
            circle(WorldClockTile(zone: TimeZone(identifier: settings.worldClockZone) ?? .current))
        case .cpu:
            circle(CPURing(load: 0.35))
        case .focus:
            circle(FocusTile(mode: FocusMode(identifier: "com.apple.focus.work", name: "Work",
                                             symbol: "person.lanyardcard.fill", tint: "systemTealColor")))
        }
    }

    private func circle(_ content: some View) -> some View {
        content
            .frame(width: 66, height: 66)
            .snapshotSafeGlass(.islet, in: Circle())
            .contentShape(Circle())
    }
}
