import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import CoreGraphics
import Testing

struct SidebarDragSessionTests {
    // Layout: workspace A's cell (source + target) above workspace B, whose
    // block is a whole-workspace target containing one zoned pane cell.
    private let cellA = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let blockB = CGRect(x: 0, y: 120, width: 100, height: 140)
    private let cellB = CGRect(x: 0, y: 140, width: 100, height: 100)

    private let paneSpec = DropSpec(
        action: ButtonAction(commands: [
            .cmux(method: "surface.move", params: [
                "surface_id": DropSpec.payloadToken, "pane_id": "PB", "split": DropSpec.zoneToken,
            ]),
        ]),
        usesZones: true
    )
    private let workspaceSpec = DropSpec(
        action: ButtonAction(commands: [
            .cmux(method: "surface.move", params: ["surface_id": DropSpec.payloadToken, "workspace_id": "WB"]),
        ]),
        usesZones: false
    )

    private var regions: [SidebarDragRegion] {
        [
            SidebarDragRegion(frame: cellA, role: .source(payload: "SA")),
            SidebarDragRegion(frame: cellA, role: .target(paneSpec)),
            SidebarDragRegion(frame: blockB, role: .target(workspaceSpec)),
            SidebarDragRegion(frame: cellB, role: .source(payload: "SB")),
            SidebarDragRegion(frame: cellB, role: .target(paneSpec)),
        ]
    }

    @Test func pressOutsideAnySourceStartsNothing() {
        #expect(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 110), regions: regions) == nil)
    }

    @Test func activationNeedsMinimumTravel() {
        let start = CGPoint(x: 10, y: 10)
        #expect(!SidebarDragSession.hasActivated(from: start, to: CGPoint(x: 12, y: 12)))
        #expect(SidebarDragSession.hasActivated(from: start, to: CGPoint(x: 10, y: 16)))
    }

