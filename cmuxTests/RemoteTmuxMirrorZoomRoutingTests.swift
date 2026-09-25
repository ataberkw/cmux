import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension RemoteTmuxMirrorCLIObservabilityTests {
    /// Toggle Pane Zoom on a mirrored tmux window zooms the active tmux pane.
    /// The whole window renders inside ONE outer pane, so the outer Bonsplit
    /// zoom has nothing to act on; the nested pane tree must get first refusal.
    @Test func toggleFocusedSplitZoomZoomsActiveTmuxPane() throws {
        let harness = try Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let manager = try #require(harness.appDelegate.tabManagerFor(windowId: harness.windowID))

        #expect(manager.toggleFocusedSplitZoom())

        let commands = try zoomRoutingControlCommands(harness)
        #expect(commands.contains("resize-pane -Z -t @3.%22\n"))
        #expect(!harness.workspace.bonsplitController.isSplitZoomed)
    }

    /// A Ghostty `toggle_split_zoom` keybind fires from the inner pane's own
    /// surface, so the inner panel id must resolve to its owning mirror.
    @Test func toggleSplitZoomFromInnerPanePanelZoomsThatTmuxPane() throws {
        let harness = try Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let innerPanel = try #require(harness.mirror.panel(forPane: 11))

        #expect(harness.workspace.toggleSplitZoom(panelId: innerPanel.id))

        let commands = try zoomRoutingControlCommands(harness)
        #expect(commands.contains("resize-pane -Z -t @3.%11\n"))
    }

    /// A single-pane tmux window has nothing to zoom inside, so the shortcut
    /// keeps its workspace-level meaning and sends nothing to tmux.
    @Test func toggleSplitZoomOnSinglePaneTmuxWindowFallsThroughToWorkspace() throws {
        let layout = RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(11))
        let harness = try Harness(activeTmuxPaneID: 11, connectedTransport: true, mirrorLayout: layout)
        defer { harness.tearDown() }

        _ = harness.workspace.toggleSplitZoom(panelId: harness.outerPanelID)

        let commands = try zoomRoutingControlCommands(harness)
        #expect(!commands.contains("resize-pane -Z"))
    }

    private func zoomRoutingControlCommands(_ harness: Harness) throws -> String {
        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        return try #require(String(
            bytes: try pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ))
    }
}
