import AppKit
import SwiftUI

// MARK: - Cards

/// The island's card for something on the phone.
struct PhoneAlertContent: View {
    let alert: PhoneAlert
    let link: LinkController?
    var topInset: CGFloat = 0
    let openPage: () -> Void

    var body: some View {
        Group {
            switch alert {
            case let .notification(note):
                // Like iPhone Mirroring, a phone notification opens its app in the mirror when it can.
                PhoneNotificationCard(note: note, link: link) {
                    if let link, link.mirror.available { link.mirror.open(app: note.package) } else { openPage() }
                }
            case let .call(note): PhoneCallCard(note: note, link: link)
            case let .pairing(name, code): PhonePairingCard(name: name, code: code, link: link)
            case let .transfer(name, progress, incoming): PhoneTransferCard(name: name, progress: progress, incoming: incoming)
            }
        }
        .padding(.top, topInset)
    }
}

/// An app's icon from the phone, or a neutral glyph until one arrives.
struct PhoneAppIcon: View {
    let icon: NSImage?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(.white.opacity(0.14))
                    Image(systemName: "bell.fill").font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct PhoneNotificationCard: View {
    let note: PhoneNotification
    let link: LinkController?
    let open: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                PhoneAppIcon(icon: note.icon)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(note.app.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .tracking(0.4)
                        Text(note.time, style: .time)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer(minLength: 0)
                    }
                    Text(note.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(note.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                .offset(x: appeared ? 0 : 8)
                .opacity(appeared ? 1 : 0)
            }
            .contentShape(Rectangle())
            .routedClick("phone.note.open", action: open)
            if !note.actions.isEmpty {
                HStack(spacing: 6) {
                    Spacer().frame(width: 46)
                    ForEach(note.actions.prefix(3), id: \.index) { action in
                        PhoneActionChip(title: action.title, symbol: action.reply ? "arrowshape.turn.up.left.fill" : nil,
                                        id: "phone.note.action.\(action.index)") {
                            if action.reply {
                                PhoneReplyPanel.show(note: note, action: action, link: link)
                            } else {
                                link?.act(on: note, action: action)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .opacity(appeared ? 1 : 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .onAppear { withAnimation(IslandMotion.playful.delay(0.05)) { appeared = true } }
    }
}

/// A small capsule button on a phone card.
struct PhoneActionChip: View {
    let title: String
    var symbol: String?
    var tint: Color = .white
    let id: String
    let action: () -> Void
    @Environment(\.clickRouter) private var router

    var body: some View {
        RoutedButton(id, action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(tint == .white ? .white.opacity(0.92) : .white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint == .white ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(tint.gradient)))
            .scaleEffect(router?.pressed == id ? 0.92 : 1)
            .animation(IslandMotion.quick, value: router?.pressed == id)
        }
    }
}

/// An incoming call, like the iPhone's: who it is, and decline or answer.
struct PhoneCallCard: View {
    let note: PhoneNotification
    let link: LinkController?
    @State private var ringing = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.green.opacity(0.5), lineWidth: 2)
                    .scaleEffect(ringing ? 1.45 : 1)
                    .opacity(ringing ? 0 : 0.9)
                Circle().fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.32)], startPoint: .top, endPoint: .bottom))
                Text(initials)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(note.text.isEmpty ? "Incoming call" : note.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let decline {
                callButton(symbol: "phone.down.fill", tint: .red, id: "phone.call.decline") { link?.act(on: note, action: decline) }
            }
            if let answer {
                callButton(symbol: "phone.fill", tint: .green, id: "phone.call.answer") { link?.act(on: note, action: answer) }
                    .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 1.2)), value: ringing)
            }
        }
        .padding(.horizontal, 20)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { ringing = true }
        }
    }

    private var initials: String {
        let letters = note.title.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty || note.title.first?.isNumber == true ? "☎︎" : String(letters).uppercased()
    }

    private func find(_ words: [String]) -> PhoneNotification.Action? {
        note.actions.first { action in words.contains { action.title.lowercased().contains($0) } }
    }

    private var decline: PhoneNotification.Action? { find(["decline", "hang up", "reject", "end"]) }
    private var answer: PhoneNotification.Action? { find(["answer", "accept"]) }

    private func callButton(symbol: String, tint: Color, id: String, action: @escaping () -> Void) -> some View {
        RoutedButton(id, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint.gradient))
        }
    }
}

