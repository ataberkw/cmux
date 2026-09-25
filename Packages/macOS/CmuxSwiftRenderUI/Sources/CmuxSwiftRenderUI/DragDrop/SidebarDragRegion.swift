import CmuxSwiftRender
import CoreGraphics

/// A drag source or drop target reported by the rendered sidebar tree, with
/// its frame in the root (`.global`) coordinate space (top-left origin).
///
/// Collected through ``SidebarDragRegionsKey`` so both render lanes can run
/// drag-and-drop geometrically: the in-process sidebar from a root
/// `DragGesture`, and the out-of-process worker from forwarded pointer events
/// (SwiftUI's own `.draggable` never fires in a never-on-screen window).
public struct SidebarDragRegion: Equatable, Sendable {
    /// What the region does in a drag.
    public enum Role: Equatable, Sendable {
        /// Pressing and dragging here starts a drag carrying `payload`.
        case source(payload: String)
        /// Releasing a drag here runs the spec's action.
        case target(DropSpec)
    }

    /// The region's frame in the root coordinate space.
    public let frame: CGRect
    /// The region's role.
    public let role: Role

    /// Creates a region.
    ///
    /// - Parameters:
    ///   - frame: The frame in the root coordinate space (top-left origin).
    ///   - role: Whether the region starts drags or accepts drops.
    public init(frame: CGRect, role: Role) {
        self.frame = frame
        self.role = role
    }
}
