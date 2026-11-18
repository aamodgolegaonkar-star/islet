import Foundation
import IsletCore

/// The current Focus mode, told when it changes. Watches donotdisturbd's DB folder with a
/// kqueue source (the files are replaced, not edited, so the folder is what's watched):
/// no timer and no log stream, nothing runs until a Focus actually changes.
@MainActor
final class FocusMonitor {
    private(set) var active: FocusMode?
    /// (new mode or nil, the mode that just ended or nil)
    var onChange: ((FocusMode?, FocusMode?) -> Void)?

    private let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    private var source: DispatchSourceFileSystemObject?
    private var modes: [String: FocusMode] = [:]
    private var pending: Task<Void, Never>?

    func start() {
        guard source == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.island.error("Focus: can't watch \(self.folder.path, privacy: .public) (errno \(errno))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        reloadModes()
        do { _ = try Data(contentsOf: folder.appendingPathComponent("Assertions.json")) } catch {
            Log.island.error("Focus: can't read assertions: \(error.localizedDescription, privacy: .public)")
        }
        active = read()
        Log.island.notice("Focus: watching, now \(self.active?.name ?? "off", privacy: .public)")
    }

    func stop() {
        source?.cancel()
        source = nil
        pending?.cancel()
    }

    /// donotdisturbd writes a few files in a burst: settle, then read once.
    private func changed() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.reloadModes()
            let now = self.read()
            guard now != self.active else { return }
            let ended = self.active
            self.active = now
            Log.island.notice("Focus: \(now?.name ?? "off", privacy: .public)")
            self.onChange?(now, ended)
        }
    }

    private func reloadModes() {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("ModeConfigurations.json")) {
            let parsed = FocusModes.modes(configurations: data)
            if !parsed.isEmpty { modes = parsed }
        }
    }

    private func read() -> FocusMode? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Assertions.json")),
              let id = FocusModes.activeIdentifier(assertions: data) else { return nil }
        return FocusModes.mode(id, in: modes)
    }
}
