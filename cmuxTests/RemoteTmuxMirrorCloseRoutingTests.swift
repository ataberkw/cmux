import CmuxRemoteSession
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension RemoteTmuxMirrorCLIObservabilityTests {
    /// Cmd+W on a mirrored multi-pane tmux window closes the active tmux pane.
    /// The whole window renders inside ONE outer tab, so closing that tab
    /// sends kill-window and takes every pane (and a one-window session) down.
    @Test func closeCurrentPanelOnMultiPaneTmuxWindowKillsActiveTmuxPane() throws {
        try withCloseShortcutWarningDisabled {
            let harness = try Harness(connectedTransport: true)
            defer { harness.tearDown() }
            let manager = try #require(harness.appDelegate.tabManagerFor(windowId: harness.windowID))

            manager.closeCurrentPanelWithConfirmation()

            let commands = try closeRoutingControlCommands(harness)
            #expect(commands.contains("kill-pane -t @3.%22\n"))
            #expect(!commands.contains("kill-window"))
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }
    }

    /// A single-pane tmux window has no inner pane to close apart from the
    /// window itself, so Cmd+W keeps its tab-level meaning.
    @Test func closeCurrentPanelOnSinglePaneTmuxWindowFallsThroughToTabClose() throws {
        try withCloseShortcutWarningDisabled {
            let layout = RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(11))
            let harness = try Harness(activeTmuxPaneID: 11, connectedTransport: true, mirrorLayout: layout)
            defer { harness.tearDown() }
            let manager = try #require(harness.appDelegate.tabManagerFor(windowId: harness.windowID))

            manager.closeCurrentPanelWithConfirmation()

            let commands = try closeRoutingControlCommands(harness)
            #expect(!commands.contains("kill-pane"))
        }
    }

    private func withCloseShortcutWarningDisabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let key = AppCatalogSection().warnBeforeClosingTab.userDefaultsKey
        let original = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try body()
    }

    private func closeRoutingControlCommands(_ harness: Harness) throws -> String {
        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        return try #require(String(
            bytes: try pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ))
    }
}
