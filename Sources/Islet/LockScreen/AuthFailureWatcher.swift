import Foundation

/// Notices failed unlock attempts (wrong fingerprint or wrong password) while the screen
/// is locked, so the lock-screen island can shake.
///
/// macOS posts nothing public for a failed attempt, but loginwindow logs
/// `authFailWithMessage:numFailedAttempts:` for every one. Apps can't read other processes'
/// logs directly, so this runs Apple's own `log stream`, filtered down to that one message,
/// and only while the screen is locked.
@MainActor
final class AuthFailureWatcher {
    var onFailure: (() -> Void)?
    private var process: Process?

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--predicate",
                             #"process == "loginwindow" AND eventMessage CONTAINS "authFailWithMessage""#]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // One line per failure; the header line doesn't contain the message.
            let failures = String(decoding: data, as: UTF8.self)
                .components(separatedBy: "\n")
                .filter { $0.contains("authFailWithMessage") }.count
            guard failures > 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for _ in 0..<failures { self?.onFailure?() }
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            Log.lock.error("Can't watch for failed unlock attempts: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
