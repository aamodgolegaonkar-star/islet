import AppKit
import SwiftUI

/// Settings → Android Phone: get the app, pair, and choose what the phone and Mac share.
struct PhonePane: View {
    let link: LinkController
    @State private var installing = false
    @State private var installResult: String?
    @State private var trusted = LinkRemote.trusted
    private var reveal: Animation { IslandMotion.subtle }

    var body: some View {
        @Bindable var settings = link.settings
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "smartphone")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient(
                        colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Islet for Android").font(.headline)
                    Text("Your phone's notifications, calls, music and battery in the island. Your Mac's music on the phone's lock screen. Files at full quality, a shared clipboard, and the phone as a remote for this Mac. Over Wi-Fi, USB or Bluetooth, encrypted end to end.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            Toggle("Connect to my Android phone", isOn: $settings.enabled.animation(reveal))
        }

        if settings.enabled {
            if let pending = link.pendingPairing {
                Section {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pair \(pending.name)?").font(.headline)
                            Text("Pair only if your phone shows the same code.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(pending.code).font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    HStack {
                        Spacer()
                        Button("Not Now") { link.answerPairing(false) }
                        Button("Pair") { link.answerPairing(true) }.keyboardShortcut(.defaultAction)
                    }
                } header: {
                    Text("Pairing")
                }
            }

            Section {
                if link.devices.isEmpty {
                    Text("Open Islet on your phone and tap this Mac (\(link.macName)). Both screens then show the same six digits.")
                        .foregroundStyle(.secondary)
                }
                ForEach(link.devices) { device in
                    LabeledContent {
                        Button("Forget") { link.forget(device) }
                    } label: {
                        Label(device.name, systemImage: "smartphone")
                        Text(status(of: device))
                    }
                }
            } header: {
                Text("Phones")
            }

            appSection

            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Phone Mirroring")
                        Text("Use your phone in a window on this Mac: click to tap, scroll, and type with the keyboard. ⌘1 goes home, ⌘[ goes back. While it's mirrored the phone shows that it's in use; using it ends mirroring and locks it. Plug the phone in over USB, unlocked.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(link.mirror.running ? "Stop" : "Mirror Phone") { link.mirror.toggle() }
                        .disabled(LinkUSB.adbPath == nil)
                }
            }

            Section {
                Toggle("Show notifications in the island", isOn: $settings.showNotifications)
                Toggle("Show incoming calls", isOn: $settings.showCalls)
                Toggle("Pause music during calls", isOn: $settings.pauseForCalls)
            } header: {
                Text("In the island")
            } footer: {
                Text("Reply, answer or decline from the island. The phone button beside the open island shows its battery and opens the phone page.")
            }

            Section {
                Toggle("Shared clipboard", isOn: $settings.syncClipboard)
                Toggle("Let the phone control this Mac", isOn: $settings.allowRemote.animation(reveal))
                if settings.allowRemote, !trusted {
                    LabeledContent("Trackpad and keyboard need Accessibility access") {
                        Button("Allow…") {
                            LinkRemote.askForAccess()
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                trusted = LinkRemote.trusted
                            }
                        }
                    }
                }
            } header: {
                Text("Sharing and control")
            } footer: {
                Text("Copied passwords are never shared. The phone can play music, change volume and brightness, lock or sleep the Mac, run Shortcuts, and work as a trackpad and keyboard.")
            }

            Section {
                LabeledContent("Wi-Fi") {
                    Text(link.problem ?? "Listening").foregroundStyle(link.problem == nil ? Color.secondary : .orange)
                }
                LabeledContent("USB") {
                    Text(LinkUSB.adbPath == nil ? "Needs Android platform-tools" : link.usb.forwarding ? "Phone connected" : "Plug in a phone with USB debugging on")
                        .foregroundStyle(.secondary)
                }
                Toggle("Bluetooth when there's no Wi-Fi", isOn: $settings.useBluetooth)
            } header: {
                Text("Connections")
            } footer: {
                Text("Islet picks the fastest link: USB, then Wi-Fi, then Bluetooth. Bluetooth is slower, so large files wait for Wi-Fi or USB.")
            }
        }
    }

    @ViewBuilder
    private var appSection: some View {
        Section {
            if let url = link.downloadURL, let qr = PortalController.qrCode(for: url) {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 130, height: 130)
                        .padding(8)
                        .background(.white, in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scan with your phone's camera").font(.headline)
                        Text("It downloads Islet from this Mac over your Wi-Fi. Open the file to install it; Android asks you to allow installs from your browser once.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if let apk = LinkController.bundledAPK {
                LabeledContent("Install over USB") {
                    HStack {
                        if let installResult { Text(installResult).foregroundStyle(.secondary).lineLimit(2) }
                        Button(installing ? "Installing…" : "Install") {
                            installing = true
                            Task { @MainActor in
                                let result = await link.usb.install(apk: apk)
                                installResult = result.message
                                installing = false
                            }
                        }
                        .disabled(installing || LinkUSB.adbPath == nil)
                    }
                }
                Button("Show the App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([apk]) }
            } else {
                Text("The Android app isn't bundled in this build of Islet.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Get the app")
        }
    }

    private func status(of device: LinkDevice) -> String {
        if let phone = link.phone, phone.id == device.id {
            return "Connected over \(phone.transport.label)" + (phone.battery.map { " · \($0)%" } ?? "")
        }
        return device.model.isEmpty ? "Not connected" : "\(device.model) · Not connected"
    }
}
