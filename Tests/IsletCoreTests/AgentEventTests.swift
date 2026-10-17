import Foundation
import IsletCore
import Testing

@Suite("Coding agent events")
struct AgentEventTests {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test func claudePermission() {
        let event = AgentEvent.claude(json(#"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","cwd":"/Users/me/Islet"}"#))
        #expect(event == AgentEvent(kind: .permission, project: "Islet", message: "Claude needs your permission to use Bash"))
    }

    @Test func claudeWaitingAndDone() {
        #expect(AgentEvent.claude(json(#"{"hook_event_name":"Notification","message":"Claude is waiting for your input","cwd":"/a/b"}"#))?.kind == .waiting)
        #expect(AgentEvent.claude(json(#"{"hook_event_name":"Stop","cwd":"/a/web"}"#)) == AgentEvent(kind: .done, project: "web", message: ""))
        #expect(AgentEvent.claude(json(#"{"hook_event_name":"PermissionRequest","tool_name":"Edit"}"#))?.message == "Wants to use Edit")
        #expect(AgentEvent.claude(json(#"{"hook_event_name":"PreToolUse"}"#)) == nil)
        #expect(AgentEvent.claude(json("not json")) == nil)
    }

    @Test func codexTurnComplete() {
        let event = AgentEvent.codex(#"{"type":"agent-turn-complete","last-assistant-message":"Fixed the build.\nDetails…","cwd":"/x/api"}"#)
        #expect(event == AgentEvent(kind: .done, project: "api", message: "Fixed the build."))
        #expect(AgentEvent.codex(#"{"type":"other"}"#) == nil)
        #expect(AgentEvent.summary(String(repeating: "a", count: 200)).count == 120)
    }
}