/// Pairing: the same six digits must be on both screens.
struct PhonePairingCard: View {
    let name: String
    let code: String
    let link: LinkController?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "smartphone")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pair \(name)?")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Check your phone shows the same code")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                Text(spaced)
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .tracking(1)
            }
            HStack(spacing: 8) {
                Spacer()
                PhoneActionChip(title: "Not Now", id: "phone.pair.no") { link?.answerPairing(false) }
                PhoneActionChip(title: "Pair", symbol: "checkmark", tint: .blue, id: "phone.pair.yes") { link?.answerPairing(true) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var spaced: String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }
}

/// A file going to or from the phone.
struct PhoneTransferCard: View {
    let name: String
    let progress: Double
    let incoming: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white, .blue)
                .symbolEffect(.pulse, isActive: progress < 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.numericText())
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geometry.size.width * progress))
                    }
                }
                .frame(height: 5)
                .animation(.easeOut(duration: 0.25), value: progress)
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Phone page

/// The open island's phone page: battery and link, what the phone plays, its latest
/// notifications, and quick actions.
/// A phone Live Activity in the resting island: the app's icon, then its short status, a
/// running clock, or progress.
struct PhoneLiveCompact: View {
    let live: PhoneLive

    var body: some View {
        HStack(spacing: 8) {
            PhoneAppIcon(icon: live.icon, size: 18)
            Spacer(minLength: 0)
            trailing
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var trailing: some View {
        if let clock = live.chronometer {
            PhoneLiveClock(start: clock, countdown: live.countdown)
        } else if let progress = live.progress {
            HStack(spacing: 6) {
                Text("\(Int(progress * 100))%").contentTransition(.numericText())
                PhoneLiveRing(progress: progress)
            }
            .animation(IslandMotion.quick, value: progress)
        } else {
            Text(live.compactText).truncationMode(.tail)
        }
    }
}

/// A Live Activity's clock: one redraw a second, and only while it shows.
struct PhoneLiveClock: View {
    let start: Date
    let countdown: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int((countdown ? start.timeIntervalSince(context.date) : context.date.timeIntervalSince(start)).rounded(.down)))
            Text(seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                                 : String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }
}

struct PhoneLiveRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress).stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
    }
}

