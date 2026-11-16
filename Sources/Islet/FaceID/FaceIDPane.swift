import AVFoundation
import IsletCore
import SwiftUI

/// Settings → Face ID.
struct FaceIDPane: View {
    @Bindable var settings: AppSettings
    let faceID: FaceIDController
    @State private var password = ""
    @State private var passwordError: String?
    @State private var changingPassword = false
    @State private var faceName = ""
    @State private var confirmForget = false
    @State private var refresh = 0
    private var reveal: Animation { IslandMotion.subtle }

    var body: some View {
        let _ = refresh
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "faceid")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Face ID for your Mac").font(.headline)
                    Text("Look at your Mac to unlock it. It types your password into the lock screen for you. Your face never leaves this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            Label {
                Text("Face ID is for convenience, not security. Your Mac's camera can't see depth, so it can't always tell you from a picture of you. Keep it off on any Mac that holds anything you can't afford to lose.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            Toggle("Unlock with Face ID", isOn: $settings.faceIDEnabled.animation(reveal))
                .disabled(!settings.faceIDEnabled && !(faceID.isReady && faceID.cameraAllowed && faceID.accessibilityAllowed))
        } footer: {
            if !settings.faceIDEnabled && !faceID.isReady {
                Text("Set up below first: allow the camera and Accessibility, save your password and add your face.")
            }
        }

        Section {
            permissionRow("Camera", "To see your face.", allowed: faceID.cameraAllowed) {
                Task { _ = await faceID.requestCamera(); refresh += 1 }
            }
            permissionRow("Accessibility", "To type your password into the lock screen.", allowed: faceID.accessibilityAllowed) {
                faceID.requestAccessibility()
            }
        } header: {
            Text("Face ID needs two things")
        }

        Section {
            if faceID.hasPassword && !changingPassword {
                LabeledContent("Mac password") {
                    HStack {
                        Label("Saved in your Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Change") { changingPassword = true }
                    }
                }
            } else {
                LabeledContent("Mac password") {
                    HStack {
                        SecureField("", text: $password, prompt: Text("Your login password"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit(savePassword)
                        Button("Save", action: savePassword).disabled(password.isEmpty)
                    }
                }
                if let passwordError {
                    Text(passwordError).foregroundStyle(.red).font(.callout)
                }
            }
        } header: {
            Text("Password")
        } footer: {
            Text("Face ID types it in for you. It stays in this Mac's Keychain. Islet checks it once against your account before saving it. After a restart, macOS always wants it typed by hand.")
        }

        Section {
            ForEach(faceID.faces) { face in
                LabeledContent {
                    HStack {
                        Toggle("", isOn: Binding(get: { face.enabled }, set: { faceID.setEnabled(face, $0) }))
                            .labelsHidden()
                        if (face.learned?.count ?? 0) > 0 {
                            Button("Forget Learned") { faceID.forgetLearned(face) }
                                .help("Back to how it was enrolled: drops the looks it picked up since.")
                        }
                        Button("Delete", role: .destructive) { faceID.delete(face) }
                    }
                } label: {
                    Label(face.name, systemImage: "person.crop.circle.fill")
                    Text("\(face.embeddings.count) angles" + ((face.learned?.count ?? 0) > 0 ? " · \(face.learned!.count) learned looks" : ""))
                }
            }
            if faceID.enrolling {
                enrolment
            } else {
                Button {
                    faceName = faceID.faces.isEmpty ? NSFullUserName() : ""
                    faceID.beginEnrolment()
                } label: {
                    Label(faceID.faces.isEmpty ? "Set Up Your Face" : "Add Another Face", systemImage: "plus.circle.fill")
                }
                .disabled(!faceID.cameraAllowed)
            }
        } header: {
            Text("Faces")
        }

        Section {
            LabeledContent("Match strictness") {
                HStack {
                    Text("Easier").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $settings.faceIDStrictness, in: 0...1).frame(width: 170)
                    Text("Stricter").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Liveness", selection: $settings.faceIDLiveness) {
                Text("Off").tag(FaceLiveness.off)
                Text("Natural").tag(FaceLiveness.natural)
                Text("Strict").tag(FaceLiveness.strict)
            }
            Toggle("Flash to make me blink", isOn: $settings.faceIDBlinkNudge)
                .disabled(settings.faceIDLiveness == .off)
                .help("If it's waiting for a blink, a quick white flash makes your eyes blink on their own (at most twice).")
            Toggle("Learn my face as I use it", isOn: $settings.faceIDLearn)
                .disabled(settings.faceIDLiveness != .strict)
                .help("Keeps new looks of you (other light, glasses) from Strict unlocks only, which checked for a blink and the light.")
            Picker("Lock screen style", selection: $settings.faceIDStyle) {
                ForEach(FaceIDStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Look for you for", selection: $settings.faceIDDuration) {
                ForEach([3.0, 5.0, 8.0, 12.0], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
            }
        } header: {
            Text("Behavior")
        } footer: {
            Text(livenessNote + " Higher strictness: harder for anyone else, occasionally slower for you. "
                 + (settings.faceIDStyle == .pill ? "A slim pill at the top: a lock and the Face ID mark." : "A big, clean square with the Face ID mark."))
        }

        Section {
            Toggle("When the display wakes", isOn: $settings.faceIDOnWake)
            Toggle("Right after it locks", isOn: $settings.faceIDOnLock)
            Toggle("When you click the notch", isOn: $settings.faceIDOnClick)
        } header: {
            Text("When it looks for you")
        } footer: {
            Text("Clicking the notch lets people look at the lock screen first and unlock when they're ready. After locking, it waits a couple of seconds first, so locking it on purpose sticks.")
        }

        Section {
            LabeledContent("Test") {
                Button(faceID.isScanning ? "Looking…" : "Test Face ID") { faceID.test() }
                    .disabled(faceID.isScanning || faceID.faces.isEmpty || !faceID.cameraAllowed)
            }
            if let report = faceID.testReport {
                Text(report).font(.callout).foregroundStyle(.secondary).contentTransition(.opacity)
            }
        } footer: {
            Text("Looks for you for a few seconds and shows how closely it matched, without unlocking anything.")
        }

        Section {
            Button("Turn Off and Forget Face ID", role: .destructive) { confirmForget = true }
                .disabled(faceID.faces.isEmpty && !faceID.hasPassword)
                .confirmationDialog("Forget Face ID?", isPresented: $confirmForget) {
                    Button("Turn Off and Forget", role: .destructive) { faceID.forgetEverything() }
                } message: {
                    Text("Your face fingerprints and stored password are deleted from this Mac.")
                }
        } footer: {
            Text("Face recognition uses the SFace model from OpenCV, on this Mac only.")
        }
        .onDisappear { if faceID.enrolling { faceID.cancelEnrolment() } }
        // Permissions change in System Settings, which tells nobody: look again each second.
        .task {
            while !Task.isCancelled, !(faceID.cameraAllowed && faceID.accessibilityAllowed) {
                try? await Task.sleep(for: .seconds(1))
                refresh += 1
            }
        }
    }

    private var livenessNote: String {
        switch settings.faceIDLiveness {
        case .off: "Off: fastest. A good photo of you could fool it."
        case .natural: "Natural: you blink. Stops photos; a video of you on a phone can still fool it."
        case .strict: "Strict: you blink, then the screen flashes red and green for about a second. Harder to fool, not foolproof: a Mac camera can't see depth like an iPhone's Face ID."
        }
    }

    private var enrolment: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                CameraPreview(session: faceID.previewSession)
                    .frame(width: 150, height: 150)
                    .clipShape(Circle())
                // Nine segments around the face fill in as each direction is captured.
                ForEach(0..<9, id: \.self) { index in
                    Circle()
                        .trim(from: Double(index) / 9 + 0.008, to: Double(index + 1) / 9 - 0.008)
                        .stroke(faceID.enrolledDirections.contains(index) ? Color.green : .white.opacity(0.18),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 168, height: 168)
                        .animation(IslandMotion.quick, value: faceID.enrolledDirections)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Move your head slowly in a circle").font(.headline)
                Text("\(faceID.enrolledDirections.count) of 9 angles. Good light helps; glasses are fine.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Name", text: $faceName).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                HStack {
                    Button("Cancel") { faceID.cancelEnrolment() }
                    Button("Done") { _ = faceID.finishEnrolment(name: faceName) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(faceID.enrolledDirections.count < 4)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func permissionRow(_ title: String, _ detail: String, allowed: Bool, request: @escaping () -> Void) -> some View {
        LabeledContent {
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow…", action: request)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        if faceID.savePassword(password) {
            passwordError = nil
            changingPassword = false
        } else {
            passwordError = "That isn't this Mac's password."
        }
        password = ""
    }
}

/// The camera, mirrored like a mirror, for enrolment.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let session, (view.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer)?.session !== session else { return }
        view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
    }
}
