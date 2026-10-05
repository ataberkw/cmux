import SwiftUI

/// Draws an in-flight drag's feedback over the sidebar: a dashed outline on
/// the source and a tinted highlight on the half (or whole) of the target the
/// drop would occupy. Frames arrive in the global space and are converted to
/// this overlay's local space, so it must cover the whole sidebar root.
///
/// Purely visual: it never takes hits, so the drag gesture underneath keeps
/// receiving the pointer.
public struct SidebarDragFeedbackOverlay: View {
    private let session: SidebarDragSession?
    private let remoteHover: SidebarDragSession.Hover?

    /// Creates the overlay for a session (`nil` draws nothing).
    ///
    /// - Parameters:
    ///   - session: The drag started in this sidebar, if any.
    ///   - remoteHover: The target a drag from another window would land on
    ///     here (highlight only; the source is drawn in its own window).
    public init(session: SidebarDragSession?, remoteHover: SidebarDragSession.Hover? = nil) {
        self.session = session
        self.remoteHover = remoteHover
    }

    public var body: some View {
        GeometryReader { proxy in
            if session != nil || remoteHover != nil {
                let origin = proxy.frame(in: .global).origin
                ZStack(alignment: .topLeading) {
                    if let session {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: session.sourceFrame.width, height: session.sourceFrame.height)
                            .offset(x: session.sourceFrame.minX - origin.x, y: session.sourceFrame.minY - origin.y)
                    }
                    if let hover = session?.hover ?? remoteHover {
                        let rect = hover.highlightFrame
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.3))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            )
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX - origin.x, y: rect.minY - origin.y)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
    }
}
