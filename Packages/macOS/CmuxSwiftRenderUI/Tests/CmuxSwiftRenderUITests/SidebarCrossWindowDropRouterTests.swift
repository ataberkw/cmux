import AppKit
import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import Testing

/// A drag that leaves one window's custom sidebar lands on the custom sidebar
/// of the window under the pointer.
@MainActor
struct SidebarCrossWindowDropRouterTests {
    private let moveHere = DropSpec(
        action: ButtonAction(commands: [
            .cmux(method: "workspace.move_to_window", params: ["workspace_id": DropSpec.payloadToken, "window_id": "WIN-B"]),
        ]),
        usesZones: false,
        kind: "workspace"
    )

    /// A borderless window at `origin` (screen coords) whose content is one
    /// 200x400 sidebar with the anchor covering it.
    private func makeSidebar(origin: CGPoint, run: @escaping @MainActor @Sendable (ButtonAction) -> Void)
        -> (NSWindow, SidebarDragRegionStore)
    {
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 200, height: 400)),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = SidebarDragAnchorView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        window.contentView?.addSubview(anchor)
        let store = SidebarDragRegionStore()
        store.addAnchor(anchor)
        // The sidebar root sits at (10, 20) in its window's `.global` space.
        store.rootGlobalFrame = CGRect(x: 10, y: 20, width: 200, height: 400)
        store.dispatch = SidebarActionDispatch(run: run)
        return (window, store)
    }

    @Test func dropOverAnotherWindowsSidebarRunsItsTarget() throws {
        var ran: [ButtonAction] = []
        let (sourceWindow, source) = makeSidebar(origin: CGPoint(x: 0, y: 0)) { _ in }
        let (targetWindow, target) = makeSidebar(origin: CGPoint(x: 500, y: 100)) { ran.append($0) }
        _ = sourceWindow
        // The target's root-wide workspace drop zone, in its `.global` space.
        target.regions = [SidebarDragRegion(frame: CGRect(x: 10, y: 20, width: 200, height: 400), role: .target(moveHere))]

        let router = SidebarCrossWindowDropRouter()
        router.windowsAtScreenPoint = { _ in [targetWindow] }
        router.register(source)
        router.register(target)

        // Screen (550, 450) is 50pt in and 50pt below the target window's top
        // edge (its frame spans y 100...500).
        var hovers: [SidebarDragSession.Hover?] = []
        target.onRemoteHover = { hovers.append($0) }
        router.updateHover(screenPoint: CGPoint(x: 550, y: 450), kind: "workspace", from: source)
        router.updateHover(screenPoint: CGPoint(x: 551, y: 451), kind: "workspace", from: source)
        #expect(hovers.count == 1)
        #expect(hovers.first??.targetFrame == CGRect(x: 10, y: 20, width: 200, height: 400))

        let dropped = router.drop(payload: "W-1", kind: "workspace", screenPoint: CGPoint(x: 550, y: 450), from: source)
        #expect(dropped)
        #expect(ran.map(\.commands) == [[
            .cmux(method: "workspace.move_to_window", params: ["workspace_id": "W-1", "window_id": "WIN-B"]),
        ]])
        // The drop clears the target's hover.
        #expect(hovers.last == .some(nil))
    }

    /// SwiftUI can mount a replacement anchor and then remove the old one.
    /// The removed anchor must not hide the live one: that left every
    /// sidebar windowless and no cross-window drop ever landed.
    @Test func replacedAnchorDoesNotHideTheLiveOne() {
        var ran = 0
        let (_, source) = makeSidebar(origin: CGPoint(x: 0, y: 0)) { _ in }
        let (targetWindow, target) = makeSidebar(origin: CGPoint(x: 500, y: 100)) { _ in ran += 1 }
        target.regions = [SidebarDragRegion(frame: CGRect(x: 10, y: 20, width: 200, height: 400), role: .target(moveHere))]
        // A detached anchor registered after the live one.
        let detached = SidebarDragAnchorView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        target.addAnchor(detached)
        let router = SidebarCrossWindowDropRouter()
        router.windowsAtScreenPoint = { _ in [targetWindow] }
        router.register(source)
        router.register(target)

        #expect(router.drop(payload: "W-1", kind: "workspace", screenPoint: CGPoint(x: 550, y: 450), from: source))
        #expect(ran == 1)
        withExtendedLifetime(detached) {}
    }

    @Test func dropIsIgnoredForOtherKindsOtherWindowsAndOutsideTheSidebar() {
        var ran = 0
        let (_, source) = makeSidebar(origin: CGPoint(x: 0, y: 0)) { _ in }
        let (targetWindow, target) = makeSidebar(origin: CGPoint(x: 500, y: 100)) { _ in ran += 1 }
        target.regions = [SidebarDragRegion(frame: CGRect(x: 10, y: 20, width: 200, height: 400), role: .target(moveHere))]
        let router = SidebarCrossWindowDropRouter()
        router.register(source)
        router.register(target)

        router.windowsAtScreenPoint = { _ in [targetWindow] }
        // A pane (default-kind) payload: the workspace target refuses it.
        #expect(!router.drop(payload: "P-1", kind: nil, screenPoint: CGPoint(x: 550, y: 450), from: source))
        // Over the target window but left of its sidebar root.
        #expect(!router.drop(payload: "W-1", kind: "workspace", screenPoint: CGPoint(x: 450, y: 450), from: source))

        // Another window covers the target at the point.
        let cover = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        router.windowsAtScreenPoint = { _ in [cover, targetWindow] }
        #expect(!router.drop(payload: "W-1", kind: "workspace", screenPoint: CGPoint(x: 550, y: 450), from: source))

        // The source's own sidebar is never a cross-window target.
        router.unregister(target)
        #expect(!router.drop(payload: "W-1", kind: "workspace", screenPoint: CGPoint(x: 550, y: 450), from: source))
        #expect(ran == 0)
    }
}
