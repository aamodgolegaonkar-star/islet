import AppKit
import IsletCore

/// A coding agent asking for attention, as shown in the island.
struct AgentAlert: Equatable, Sendable {
    enum Source: String, Sendable {
        case claude, codex

        var name: String { self == .claude ? "Claude Code" : "Codex" }
    }

    var source: Source
    var event: AgentEvent
    /// Bundle ID of the app the agent runs in (Terminal, iTerm, VS Code…), to bring it forward.
    var app: String?

    var title: String {
        switch event.kind {
        case .permission: "\(source.name) needs your permission"
        case .waiting: "\(source.name) is waiting for you"
        case .done: "\(source.name) finished"
        }
    }

    var subtitle: String {
        [event.project, event.message].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - islet:// links (how the hook command reaches the running app)

    var url: URL? {
        var parts = URLComponents()
        parts.scheme = "islet"
        parts.host = "agent"
        parts.queryItems = [
            URLQueryItem(name: "source", value: source.rawValue),
            URLQueryItem(name: "kind", value: event.kind.rawValue),
            URLQueryItem(name: "project", value: event.project),
            URLQueryItem(name: "message", value: event.message),
            URLQueryItem(name: "app", value: app),
        ]
        return parts.url
    }

    init(source: Source, event: AgentEvent, app: String?) {
        self.source = source
        self.event = event
        self.app = app
    }

    init?(url: URL) {
        guard url.scheme == "islet", url.host == "agent",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let source = value("source").flatMap(Source.init), let kind = value("kind").flatMap(AgentEvent.Kind.init)
        else { return nil }
        self.init(source: source,
                  event: AgentEvent(kind: kind, project: value("project") ?? "",
                                    message: String((value("message") ?? "").prefix(200))),
                  app: value("app"))
    }
}

/// `Islet --agent-notify <claude|codex> [--then <command…>]`: the command the agents run.
/// It reads the event (stdin for Claude Code, the last argument for Codex), passes it to the
/// running Islet through an islet:// link without activating it, then runs the command
/// Codex used before (if any) with the same payload, and exits.
enum AgentNotifier {
    static func run(_ arguments: [String]) -> Never {
        guard let flag = arguments.firstIndex(of: "--agent-notify"), flag + 1 < arguments.count,
              let source = AgentAlert.Source(rawValue: arguments[flag + 1]) else { exit(2) }
        let rest = Array(arguments[(flag + 2)...])
        var previous: [String] = []
        var payloadArgument = rest.last
        if let then = rest.firstIndex(of: "--then") {
            previous = Array(rest[(then + 1)...].dropLast())
        }
        if source == .claude { payloadArgument = nil }

        let event: AgentEvent?
        switch source {
        case .claude: event = AgentEvent.claude(FileHandle.standardInput.readDataToEndOfFile())
        case .codex: event = payloadArgument.flatMap(AgentEvent.codex)
        }
        // Apps set __CFBundleIdentifier for what they launch: the terminal the agent runs in.
        let app = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        if let event, let url = AgentAlert(source: source, event: event, app: app).url {
            let done = DispatchSemaphore(value: 0)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open(url, configuration: configuration) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 3)
        }
        if !previous.isEmpty, let payloadArgument {
            let chained = Process()
            chained.executableURL = URL(fileURLWithPath: previous[0])
            chained.arguments = Array(previous.dropFirst()) + [payloadArgument]
            try? chained.run()
        }
        exit(0)
    }
}

/// Connects or disconnects the agents, editing their own settings files (with a backup).
@MainActor
enum AgentSetup {
    static var executable: String { Bundle.main.executablePath ?? "/Applications/Islet.app/Contents/MacOS/Islet" }

    // MARK: Claude Code: ~/.claude/settings.json hooks

    private static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }
    private static let claudeEvents = ["Notification", "Stop"]
    private static let claudeMarker = "--agent-notify claude"

    static var claudeConnected: Bool {
        (try? String(contentsOf: claudeSettings, encoding: .utf8))?.contains(claudeMarker) == true
    }

    static func connectClaude() throws {
        var json = try readJSON(claudeSettings)
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let command = "'\(executable)' \(claudeMarker)"
        for event in claudeEvents {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !mentionsIslet($0) }
            entries.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = entries
        }
        json["hooks"] = hooks
        try writeJSON(json, to: claudeSettings)
    }

    static func disconnectClaude() throws {
        var json = try readJSON(claudeSettings)
        guard var hooks = json["hooks"] as? [String: Any] else { return }
        for event in claudeEvents {
            let entries = (hooks[event] as? [[String: Any]] ?? []).filter { !mentionsIslet($0) }
            hooks[event] = entries.isEmpty ? nil : entries
        }
        json["hooks"] = hooks
        try writeJSON(json, to: claudeSettings)
    }

    private static func mentionsIslet(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(claudeMarker) == true }
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func writeJSON(_ json: [String: Any], to url: URL) throws {
        backUp(url)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Codex: ~/.codex/config.toml `notify` (only one allowed, so Islet chains to it)

    private static var codexConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/config.toml")
    }

    static var codexInstalled: Bool {
        FileManager.default.fileExists(atPath: codexConfig.deletingLastPathComponent().path)
    }

    static var codexConnected: Bool { currentCodexNotify().contains("--agent-notify") }

    static func connectCodex() throws {
        let current = currentCodexNotify()
        guard !current.contains("--agent-notify") else { return }
        let previous = current.isEmpty ? [] : ["--then"] + current
        try setCodexNotify([executable, "--agent-notify", "codex"] + previous)
    }

    static func disconnectCodex() throws {
        let current = currentCodexNotify()
        guard current.contains("--agent-notify") else { return }
        // Put back whatever ran before Islet.
        let previous = current.firstIndex(of: "--then").map { Array(current[($0 + 1)...]) } ?? []
        try setCodexNotify(previous)
    }

    private static let notifyPattern = /(?m)^notify\s*=\s*\[[^\]]*\]\n?/

    private static func currentCodexNotify() -> [String] {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8),
              let match = text.firstMatch(of: notifyPattern) else { return [] }
        return match.output.matches(of: /"((?:[^"\\]|\\.)*)"/).map {
            String($0.output.1).replacing("\\\"", with: "\"").replacing("\\\\", with: "\\")
        }
    }

    private static func setCodexNotify(_ values: [String]) throws {
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        text = text.replacing(notifyPattern, with: "")
        if !values.isEmpty {
            let quoted = values.map { "    \"" + $0.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\"," }
            // Top-level keys must come before the first [table].
            text = "notify = [\n" + quoted.joined(separator: "\n") + "\n]\n" + text
        }
        backUp(codexConfig)
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    /// The first time Islet edits a file it keeps the original next to it.
    private static func backUp(_ url: URL) {
        let backup = url.appendingPathExtension("islet-backup")
        guard FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }
}
