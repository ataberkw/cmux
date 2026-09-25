import CmuxSwiftRender
import SwiftUI

/// In-process sidebar drag-and-drop: a root `DragGesture` hit-tests the
/// reported ``SidebarDragRegion``s, drives a ``SidebarDragSession``, draws
/// ``SidebarDragFeedbackOverlay``, and dispatches the drop's action.
///
/// The gesture is simultaneous and has a minimum distance, so taps on rows and
/// scrolling keep working; a press that doesn't start on a source is ignored
/// for the rest of that gesture.
struct SidebarDragInteraction: ViewModifier {
    let dispatch: SidebarActionDispatch

    /// Latest reported regions, in a non-observed reference box: regions
    /// change on every layout pass but only the gesture reads them, so storing
    /// them must not invalidate the view (no preference → state → layout loop).
    @State private var store = SidebarDragRegionStore()
    @State private var session: SidebarDragSession?
    @State private var pressRejected = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(SidebarDragRegionsKey.self) { [store] newRegions in
                MainActor.assumeIsolated { store.regions = newRegions }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: SidebarDragSession.activationDistance, coordinateSpace: .global)
                    .onChanged { value in
                        if session == nil {
                            guard !pressRejected else { return }
                            guard let started = SidebarDragSession(pressedAt: value.startLocation, regions: store.regions) else {
                                pressRejected = true
                                return
                            }
                            session = started
                        }
                        session?.move(to: value.location, regions: store.regions)
                    }
                    .onEnded { value in
                        defer {
                            session = nil
                            pressRejected = false
                        }
                        guard var finished = session else { return }
                        finished.move(to: value.location, regions: store.regions)
                        if let action = finished.dropAction { dispatch.run(action) }
                    }
            )
            .overlay { SidebarDragFeedbackOverlay(session: session) }
    }
}

/// Non-observed holder for the latest ``SidebarDragRegion``s.
@MainActor
final class SidebarDragRegionStore {
    var regions: [SidebarDragRegion] = []
}

extension View {
    /// Enables geometric drag-and-drop between the rendered tree's
    /// `.draggable` sources and `.dropDestination` targets.
    func sidebarDragInteraction(dispatch: SidebarActionDispatch) -> some View {
        modifier(SidebarDragInteraction(dispatch: dispatch))
    }
}
