import Foundation


/// Describes a drop target captured from `.dropDestination { payload, zone in … }`.
///
/// The closure's commands are recorded like a `Button` action, but the dropped
/// payload and zone are only known when the drop lands. The interpreter binds
/// the closure parameters to placeholder tokens, and the host substitutes the
/// real values with ``resolvedAction(payload:zone:)`` at drop time:
///
/// ```swift
/// RoundedRectangle(cornerRadius: 3)
///     .draggable(n.surfaceId)
///     .dropDestination { surface, zone in
///         cmux("surface.move", surface_id: surface, pane_id: n.paneId, split: zone)
///     }
/// ```
public struct DropSpec: Codable, Sendable, Equatable {
    /// Placeholder bound to the closure's first parameter (the dragged payload).
    public static let payloadToken = "\u{1}drop.payload\u{1}"
    /// Placeholder bound to the closure's second parameter (the ``DropZone``).
    public static let zoneToken = "\u{1}drop.zone\u{1}"

    /// The captured commands, with placeholders where the closure used its
    /// parameters.
    public let action: ButtonAction
    /// Whether the closure declared a zone parameter. Targets without one
    /// always receive ``DropZone/center`` and highlight as a whole.
    public let usesZones: Bool

    /// Creates a drop spec.
    ///
    /// - Parameters:
    ///   - action: Commands with ``payloadToken`` / ``zoneToken`` placeholders.
    ///   - usesZones: Whether edge zones are distinguished.
    public init(action: ButtonAction, usesZones: Bool) {
        self.action = action
        self.usesZones = usesZones
    }

    /// The action to run for a concrete drop, with every placeholder in
    /// command arguments replaced by `payload` and `zone`.
    public func resolvedAction(payload: String, zone: DropZone) -> ButtonAction {
        func fill(_ value: String) -> String {
            value
                .replacingOccurrences(of: Self.payloadToken, with: payload)
                .replacingOccurrences(of: Self.zoneToken, with: zone.rawValue)
        }
        return ButtonAction(commands: action.commands.map { command in
            switch command {
            case let .cmux(method, params):
                return .cmux(method: fill(method), params: params.mapValues(fill))
            case let .log(message):
                return .log(fill(message))
            case let .openURL(url):
                return .openURL(fill(url))
            }
        })
    }
}
