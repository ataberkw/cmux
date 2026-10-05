import AppKit
import CmuxSwiftRender
import SwiftUI

/// In-process sidebar drag-and-drop: a root `DragGesture` hit-tests the
/// reported ``SidebarDragRegion``s, drives a ``SidebarDragSession``, draws
/// ``SidebarDragFeedbackOverlay``, and dispatches the drop's action.
///
/// The gesture is simultaneous and has a minimum distance, so taps on rows and
/// scrolling keep working; a press that doesn't start on a source is ignored
/// for the rest of that gesture.
///
/// A drag that leaves this sidebar is handed to
/// ``SidebarCrossWindowDropRouter``, which resolves it against the custom
/// sidebar of the window under the pointer, so a workspace dragged out of one
/// window's sidebar can drop into another's.
struct SidebarDragInteraction: ViewModifier {
    let dispatch: SidebarActionDispatch

    /// Latest reported regions and cross-window endpoints, in a non-observed
    /// reference box: regions change on every layout pass but only the
    /// gesture reads them, so storing them must not invalidate the view (no
    /// preference → state → layout loop).
    @State private var store = SidebarDragRegionStore()
    @State private var session: SidebarDragSession?
    @State private var pressRejected = false
    /// A hover drawn here for a drag that started in another window.
    @State private var remoteHover: SidebarDragSession.Hover?

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(SidebarDragRegionsKey.self) { [store] newRegions in
                MainActor.assumeIsolated { store.regions = newRegions }
            }
            .background {
                GeometryReader { proxy in
                    SidebarDragAnchor(store: store, rootGlobalFrame: proxy.frame(in: .global))
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: SidebarDragSession.activationDistance, coordinateSpace: .global)
                    .onChanged { value in
                        // Only the source and the hovered target/zone are
                        // drawn, so `session` (state) is written only when
                        // the drag starts or its hover changes, not on every
                        // pointer move. `onEnded` re-resolves at the final
                        // location, so the stale `location` never matters.
                        if var current = session {
                            if current.move(to: value.location, regions: store.regions) {
                                session = current
                            }
                            updateCrossWindowHover(current, at: value.location)
                            return
                        }
                        guard !pressRejected else { return }
                        guard var started = SidebarDragSession(pressedAt: value.startLocation, regions: store.regions) else {
                            pressRejected = true
                            return
                        }
                        started.move(to: value.location, regions: store.regions)
                        session = started
                    }
                    .onEnded { value in
                        defer {
                            session = nil
                            pressRejected = false
                        }
                        guard var finished = session else { return }
                        finished.move(to: value.location, regions: store.regions)
                        if let action = finished.dropAction {
                            SidebarCrossWindowDropRouter.shared.updateHover(screenPoint: nil, kind: finished.kind, from: store)
                            dispatch.run(action)
                        } else if leftSidebar(at: value.location) {
                            SidebarCrossWindowDropRouter.shared.drop(
                                payload: finished.payload,
                                kind: finished.kind,
                                screenPoint: NSEvent.mouseLocation,
                                from: store
                            )
                        } else {
                            SidebarCrossWindowDropRouter.shared.updateHover(screenPoint: nil, kind: finished.kind, from: store)
                        }
                    }
            )
            .overlay { SidebarDragFeedbackOverlay(session: session, remoteHover: remoteHover) }
            .onAppear {
                store.dispatch = dispatch
                store.onRemoteHover = { remoteHover = $0 }
                SidebarCrossWindowDropRouter.shared.register(store)
            }
            .onDisappear {
                SidebarCrossWindowDropRouter.shared.unregister(store)
                store.onRemoteHover = nil
                remoteHover = nil
            }
    }

    /// Whether `location` (`.global`) is outside this sidebar, where only
    /// another window's sidebar can take the drop.
    private func leftSidebar(at location: CGPoint) -> Bool {
        !store.rootGlobalFrame.contains(location)
    }

    /// Draws the hover in another window's sidebar while the pointer is
    /// outside this one; clears it once the pointer is back.
    private func updateCrossWindowHover(_ session: SidebarDragSession, at location: CGPoint) {
        let screenPoint = leftSidebar(at: location) ? NSEvent.mouseLocation : nil
        SidebarCrossWindowDropRouter.shared.updateHover(screenPoint: screenPoint, kind: session.kind, from: store)
    }
}

/// Records the sidebar root's `.global` frame and a flipped AppKit anchor on
/// the store, so the router can map screen points into this sidebar.
private struct SidebarDragAnchor: NSViewRepresentable {
    let store: SidebarDragRegionStore
    let rootGlobalFrame: CGRect

    func makeNSView(context: Context) -> SidebarDragAnchorView {
        let view = SidebarDragAnchorView()
        store.addAnchor(view)
        store.rootGlobalFrame = rootGlobalFrame
        return view
    }

    func updateNSView(_ view: SidebarDragAnchorView, context: Context) {
        store.addAnchor(view)
        store.rootGlobalFrame = rootGlobalFrame
    }
}

extension View {
    /// Enables geometric drag-and-drop between the rendered tree's
    /// `.draggable` sources and `.dropDestination` targets, including drops
    /// into another window's custom sidebar.
    func sidebarDragInteraction(dispatch: SidebarActionDispatch) -> some View {
        modifier(SidebarDragInteraction(dispatch: dispatch))
    }
}
