/// Where inside a drop target a dragged item was released.
///
/// The four edges map onto `surface.move`'s `split` directions (a new split on
/// that side of the target pane); ``center`` means "join the target" (no
/// split). Raw values are exactly the strings a sidebar's drop closure sees.
public enum DropZone: String, Codable, Sendable, CaseIterable {
    case center
    case left
    case right
    case up
    case down

    /// The fraction of a target's width/height, measured in from each edge,
    /// that counts as that edge's zone. The remaining middle is ``center``.
    public static let edgeFraction = 0.25

    /// Resolves the zone for a point inside a target rectangle.
    ///
    /// Coordinates are top-left-origin (y grows downward), so ``up`` is the
    /// band nearest `minY`. The nearest edge wins when the point lies in two
    /// edge bands (a corner). Points outside the rectangle clamp to it.
    ///
    /// - Parameters:
    ///   - x: The point's x offset from the target's left edge.
    ///   - y: The point's y offset from the target's top edge.
    ///   - width: The target's width.
    ///   - height: The target's height.
    /// - Returns: The zone the point falls in, or ``center`` for a degenerate
    ///   (zero-sized) target.
    public static func resolve(x: Double, y: Double, width: Double, height: Double) -> DropZone {
        guard width > 0, height > 0 else { return .center }
        let nx = min(max(x / width, 0), 1)
        let ny = min(max(y / height, 0), 1)
        let distances: [(DropZone, Double)] = [
            (.left, nx),
            (.right, 1 - nx),
            (.up, ny),
            (.down, 1 - ny),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < edgeFraction else {
            return .center
        }
        return nearest.0
    }
}
