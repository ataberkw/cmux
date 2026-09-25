import CmuxRemoteSession
import CmuxSwiftRender
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension RemoteTmuxMirrorCLIObservabilityTests {
    /// The custom-sidebar layout tree expands a mirrored tmux window's single
    /// outer cell into the tmux window's own pane tree, so a split-map sidebar
    /// draws every tmux pane instead of one `claude` cell.
    @Test func sidebarLayoutTreeExpandsMirroredTmuxWindowIntoItsPanes() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let left = try #require(harness.mirror.panel(forPane: 11))
        let right = try #require(harness.mirror.panel(forPane: 22))

        let tree = try #require(sidebarLayoutTree(harness))

        #expect(tree["kind"] == .string("split"))
        #expect(tree["orientation"] == .string("horizontal"))
        let first = try #require(objectFields(tree["first"]))
        let second = try #require(objectFields(tree["second"]))
        #expect(first["nested"] == .bool(true))
        #expect(first["surfaceId"] == .string(left.id.uuidString))
        #expect(first["focused"] == .bool(false))
        #expect(second["surfaceId"] == .string(right.id.uuidString))
        #expect(second["focused"] == .bool(true))
        #expect(first["zoomed"] == nil)
    }

    /// A zoomed tmux window still projects every pane (the base tree) so the
    /// hidden panes stay visible in the map, with the zoomed one flagged.
    @Test func sidebarLayoutTreeKeepsHiddenPanesWhileTmuxWindowIsZoomed() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let base = harness.mirror.layout
        harness.mirror.apply(window: RemoteTmuxWindow(
            id: 3, name: "claude", width: 80, height: 24,
            layout: base,
            visibleLayout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(22)),
            zoomed: true
        ))

        let tree = try #require(sidebarLayoutTree(harness))

        #expect(tree["kind"] == .string("split"))
        let first = try #require(objectFields(tree["first"]))
        let second = try #require(objectFields(tree["second"]))
        #expect(first["zoomed"] == nil)
        #expect(second["zoomed"] == .bool(true))
    }

    private func sidebarLayoutTree(_ harness: Harness) -> [String: SwiftValue]? {
        let snapshot = harness.workspace.customSidebarWorkspaceSnapshot(
            index: 0,
            selectedId: harness.workspace.id,
            unreadCount: 0
        )
        return objectFields(snapshot.layoutTree)
    }

    private func objectFields(_ value: SwiftValue?) -> [String: SwiftValue]? {
        guard case let .object(fields)? = value else { return nil }
        return fields
    }
}
