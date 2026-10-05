import CMUXAgentLaunch
import Foundation

/// One Claude Code hook event forwarded from a remote tmux pane.
///
/// The remote hook script (`scripts/remote-tmux/claude-hook.sh`)
/// writes `ESC ] 777;cmux-hook;<base64 JSON> BEL` to its pane, and
/// ``RemoteTmuxNotificationOSCFilter`` lifts the base64 text out of the
/// mirrored output. The JSON is `{"event", "session_id", "cwd"?}`.
///
/// Any program printing to the pane can emit this sequence, so the payload is
/// trusted for nothing but its own pane's agent state: the mirror, not the
/// payload, names the surface and workspace, and only lifecycle events that
/// drive that state are accepted.
struct RemoteTmuxPaneHookEvent: Equatable, Sendable {
    let hookEventName: WorkstreamEvent.HookEventName
    let sessionId: String
    let cwd: String?

    /// Events that move a session's turn state. Tool payloads and prompts
    /// never cross the wire: the script sends only the event name, session id
    /// and cwd.
    static let acceptedEvents: Set<WorkstreamEvent.HookEventName> = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse,
        .postToolUseFailure, .stop, .notification, .permissionRequest,
    ]

    private static let maxSessionIdLength = 128
    private static let maxCwdLength = 4096

    init?(base64: String) {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEvent = object["event"] as? String,
              let event = WorkstreamEvent.HookEventName(rawValue: rawEvent),
              Self.acceptedEvents.contains(event),
              let sessionId = object["session_id"] as? String,
              Self.isValidSessionId(sessionId) else { return nil }
        hookEventName = event
        self.sessionId = sessionId
        cwd = (object["cwd"] as? String).flatMap {
            $0.isEmpty || $0.utf8.count > Self.maxCwdLength ? nil : $0
        }
    }

    /// The registry event for this hook, bound to the pane's own surface.
    ///
    /// No pid: the agent runs on the remote host, and a remote pid would let
    /// the local liveness sweep end the session. No transcript path: it names
    /// a remote file this Mac cannot read.
    func workstreamEvent(workspaceId: UUID, surfaceId: UUID, receivedAt: Date) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: "claude-\(sessionId)",
            hookEventName: hookEventName,
            source: "claude",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            cwd: cwd,
            receivedAt: receivedAt
        )
    }

    private static func isValidSessionId(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maxSessionIdLength else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }
}
