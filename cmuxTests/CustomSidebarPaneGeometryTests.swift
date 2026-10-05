import Bonsplit
import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The custom-sidebar snapshot reads pane geometry off the same tree walk as
/// the split layout tree instead of a second `layoutSnapshot()` pass; the
/// numbers must still match what `layoutSnapshot()` (the socket `pane.list`
/// source) reports.
@MainActor
struct CustomSidebarPaneGeometryTests {
    @Test func treeGeometryMatchesLayoutSnapshot() throws {
        let controller = BonsplitController()
        controller.setContainerFrame(CGRect(x: 40, y: 28, width: 1200, height: 800))
        let first = try #require(controller.allPaneIds.first)
        let right = try #require(controller.splitPane(first, orientation: .horizontal, initialDividerPosition: 0.3))
        _ = try #require(controller.splitPane(right, orientation: .vertical, initialDividerPosition: 0.6))

        let layout = controller.layoutSnapshot()
        let geometry = Workspace.customSidebarPaneGeometry(controller.treeSnapshot())

        #expect(geometry.frameByPaneId.count == layout.panes.count)
        for pane in layout.panes {
            let frame = try #require(geometry.frameByPaneId[pane.paneId])
            #expect(frame.x == pane.frame.x)
            #expect(frame.y == pane.frame.y)
            #expect(frame.width == pane.frame.width)
            #expect(frame.height == pane.frame.height)
        }
        let tolerance = 1e-6
        #expect(abs(geometry.containerFrame.x - layout.containerFrame.x) < tolerance)
        #expect(abs(geometry.containerFrame.y - layout.containerFrame.y) < tolerance)
        #expect(abs(geometry.containerFrame.width - layout.containerFrame.width) < tolerance)
        #expect(abs(geometry.containerFrame.height - layout.containerFrame.height) < tolerance)
    }
}
