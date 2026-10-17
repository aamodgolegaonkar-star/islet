import Foundation
import IsletCore

/// Streams system-wide Now Playing through the bundled mediaremote-adapter (BSD-3-Clause).
///
/// Since macOS 15.4 only Apple-signed processes may use MediaRemote, so the adapter runs
/// inside `/usr/bin/perl` (which identifies as `com.apple.perl`) and prints JSON lines.
@MainActor
final class AdapterSource {
    var onEvent: ((AdapterEvent) -> Void)?
    /// Called when the adapter is missing or keeps exiting; the caller should fall back.
    var onUnavailable: (() -> Void)?

    private let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private let script: URL?
    private let framework: URL?
    private var process: Process?
    private var stopping = false
    private var recentExits: [Date] = []

    init(resources: URL? = Bundle.main.resourceURL) {
        script = resources?.appending(path: "mediaremote-adapter.pl")
        framework = resources?.appending(path: "MediaRemoteAdapter.framework")
    }

    var isAvailable: Bool {
        let fm = FileManager.default
        guard let script, let framework else { return false }
        return fm.isExecutableFile(atPath: perl.path)
            && fm.fileExists(atPath: script.path)
            && fm.fileExists(atPath: framework.path)
    }

    /// Starts streaming; returns false when the adapter is not bundled.
    @discardableResult
    func start() -> Bool {
        guard isAvailable else { return false }
        stopping = false
        removeOrphans()
        launchStream()
        return true
    }

    /// A previous Islet that crashed or was killed leaves its stream adapter running,
    /// reparented to launchd. Stop any such orphan of this bundle before starting ours.
    private func removeOrphans() {
        guard let script else { return }
        let sweep = Process()
        sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        sweep.arguments = ["-P", "1", "-f", NSRegularExpression.escapedPattern(for: script.path) + " .* stream"]
        sweep.standardOutput = FileHandle.nullDevice
        sweep.standardError = FileHandle.nullDevice
        try? sweep.run()
        sweep.waitUntilExit()
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    func send(_ command: MediaCommand) async -> Bool {
        await runOnce(["send", String(command.rawValue)])
    }

    func seek(to seconds: TimeInterval) async -> Bool {
        await runOnce(["seek", String(Int64(max(0, seconds) * 1_000_000))])
    }

    // MARK: - Process management

    private func launchStream() {
        guard let script, let framework else { return }
        let process = Process()
        process.executableURL = perl
        process.arguments = [script.path, framework.path, "stream", "--micros", "--debounce=40"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let reader = AdapterLineReader { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onEvent?(event) }
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.append(data)
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let pid = finished.processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A stream stopped for a restart reports late; it mustn't touch its successor.
                    guard let self, self.process == nil || self.process?.processIdentifier == pid else { return }
                    self.streamEnded(status: status)
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            onUnavailable?()
        }
    }

    private func streamEnded(status: Int32) {
        process = nil
        guard !stopping else { return }
        let now = Date()
        recentExits = recentExits.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentExits.count >= 4 {
            onUnavailable?()
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !self.stopping, self.process == nil else { return }
            self.launchStream()
        }
    }

    private func runOnce(_ arguments: [String]) async -> Bool {
        guard isAvailable, let script, let framework else { return false }
        let process = Process()
        process.executableURL = perl
        process.arguments = [script.path, framework.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }
}

/// Splits the adapter's stdout into lines and decodes them on the pipe's reader thread.
private final class AdapterLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var decoder = AdapterStreamDecoder()
    private let emit: @Sendable (AdapterEvent) -> Void

    init(emit: @escaping @Sendable (AdapterEvent) -> Void) {
        self.emit = emit
    }

    func append(_ data: Data) {
        var events: [AdapterEvent] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty, let event = decoder.consume(line: Data(line)) {
                events.append(event)
            }
        }
        lock.unlock()
        // Only the latest state matters when several lines arrive together.
        if let last = events.last { emit(last) }
    }
}
