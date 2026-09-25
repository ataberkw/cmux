import CmuxSwiftRenderUI
import SwiftUI

/// The worker's SwiftUI root: the shared sidebar presentation plus collection
/// of the rendered tree's tap targets and drag regions, so the coordinator can
/// hit-test forwarded clicks and drags geometrically, and the feedback overlay
/// for the drag the coordinator is driving.
struct RemoteWorkerRootView: View {
    let content: CustomSidebarContentView
    /// The in-flight drag, if any, drawn over the content.
    let dragSession: SidebarDragSession?
    /// Receives the rendered tree's tappable regions after each layout pass.
    let onTapTargetsChange: @MainActor @Sendable ([SidebarTapTarget]) -> Void
    /// Receives the rendered tree's drag sources/targets after each layout pass.
    let onDragRegionsChange: @MainActor @Sendable ([SidebarDragRegion]) -> Void

    var body: some View {
        content
            .onPreferenceChange(SidebarTapTargetsKey.self) { targets in
                Task { @MainActor in
                    onTapTargetsChange(targets)
                }
            }
            .onPreferenceChange(SidebarDragRegionsKey.self) { regions in
                Task { @MainActor in
                    onDragRegionsChange(regions)
                }
            }
            .overlay { SidebarDragFeedbackOverlay(session: dragSession) }
    }
}
