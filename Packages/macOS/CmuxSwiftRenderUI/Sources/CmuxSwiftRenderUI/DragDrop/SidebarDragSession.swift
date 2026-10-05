import CmuxSwiftRender
import CoreGraphics

/// The pure state of one in-flight sidebar drag: what is being dragged, where
/// the pointer is, and which drop target (and zone) it would land on.
///
/// Both render lanes drive the same session, so hit-testing, zone resolution,
/// and the command a drop runs can't drift between them. All points and
/// frames are in the root coordinate space (top-left origin).
///
/// ```swift
/// guard var session = SidebarDragSession(pressedAt: start, regions: regions) else { return }
/// session.move(to: point, regions: regions)
/// if let action = session.dropAction { dispatch.run(action) }
/// ```
public struct SidebarDragSession: Equatable, Sendable {
    /// The drop target under the pointer.
    public struct Hover: Equatable, Sendable {
        /// The target region's full frame.
        public let targetFrame: CGRect
        /// The zone the pointer is in.
        public let zone: DropZone
        /// The part of the target the drop would occupy (a half for an edge
        /// zone, the whole target for ``DropZone/center``), for feedback.
        public let highlightFrame: CGRect
        /// The target's drop spec.
        public let spec: DropSpec
    }

    /// The minimum pointer travel, in points, before a press becomes a drag,
    /// so a click on a draggable view still reads as a tap.
    public static let activationDistance: CGFloat = 5

    /// The dragged payload.
    public let payload: String
    /// The payload's kind; only targets accepting it resolve as a hover.
    public let kind: String?
    /// The frame of the source region the drag started from.
    public let sourceFrame: CGRect
    /// The pointer's current location.
    public private(set) var location: CGPoint
    /// The target under the pointer, if any accepts this drop.
    public private(set) var hover: Hover?

    /// Starts a drag from the innermost source region containing `point`.
    ///
    /// - Parameters:
    ///   - point: Where the press began.
    ///   - regions: The rendered tree's current drag regions.
    /// - Returns: `nil` when no source region contains `point`.
    public init?(pressedAt point: CGPoint, regions: [SidebarDragRegion]) {
        let sources = regions.compactMap { region -> (CGRect, String, String?)? in
            guard case let .source(payload, kind) = region.role, region.frame.contains(point) else { return nil }
            return (region.frame, payload, kind)
        }
        guard let source = sources.min(by: { Self.area($0.0) < Self.area($1.0) }) else { return nil }
        self.payload = source.1
        self.kind = DropSpec.normalizedKind(source.2)
        self.sourceFrame = source.0
        self.location = point
        self.hover = nil
    }

    /// Whether the pointer has moved far enough from `start` to begin a drag.
    public static func hasActivated(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= activationDistance
    }

    /// Moves the pointer and re-resolves the hovered target.
    ///
    /// The innermost target containing the point wins. Anywhere over the
    /// drag's own source is no target at all (not even an enclosing one), so
    /// dropping a pane back on itself is a no-op.
    ///
    /// - Returns: Whether ``hover`` changed. Feedback draws only the source
    ///   and the hovered target/zone, so a move that returns `false` needs no
    ///   redraw; both render lanes gate republishing on it.
    @discardableResult
    public mutating func move(to point: CGPoint, regions: [SidebarDragRegion]) -> Bool {
        location = point
        let previous = hover
        hover = Self.resolveHover(at: point, regions: regions, kind: kind, sourceFrame: sourceFrame)
        return hover != previous
    }

    /// The innermost target at `point` accepting a `kind` payload. A drop
    /// handed over from another window passes no `sourceFrame`.
    ///
    /// A typed target that encloses the drag's own source is skipped: it is
    /// the source's own container (a workspace header inside a window-wide
    /// "move workspace here" target), so dropping there would be a no-op.
    static func resolveHover(
        at point: CGPoint,
        regions: [SidebarDragRegion],
        kind: String?,
        sourceFrame: CGRect?
    ) -> Hover? {
        if let sourceFrame, sourceFrame.contains(point) { return nil }
        let targets = regions.compactMap { region -> (CGRect, DropSpec)? in
            guard case let .target(spec) = region.role,
                  spec.accepts(payloadKind: kind),
                  region.frame.contains(point),
                  region.frame != sourceFrame else { return nil }
            if spec.kind != nil, let sourceFrame, region.frame.contains(sourceFrame) { return nil }
            return (region.frame, spec)
        }
        guard let (frame, spec) = targets.min(by: { Self.area($0.0) < Self.area($1.0) }) else {
            return nil
        }
        let zone = spec.usesZones
            ? DropZone.resolve(
                x: Double(point.x - frame.minX),
                y: Double(point.y - frame.minY),
                width: Double(frame.width),
                height: Double(frame.height)
            )
            : .center
        return Hover(
            targetFrame: frame,
            zone: zone,
            highlightFrame: Self.highlightFrame(for: zone, in: frame),
            spec: spec
        )
    }

    /// The command a release at the current location runs, or `nil` when the
    /// pointer is not over an accepting target.
    public var dropAction: ButtonAction? {
        hover.map { $0.spec.resolvedAction(payload: payload, zone: $0.zone) }
    }

    /// The half (or whole) of `frame` a drop in `zone` would occupy.
    static func highlightFrame(for zone: DropZone, in frame: CGRect) -> CGRect {
        switch zone {
        case .center:
            return frame
        case .left:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:
            return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .up:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .down:
            return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}
