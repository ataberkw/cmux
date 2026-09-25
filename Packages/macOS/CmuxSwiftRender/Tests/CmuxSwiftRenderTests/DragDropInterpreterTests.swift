import Testing
@testable import CmuxSwiftRender

@Suite struct DragDropInterpreterTests {
    let interp = SwiftViewInterpreter()

    @Test func draggableCapturesEvaluatedPayload() {
        let node = interp.evaluate("""
        Rectangle().draggable(pane.panelId)
        """, state: ["pane": .object(["panelId": .string("P-1")])])
        #expect(node?.kind == .rectangle)
        #expect(node?.dragPayload == "P-1")
        #expect(node?.modifiers.contains { $0.name == "draggable" } == false)
    }

    @Test func dropDestinationWithZoneBindsPlaceholders() {
        let node = interp.evaluate("""
        Rectangle().dropDestination { surface, zone in
            cmux("surface.move", surface_id: surface, pane_id: pane.paneId, split: zone)
        }
        """, state: ["pane": .object(["paneId": .string("PANE-9")])])
        #expect(node?.drop?.usesZones == true)
        #expect(node?.drop?.action.commands == [
            .cmux(method: "surface.move", params: [
                "surface_id": DropSpec.payloadToken,
                "pane_id": "PANE-9",
                "split": DropSpec.zoneToken,
            ]),
        ])
    }

    @Test func dropDestinationWithoutZoneIsWholeTarget() {
        let node = interp.evaluate("""
        VStack { Text("ws") }.dropDestination { surface in
            cmux("surface.move", surface_id: surface, workspace_id: "W")
        }
        """)
        #expect(node?.drop?.usesZones == false)
        let resolved = node?.drop?.resolvedAction(payload: "S-1", zone: .center)
        #expect(resolved?.commands == [
            .cmux(method: "surface.move", params: ["surface_id": "S-1", "workspace_id": "W"]),
        ])
    }

    @Test func resolvedActionSubstitutesPayloadAndZone() {
        let spec = DropSpec(
            action: ButtonAction(commands: [
                .cmux(method: "surface.move", params: ["surface_id": DropSpec.payloadToken, "split": DropSpec.zoneToken]),
                .log("dropped \(DropSpec.payloadToken) on \(DropSpec.zoneToken)"),
            ]),
            usesZones: true
        )
        #expect(spec.resolvedAction(payload: "S-2", zone: .left).commands == [
            .cmux(method: "surface.move", params: ["surface_id": "S-2", "split": "left"]),
            .log("dropped S-2 on left"),
        ])
    }

    @Test func dragAndTapCoexistOnOneNode() {
        let node = interp.evaluate("""
        Rectangle()
            .onTapGesture { cmux("surface.focus", surface_id: "S") }
            .draggable("S")
            .dropDestination { p, z in cmux("surface.move", surface_id: p, split: z) }
        """)
        #expect(node?.action?.commands == [.cmux(method: "surface.focus", params: ["surface_id": "S"])])
        #expect(node?.dragPayload == "S")
        #expect(node?.drop != nil)
    }
}

@Suite struct DropZoneTests {
    // A 100x80 target: edge bands are 25pt wide (x) and 20pt tall (y).
    @Test func middleIsCenter() {
        #expect(DropZone.resolve(x: 50, y: 40, width: 100, height: 80) == .center)
        #expect(DropZone.resolve(x: 26, y: 21, width: 100, height: 80) == .center)
    }

    @Test func edgeBandsResolveToTheirSide() {
        #expect(DropZone.resolve(x: 5, y: 40, width: 100, height: 80) == .left)
        #expect(DropZone.resolve(x: 95, y: 40, width: 100, height: 80) == .right)
        #expect(DropZone.resolve(x: 50, y: 5, width: 100, height: 80) == .up)
        #expect(DropZone.resolve(x: 50, y: 75, width: 100, height: 80) == .down)
    }

    @Test func cornerPicksNearestEdge() {
        // 2% from the left, 10% from the top: left wins.
        #expect(DropZone.resolve(x: 2, y: 8, width: 100, height: 80) == .left)
        // 20% from the right, 2.5% from the bottom: down wins.
        #expect(DropZone.resolve(x: 80, y: 78, width: 100, height: 80) == .down)
    }

    @Test func degenerateTargetIsCenter() {
        #expect(DropZone.resolve(x: 0, y: 0, width: 0, height: 10) == .center)
    }
}