    @Test func moveReportsOnlyHoverChanges() throws {
        var session = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 50), regions: regions))
        // Entering B's cell center makes the hover appear; wiggling in the same
        // zone redraws nothing; crossing into the left edge zone does; leaving
        // every target clears the hover once, then stays quiet.
        let steps: [(CGPoint, Bool)] = [
            (CGPoint(x: 50, y: 190), true),
            (CGPoint(x: 52, y: 192), false),
            (CGPoint(x: 5, y: 190), true),
            (CGPoint(x: 50, y: 110), true),
            (CGPoint(x: 50, y: 112), false),
        ]
        for (point, expectedChange) in steps {
            let changed = session.move(to: point, regions: regions)
            #expect(changed == expectedChange, "move to \(point)")
        }
        #expect(session.location == CGPoint(x: 50, y: 112))
    }

    @Test func droppingOnOwnSourceIsANoOp() throws {
        var session = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 50), regions: regions))
        session.move(to: CGPoint(x: 90, y: 50), regions: regions)
        #expect(session.hover == nil)
        #expect(session.dropAction == nil)
    }

    @Test func ownSourceShadowsItsEnclosingWorkspaceTarget() throws {
        // Drag B's cell and hover it again: block B encloses it, but the drop
        // must not fall through to "join workspace B".
        var session = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 190), regions: regions))
        session.move(to: CGPoint(x: 55, y: 195), regions: regions)
        #expect(session.hover == nil)
        #expect(session.dropAction == nil)
    }

    @Test func edgeOfAnotherPaneSplitsThatSide() throws {
        var session = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 50), regions: regions))
        session.move(to: CGPoint(x: 95, y: 190), regions: regions)
        #expect(session.hover?.zone == .right)
        #expect(session.hover?.highlightFrame == CGRect(x: 50, y: 140, width: 50, height: 100))
        #expect(session.dropAction?.commands == [
            .cmux(method: "surface.move", params: ["surface_id": "SA", "pane_id": "PB", "split": "right"]),
        ])
    }

    @Test func middleOfAnotherPaneJoinsAsTab() throws {
        var session = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 50), regions: regions))
        session.move(to: CGPoint(x: 50, y: 190), regions: regions)
        #expect(session.hover?.zone == .center)
        #expect(session.hover?.highlightFrame == cellB)
        #expect(session.dropAction?.commands == [
            .cmux(method: "surface.move", params: ["surface_id": "SA", "pane_id": "PB", "split": "center"]),
        ])
    }

    @Test func workspaceBlockOutsideCellsTakesWholeWorkspaceDrop() throws {
        var session = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 50), regions: regions))
        // Inside block B but above its cell (the header band).
        session.move(to: CGPoint(x: 50, y: 128), regions: regions)
        #expect(session.hover?.targetFrame == blockB)
        #expect(session.dropAction?.commands == [
            .cmux(method: "surface.move", params: ["surface_id": "SA", "workspace_id": "WB"]),
        ])
    }

    @Test func leavingAllTargetsClearsHover() throws {
        var session = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 50), regions: regions))
        session.move(to: CGPoint(x: 50, y: 190), regions: regions)
        session.move(to: CGPoint(x: 300, y: 300), regions: regions)
        #expect(session.hover == nil)
        #expect(session.dropAction == nil)
    }

    /// A workspace drag and a pane drag share one sidebar; each lands only on
    /// targets of its own kind, so a workspace never "moves" as a surface.
    @Test func kindsPairOnlySameKindSourcesAndTargets() throws {
        let header = CGRect(x: 0, y: 300, width: 100, height: 20)
        let moveWorkspace = DropSpec(
            action: ButtonAction(commands: [
                .cmux(method: "workspace.move_to_window", params: ["workspace_id": DropSpec.payloadToken, "window_id": "WIN"]),
            ]),
            usesZones: false,
            kind: "workspace"
        )
        let typed = regions + [
            SidebarDragRegion(frame: header, role: .source(payload: "WA", kind: "workspace")),
            // A typed target on block B, which does not enclose the header.
            SidebarDragRegion(frame: blockB, role: .target(moveWorkspace)),
        ]

        var workspaceDrag = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 310), regions: typed))
        #expect(workspaceDrag.kind == "workspace")
        // Over B's pane cell: the pane target ignores it and the enclosing
        // workspace-kind target takes it.
        workspaceDrag.move(to: CGPoint(x: 50, y: 190), regions: typed)
        #expect(workspaceDrag.hover?.targetFrame == blockB)
        #expect(workspaceDrag.dropAction?.commands == [
            .cmux(method: "workspace.move_to_window", params: ["workspace_id": "WA", "window_id": "WIN"]),
        ])

        // A pane drag over block B's header band finds the untyped workspace
        // target, never the workspace-kind one.
        var paneDrag = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 50), regions: typed))
        #expect(paneDrag.kind == nil)
        paneDrag.move(to: CGPoint(x: 50, y: 128), regions: typed)
        #expect(paneDrag.dropAction?.commands.first == .cmux(
            method: "surface.move", params: ["surface_id": "SA", "workspace_id": "WB"]
        ))
    }

    /// A window-wide "move workspace here" target encloses the window's own
    /// workspace headers. Dropping a header back into its own window is a
    /// no-op, so that target must not light up for it.
    @Test func typedTargetEnclosingTheSourceIsSkipped() throws {
        let header = CGRect(x: 0, y: 300, width: 100, height: 20)
        let root = CGRect(x: 0, y: 0, width: 100, height: 400)
        let moveWorkspace = DropSpec(action: ButtonAction(commands: []), usesZones: false, kind: "workspace")
        let typed = [
            SidebarDragRegion(frame: header, role: .source(payload: "WA", kind: "workspace")),
            SidebarDragRegion(frame: root, role: .target(moveWorkspace)),
        ]
        var drag = try #require(SidebarDragSession(pressedAt: CGPoint(x: 50, y: 310), regions: typed))
        drag.move(to: CGPoint(x: 50, y: 100), regions: typed)
        #expect(drag.hover == nil)
        // The same target in another window (no source frame) takes it.
        let remote = SidebarDragSession.resolveHover(
            at: CGPoint(x: 50, y: 100), regions: typed, kind: "workspace", sourceFrame: nil
        )
        #expect(remote?.targetFrame == root)
    }

    @Test func emptyKindIsTheDefaultKind() {
        let spec = DropSpec(action: ButtonAction(commands: []), usesZones: false, kind: "")
        #expect(spec.kind == nil)
        #expect(spec.accepts(payloadKind: nil))
        #expect(spec.accepts(payloadKind: ""))
        #expect(!spec.accepts(payloadKind: "workspace"))
    }

}