/// A Live Activity on the phone page: what it is, how it's going, and a click to open it.
struct PhoneLiveRow: View {
    let live: PhoneLive
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            PhoneAppIcon(icon: live.icon, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(live.title.isEmpty ? live.app : live.title)
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 0)
                    if let clock = live.chronometer {
                        PhoneLiveClock(start: clock, countdown: live.countdown)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    }
                }
                if !live.text.isEmpty {
                    Text(live.text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                if let progress = live.progress {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(.white).controlSize(.mini)
                } else if live.indeterminate {
                    ProgressView().progressViewStyle(.linear).tint(.white).controlSize(.mini)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
        .contentShape(Rectangle())
        .routedClick("phone.live.row", action: open)
    }
}

struct PhonePageView: View {
    let link: LinkController
    let model: IslandModel
    var notchHeight: CGFloat?
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let phone = link.phone {
                header(phone)
                if let media = phone.media {
                    PhoneMediaRow(media: media, link: link)
                }
                if let live = phone.live.first {
                    PhoneLiveRow(live: live) { link.openLive(live) }
                }
                notifications(phone)
                Spacer(minLength: 0)
                actions
            } else {
                empty
            }
        }
        .padding(.top, (notchHeight ?? 0) + 12)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func header(_ phone: ConnectedPhone) -> some View {
        HStack(spacing: 10) {
            PhoneBatteryGlyph(level: phone.battery, charging: phone.charging, size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(phone.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: phone.transport.symbol).font(.system(size: 9, weight: .bold))
                    Text(statusLine(phone))
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            IslandPillButton(label: nil, symbol: "chevron.backward", help: "Back", id: "phone.back", diameter: 28, action: back)
        }
    }

    private func statusLine(_ phone: ConnectedPhone) -> String {
        var parts = ["Connected over \(phone.transport.label)"]
        if let battery = phone.battery { parts.append("\(battery)%\(phone.charging ? " charging" : "")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func notifications(_ phone: ConnectedPhone) -> some View {
        let recent = phone.notifications.filter { !$0.isCall }.prefix((phone.media == nil ? 3 : 2) - (phone.live.isEmpty ? 0 : 1))
        if recent.isEmpty {
            Text("No new notifications")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 6) {
                ForEach(Array(recent)) { note in
                    HStack(spacing: 9) {
                        PhoneAppIcon(icon: note.icon, size: 22)
                        Text(note.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            .layoutPriority(1)
                        Text(note.text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let reply = note.actions.first(where: \.reply) {
                            RoutedButton("phone.page.reply.\(note.id)", action: {
                                PhoneReplyPanel.show(note: note, action: reply, link: link)
                            }) {
                                Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.7)).frame(width: 20, height: 20)
                            }
                        }
                        RoutedButton("phone.page.dismiss.\(note.id)", action: { withAnimation(IslandMotion.quick) { link.dismiss(note) } }) {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5)).frame(width: 20, height: 20)
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            IslandPillButton(label: link.ringing ? "Stop" : "Ring",
                             symbol: link.ringing ? "bell.slash.fill" : "bell.and.waves.left.and.right.fill",
                             help: link.ringing ? "Stop ringing" : "Ring your phone", id: "phone.ring", action: link.ringPhone)
            if LinkUSB.adbPath != nil {
                IslandPillButton(label: link.mirror.streaming ? "Stop" : "Mirror", symbol: "rectangle.portrait.on.rectangle.portrait.fill",
                                 help: link.mirror.streaming ? "Stop mirroring" : "Use your phone on this Mac", id: "phone.mirror",
                                 action: link.mirror.toggle)
            }
            action("Send Files…", symbol: "paperplane.fill", id: "phone.files", run: link.chooseFilesToSend)
            action("Send Clipboard", symbol: "doc.on.clipboard.fill", id: "phone.clip", run: link.sendClipboard)
            Spacer(minLength: 0)
            action("Phone Settings", symbol: "gearshape.fill", id: "phone.settings") {
                NotificationCenter.default.post(name: .openSettingsPane, object: "phone")
            }
        }
    }

    private func action(_ help: String, symbol: String, id: String, run: @escaping () -> Void) -> some View {
        IslandPillButton(label: help.hasSuffix("…") || help == "Ring" ? help : nil, symbol: symbol, help: help, id: id,
                         diameter: help.hasSuffix("…") || help == "Ring" ? nil : 28, action: run)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "smartphone")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.75))
            Text(link.devices.isEmpty ? "Connect your Android phone" : "\(link.devices.last?.name ?? "Your phone") isn't connected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(link.devices.isEmpty
                 ? "Install Islet on the phone, open it, and tap this Mac."
                 : "Open Islet on the phone, or plug it in with USB.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                IslandPillButton(label: "Back", symbol: "chevron.backward", help: "Back", id: "phone.back", action: back)
                IslandPillButton(label: "Set Up…", symbol: "gearshape.fill", help: "Phone Settings", id: "phone.setup") {
                    NotificationCenter.default.post(name: .openSettingsPane, object: "phone")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Notification.Name {
    /// Opens Settings at a pane (`object` is the pane's raw value).
    static let openSettingsPane = Notification.Name("IsletOpenSettingsPane")
}

/// What the phone is playing, with its controls.
struct PhoneMediaRow: View {
    let media: PhoneMedia
    let link: LinkController

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let art = media.art {
                    Image(nsImage: art).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(.rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: media.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(media.artist.isEmpty ? media.app : "\(media.artist) · \(media.app)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fraction = media.duration > 0 ? media.elapsed(at: context.date) / media.duration : 0
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(.white.opacity(0.8)).frame(width: geometry.size.width * fraction)
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.top, 3)
            }
            .layoutPriority(1)
            HStack(spacing: 2) {
                button("backward.fill", id: "phone.media.prev") { link.phoneMediaCommand("previous") }
                button(media.playing ? "pause.fill" : "play.fill", id: "phone.media.play", size: 16) { link.phoneMediaCommand("toggle") }
                button("forward.fill", id: "phone.media.next") { link.phoneMediaCommand("next") }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
    }

    private func button(_ symbol: String, id: String, size: CGFloat = 12, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(GlassIconButtonStyle(diameter: 30, look: .highlight))
        .routedClick(id, action: run)
    }
}

/// The phone's battery as a ring around a phone.
struct PhoneBatteryGlyph: View {
    let level: Int?
    let charging: Bool
    var size: CGFloat = 40
    var connected = true

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: 2.5)
            if let level, connected {
                Circle()
                    .trim(from: 0, to: CGFloat(level) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(IslandMotion.subtle, value: level)
            }
            Image(systemName: charging && connected ? "bolt.fill" : "smartphone")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(charging && connected ? .green : .white.opacity(connected ? 0.92 : 0.45))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
    }

    private var tint: Color {
        guard let level else { return .white }
        if charging { return .green }
        return level <= 20 ? .red : .white
    }
}

/// The round phone button that floats beside the open island, its battery as a ring.
struct PhoneBubble: View {
    let link: LinkController
    let isOpen: Bool
    let action: () -> Void
    @Environment(\.clickRouter) private var router
    @State private var hovering = false

    var body: some View {
        RoutedButton("island.phone", action: action) {
            PhoneBatteryGlyph(level: link.phone?.battery, charging: link.phone?.charging ?? false,
                              size: 30, connected: link.phone != nil)
                .overlay(alignment: .topTrailing) {
                    let count = link.phone?.notifications.filter { !$0.isCall }.count ?? 0
                    if count > 0, !isOpen {
                        Text("\(min(count, 9))")
                            .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Circle().fill(.red))
                            .offset(x: 6, y: -6)
                    }
                }
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(isOpen ? 0.22 : hovering ? 0.16 : 0.0001)))
                .scaleEffect(router?.pressed == "island.phone" ? 0.9 : 1)
                .animation(IslandMotion.quick, value: router?.pressed == "island.phone")
        }
        .onHover { hovering = $0 }
        .help(link.phone.map { "\($0.name)\($0.battery.map { " · \($0)%" } ?? "")" } ?? "Phone")
    }
}

// MARK: - Quick reply

/// A small window for typing a reply to a phone notification. The island never takes
/// keyboard focus, so replies get their own key window right under it.
@MainActor
enum PhoneReplyPanel {
    private static var panel: NSPanel?

    static func show(note: PhoneNotification, action: PhoneNotification.Action, link: LinkController?) {
        panel?.close()
        let panel = ReplyWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                                styleMask: [.titled, .closable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ReplyView(note: note) { text in
            link?.act(on: note, action: action, reply: text)
            panel.close()
        } cancel: {
            panel.close()
        })
        if let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.frame.midX - 190, y: screen.frame.maxY - 230))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private final class ReplyWindow: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private struct ReplyView: View {
        let note: PhoneNotification
        let send: (String) -> Void
        let cancel: () -> Void
        @State private var text = ""
        @FocusState private var focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PhoneAppIcon(icon: note.icon, size: 22)
                    Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                }
                Text(note.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    TextField("Reply", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { if !text.isEmpty { send(text) } }
                    Button("Send") { send(text) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.isEmpty)
                }
            }
            .padding(16)
            .padding(.top, 8)
            .onAppear { focused = true }
            .onExitCommand(perform: cancel)
        }
    }
}
