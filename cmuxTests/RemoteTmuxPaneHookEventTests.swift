import CMUXAgentLaunch
import CmuxAgentChat
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Remote Claude hooks in an ssh-tmux pane have no socket back to the Mac, so
/// `scripts/remote-tmux/claude-hook.sh` writes each event into the pane's own
/// output as `ESC ] 777;cmux-hook;<base64 JSON> BEL`.
@MainActor
struct RemoteTmuxPaneHookEventTests {
    private let ESC = "\u{1b}"
    private let BEL = "\u{07}"

    /// The exact JSON shape the hook script emits.
    private func payload(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
    }

    @Test func decodesTheHookScriptPayload() throws {
        let hook = try #require(RemoteTmuxPaneHookEvent(
            base64: payload(#"{"event":"Stop","session_id":"abc-123_x","cwd":"/home/u/my \"dir\""}"#)
        ))
        #expect(hook.hookEventName == .stop)
        #expect(hook.sessionId == "abc-123_x")
        #expect(hook.cwd == #"/home/u/my "dir""#)
    }

    @Test func rejectsPayloadsThatCannotDriveOnlyAgentState() {
        // Not base64, unknown event, event outside the lifecycle set, and a
        // session id that is not an id.
        #expect(RemoteTmuxPaneHookEvent(base64: "not base64!") == nil)
        #expect(RemoteTmuxPaneHookEvent(base64: payload(#"{"event":"Bogus","session_id":"a"}"#)) == nil)
        #expect(RemoteTmuxPaneHookEvent(base64: payload(#"{"event":"SubagentStart","session_id":"a"}"#)) == nil)
        #expect(RemoteTmuxPaneHookEvent(base64: payload(#"{"event":"Stop","session_id":"../x"}"#)) == nil)
        #expect(RemoteTmuxPaneHookEvent(base64: payload(#"{"event":"Stop"}"#)) == nil)
    }

    /// The mirror names the surface; a remote pid would let the local
    /// liveness sweep end the session, and the transcript is a remote file.
    @Test func workstreamEventIsBoundToThePaneWithoutPidOrTranscript() throws {
        let hook = try #require(RemoteTmuxPaneHookEvent(
            base64: payload(#"{"event":"UserPromptSubmit","session_id":"s1"}"#)
        ))
        let workspaceId = UUID()
        let surfaceId = UUID()
        let event = hook.workstreamEvent(workspaceId: workspaceId, surfaceId: surfaceId, receivedAt: Date())
        #expect(event.sessionId == "claude-s1")
        #expect(event.source == "claude")
        #expect(event.hookEventName == .userPromptSubmit)
        #expect(event.workspaceId == workspaceId.uuidString)
        #expect(event.surfaceId == surfaceId.uuidString)
        #expect(event.ppid == nil)
        #expect(event.transcriptPath == nil)
    }

    @Test func filterLiftsHookSequencesAcrossChunkSplitsAndKeepsNotifications() {
        let body = payload(#"{"event":"Stop","session_id":"s1"}"#)
        let stream = "a\(ESC)]777;cmux-hook;\(body)\(BEL)b\(ESC)]777;notify;T;B\(BEL)c\(ESC)]777;other;x\(BEL)"
        let bytes = Array(stream.utf8)
        // Split at every byte boundary: the sequence can straddle any
        // `%output` chunk.
        for split in 1..<bytes.count {
            var filter = RemoteTmuxNotificationOSCFilter()
            var hooks: [String] = []
            var notifications: [String] = []
            var out = Data()
            for chunk in [bytes[..<split], bytes[split...]] {
                out.append(filter.filter(
                    Data(chunk),
                    onNotification: { title, body in notifications.append("\(title)|\(body)") },
                    onHookPayload: { hooks.append($0) }
                ))
            }
            #expect(hooks == [body], "split \(split)")
            #expect(notifications == ["T|B"], "split \(split)")
            #expect(out == Data("abc\(ESC)]777;other;x\(BEL)".utf8), "split \(split)")
        }
    }

    /// End to end: the hook escape in a mirrored pane's output drives that
    /// pane's registry record, which the sidebar reads as its status.
    @Test func paneOutputHookEscapeDrivesThePaneAgentState() throws {
        let previousService = TerminalController.shared.agentChatTranscriptService
        let registry = AgentChatSessionRegistry()
        TerminalController.shared.agentChatTranscriptService = AgentChatTranscriptService(
            registry: registry,
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        let fixture = HookSessionMirrorFixture()
        defer {
            fixture.close()
            TerminalController.shared.agentChatTranscriptService = previousService
        }
        let panel = try #require(fixture.sessionMirror.windowMirrorByWindowId[1]?.panel(forPane: 7))

        func emit(_ event: String) {
            let body = payload(#"{"event":"\#(event)","session_id":"remote-1","cwd":"/srv/dt"}"#)
            fixture.sessionMirror.routeOutput(
                paneId: 7,
                data: Data("\(ESC)]777;cmux-hook;\(body)\(BEL)".utf8)
            )
        }
        func record() -> AgentChatSessionRecord? {
            registry.sessions(workspaceID: nil).first { $0.surfaceID == panel.id.uuidString }
        }

        emit("UserPromptSubmit")
        let working = try #require(record())
        #expect(working.sessionID == "remote-1")
        #expect(working.workspaceID == fixture.workspace.id.uuidString)
        #expect(working.workingDirectory == "/srv/dt")
        #expect(working.pid == nil)
        guard case .working = working.state else {
            Issue.record("expected working, got \(working.state)")
            return
        }

        emit("PermissionRequest")
        guard case .needsInput = record()?.state else {
            Issue.record("expected needsInput, got \(String(describing: record()?.state))")
            return
        }

        emit("Stop")
        #expect(record()?.state == .idle)
    }
}

@MainActor
private struct HookSessionMirrorFixture {
    let connection: RemoteTmuxControlConnection
    let writer: RemoteTmuxControlPipeWriter
    let pipe: Pipe
    let workspace: Workspace
    let sessionMirror: RemoteTmuxSessionMirror

    init() {
        connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "hook-relay.test"),
            sessionName: "work"
        )
        pipe = Pipe()
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-hook-relay-test",
            maxPendingBytes: 1 << 20,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7))
        )
        connection.windowOrder = [1]
        connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])
        let manager = TabManager(autoWelcomeIfNeeded: false)
        workspace = manager.selectedWorkspace!
        workspace.isRemoteTmuxMirror = true
        sessionMirror = RemoteTmuxSessionMirror(
            host: connection.host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        sessionMirror.rebuild()
    }

    func close() {
        sessionMirror.detachObserver()
        writer.close()
        try? pipe.fileHandleForReading.close()
    }
}
