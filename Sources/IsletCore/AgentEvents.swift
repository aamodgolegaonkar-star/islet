import Foundation

/// What a coding agent (Claude Code, Codex) reported, reduced to what the island shows.
public struct AgentEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Waiting for the user to approve something.
        case permission
        /// Idle, waiting for the next message.
        case waiting
        /// Finished its turn.
        case done
    }

    public var kind: Kind
    /// The project folder's name.
    public var project: String
    public var message: String

    public init(kind: Kind, project: String, message: String) {
        self.kind = kind
        self.project = project
        self.message = message
    }

    /// Claude Code hook input (JSON on stdin): Notification, PermissionRequest and Stop.
    public static func claude(_ data: Data) -> AgentEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let project = folderName(json["cwd"] as? String)
        let message = (json["message"] as? String) ?? ""
        switch json["hook_event_name"] as? String {
        case "Notification":
            let asking = message.localizedCaseInsensitiveContains("permission")
            return AgentEvent(kind: asking ? .permission : .waiting, project: project, message: message)
        case "PermissionRequest":
            let tool = json["tool_name"] as? String
            return AgentEvent(kind: .permission, project: project,
                              message: tool.map { "Wants to use \($0)" } ?? "Needs your permission")
        case "Stop":
            return AgentEvent(kind: .done, project: project, message: "")
        default:
            return nil
        }
    }

    /// Codex `notify` payload (JSON as the last argument): agent-turn-complete.
    public static func codex(_ argument: String) -> AgentEvent? {
        guard let data = argument.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "agent-turn-complete" else { return nil }
        let reply = (json["last-assistant-message"] as? String) ?? ""
        return AgentEvent(kind: .done, project: folderName(json["cwd"] as? String), message: summary(reply))
    }

    /// The first line, at most 120 characters.
    public static func summary(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    static func folderName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
