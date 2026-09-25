import CmuxSwiftRender
import SwiftUI

/// Accumulates every ``SidebarDragRegion`` in the rendered sidebar.
public struct SidebarDragRegionsKey: PreferenceKey {
    /// No regions until the render tree reports some.
    public static let defaultValue: [SidebarDragRegion] = []

    /// Concatenates regions from sibling subtrees.
    public static func reduce(value: inout [SidebarDragRegion], nextValue: () -> [SidebarDragRegion]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Reports this view's global frame as a drag source and/or drop target
    /// for the node's `.draggable` / `.dropDestination`. No-op when the node
    /// has neither.
    @ViewBuilder
    func reportDragRegions(payload: String?, drop: DropSpec?) -> some View {
        if payload != nil || drop != nil {
            background(
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    Color.clear.preference(
                        key: SidebarDragRegionsKey.self,
                        value: [
                            payload.map { SidebarDragRegion(frame: frame, role: .source(payload: $0)) },
                            drop.map { SidebarDragRegion(frame: frame, role: .target($0)) },
                        ].compactMap { $0 }
                    )
                }
            )
        } else {
            self
        }
    }
}
