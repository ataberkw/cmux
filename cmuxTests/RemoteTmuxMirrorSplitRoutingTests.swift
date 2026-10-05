import CmuxRemoteSession
import AppKit
import Bonsplit
import CmuxControlSocket
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the remote-tmux mirror split routing contract
/// (https://github.com/manaflow-ai/cmux/pull/5553): a split request on a
/// remote tmux mirror workspace must never create a local panel — it is
/// routed to the remote tmux session (the pane arrives via %layout-change),
/// or fails when no live mirror exists. A local panel here would be an
/// orphan the mirror's rebuild() never reconciles, and the socket layer
/// reporting routed requests as errors makes automation retry and duplicate
/// remote panes.
@MainActor
@Suite(.serialized) struct RemoteTmuxMirrorSplitRoutingTests {
    @Test func mirrorWorkspaceSplitNeverCreatesLocalPanel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.workspace.isRemoteTmuxMirror = true
        let panelsBefore = harness.workspace.panels.count

        let panel = harness.workspace.newTerminalSplit(
            from: harness.sourcePanelId,
            orientation: .horizontal,
            focus: false
        )

        #expect(panel == nil)
        #expect(harness.workspace.panels.count == panelsBefore)
    }

    @Test func localWorkspaceSplitStillCreatesLocalPanel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let panelsBefore = harness.workspace.panels.count

        let panel = harness.workspace.newTerminalSplit(
            from: harness.sourcePanelId,
            orientation: .horizontal,
            focus: false
        )

        #expect(panel != nil)
        #expect(harness.workspace.panels.count == panelsBefore + 1)
    }

    @Test func windowMirrorSplitRejectsWhileConnecting() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7)),
            appearance: .default,
            makePanel: { _ in nil }
        )

        #expect(!mirror.requestSplit(
            fromPane: 7,
            vertical: true,
            focusIntent: .focusCreatedPane
        ))
    }

    @Test func focusedSplitRequestsTheCreatedPaneID() {
        #expect(
            RemoteTmuxSplitFocusIntent.focusCreatedPane.command(
                vertical: false,
                windowID: 2,
                paneID: 4
            ) == "split-window -P -F '#{pane_id}' -h -t @2.%4"
        )
    }

    /// A split must start the new pane in the split pane's directory, like a
    /// local split. Without `-c`, tmux starts it in the session's start
    /// directory (`cd dt` + split button landed in `~`). The path is literal:
    /// tmux expands `-c '#{pane_current_path}'` against the session's current
    /// window, not the `-t` pane.
    @Test func splitCommandStartsInTheSplitPaneDirectory() {
        #expect(
            RemoteTmuxSplitFocusIntent.preserveActivePane.command(
                vertical: true,
                windowID: 3,
                paneID: 9,
                workingDirectory: "/home/me/my dt"
            ) == "split-window -d -v -t @3.%9 -c '/home/me/my dt'"
        )
        #expect(
            RemoteTmuxSplitFocusIntent.focusCreatedPane.command(
                vertical: false,
                windowID: 3,
                paneID: 9,
                workingDirectory: "  "
            ) == "split-window -P -F '#{pane_id}' -h -t @3.%9"
        )
        #expect(
            RemoteTmuxSplitFocusIntent.focusCreatedPane.command(
                vertical: false,
                windowID: 3,
                paneID: 9,
                workingDirectory: "/tmp/a\nkill-server"
            ) == "split-window -P -F '#{pane_id}' -h -t @3.%9"
        )
    }

    /// The split button on a single-pane mirror tab routes through the session
    /// mirror and must carry that pane's tracked remote cwd.
    @Test func sessionMirrorTabSplitStartsInTheTrackedPaneDirectory() throws {
        let fixture = SessionMirrorFixture()
        defer { fixture.close() }
        fixture.sessionMirror.cwdByPane[7] = "/home/me/dt"
        let panelId = try #require(fixture.sessionMirror.panelIdByWindow[1])

        #expect(fixture.sessionMirror.trackedWorkingDirectory(forWindowPanel: panelId) == "/home/me/dt")
        #expect(fixture.sessionMirror.requestSplit(
            windowPanelId: panelId,
            vertical: false,
            focusIntent: .preserveActivePane
        ))
        #expect(fixture.writtenCommands(prefix: "split-window ") == [
            "split-window -d -h -t @1.%7 -c '/home/me/dt'",
        ])
    }

    /// A split of a pane inside a multi-pane mirror window goes through the
    /// window mirror and must use that pane's tracked cwd.
    @Test func windowMirrorPaneSplitStartsInTheTrackedPaneDirectory() throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness(
            connectedTransport: true
        )
        defer { harness.tearDown() }
        harness.mirror.updatePaneCwd(paneId: 11, path: "/home/me/left")
        harness.mirror.updatePaneCwd(paneId: 22, path: "/home/me/right")

        #expect(harness.mirror.requestSplit(
            fromPane: 11,
            vertical: true,
            focusIntent: .preserveActivePane
        ))
        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        let commands = try #require(String(
            bytes: try pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ))
        #expect(commands.split(separator: "\n").filter { $0.hasPrefix("split-window ") } == [
            "split-window -d -v -t @3.%11 -c '/home/me/left'",
        ])
    }

    @Test func projectedForkSplitPreservesBeforePlacementAndRemoteLaunchContext() throws {
        let command = try #require(
            RemoteTmuxSplitFocusIntent.focusCreatedPane.agentForkCommand(
                vertical: true,
                windowID: 2,
                paneID: 4,
                insertBefore: true,
                shellCommand: "claude --fork-session abc",
                workingDirectory: "/tmp/remote fork"
            )
        )

        #expect(command.hasPrefix("split-window -P -F '#{pane_id}' -v -b -t @2.%4"))
        #expect(command.contains("-c '/tmp/remote fork'"))
        #expect(command.hasSuffix("'claude --fork-session abc'"))
    }

    /// `new-split --focus false` must ask tmux to create the pane detached.
    /// Without `-d`, tmux selects the new pane and its authoritative active-pane
    /// publication also changes the mirror's internal focus (#7733).
    @Test func backgroundControlSplitPreservesTheRemoteActivePane() throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness(
            connectedTransport: true
        )
        defer { harness.tearDown() }
        let activePaneBefore = harness.mirror.activePaneId
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let surfaceID = try #require(harness.mirror.panel(forPane: tmuxPaneID)?.id)

        let result = TerminalController.shared.controlSurfaceSplit(
            routing: harness.routing(),
            inputs: ControlSurfaceSplitInputs(
                directionRaw: "right",
                typeRaw: nil,
                urlRaw: nil,
                requestedSourceSurfaceID: surfaceID,
                workingDirectory: nil,
                initialCommand: nil,
                tmuxStartCommand: nil,
                remotePTYSessionID: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                clientUnsupportedRemoteTmuxOptions: [],
                requestedFocus: false,
                initialDividerPosition: nil
            )
        )

        guard case .routedToRemote = result else {
            Issue.record("Expected background split to route to remote tmux: \(result)")
            return
        }
        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        let commands = try #require(String(
            bytes: try pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ))
        let splitCommands = commands.split(separator: "\n").filter {
            $0.hasPrefix("split-window ")
        }
        #expect(splitCommands.count == 1)
        #expect(splitCommands.first?.split(separator: " ").contains("-d") == true)
        #expect(harness.mirror.activePaneId == activePaneBefore)
    }

    @Test func windowMirrorConfigurationTracksWorkspaceAppearanceAndEmbeddedPolicy() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(
                width: 80,
                height: 24,
                x: 0,
                y: 0,
                content: .pane(7)
            ),
            makePanel: { _ in nil }
        )
        var appearance = BonsplitConfiguration.Appearance.default
        appearance.tabBarHeight = 36
        appearance.tabTitleFontSize = 14
        appearance.tabBarLeadingInset = 72
        var workspaceConfiguration = BonsplitConfiguration(
            allowCloseTabs: false,
            appearance: appearance
        )

        mirror.applyWorkspaceBonsplitConfiguration(workspaceConfiguration)
        #expect(mirror.bonsplitController.configuration.appearance.tabBarHeight == 36)
        #expect(mirror.bonsplitController.configuration.appearance.tabTitleFontSize == 14)
        #expect(mirror.bonsplitController.configuration.appearance.tabBarLeadingInset == 0)
        #expect(!mirror.bonsplitController.configuration.allowCloseTabs)
        #expect(!mirror.bonsplitController.configuration.allowsTabContextMenu)
        #expect(!mirror.bonsplitController.tabShortcutHintsEnabled)

        workspaceConfiguration.appearance.tabBarHeight = 42
        workspaceConfiguration.appearance.tabTitleFontSize = 16
        mirror.applyWorkspaceBonsplitConfiguration(workspaceConfiguration)
        #expect(mirror.bonsplitController.configuration.appearance.tabBarHeight == 42)
        #expect(mirror.bonsplitController.configuration.appearance.tabTitleFontSize == 16)
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace
        let sourcePanelId: UUID

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
            sourcePanelId = try #require(workspace.focusedPanelId)
        }

        func tearDown() {
            workspace.isRemoteTmuxMirror = false
            let identifier = "cmux.main.\(windowId.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}

@MainActor
private struct SessionMirrorFixture {
    let connection: RemoteTmuxControlConnection
    let writer: RemoteTmuxControlPipeWriter
    let pipe: Pipe
    let sessionMirror: RemoteTmuxSessionMirror

    init() {
        connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "split-cwd.test"),
            sessionName: "work"
        )
        pipe = Pipe()
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-split-cwd-test",
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
        let workspace = manager.selectedWorkspace!
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

    func writtenCommands(prefix: String) -> [String] {
        writer.close()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix(prefix) }
    }

    func close() {
        sessionMirror.detachObserver()
        writer.close()
    }
}
