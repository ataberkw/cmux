import AppKit
import CmuxSwiftRender

/// Hands a sidebar drag that leaves its own sidebar to the custom sidebar of
/// whichever window is under the pointer, so a `.draggable` source in one
/// window can land on a `.dropDestination` in another.
///
/// Each in-process sidebar registers a ``SidebarDragRegionStore`` (its regions,
/// root frame, AppKit anchor, dispatch, and remote-hover sink). The source
/// sidebar keeps driving its own drag gesture (AppKit keeps delivering a drag
/// to the view it started in, even outside its window) and asks the router to
/// resolve the screen point against the other sidebars: the frontmost of this
/// app's windows under the point wins, skipping click-through overlays.
@MainActor
final class SidebarCrossWindowDropRouter {
    static let shared = SidebarCrossWindowDropRouter()

    /// The hovered sidebar in another window and its target there.
    struct Resolution {
        let store: SidebarDragRegionStore
        let hover: SidebarDragSession.Hover
    }

    private var stores: [ObjectIdentifier: WeakStore] = [:]
    /// The other-window sidebar currently drawing a hover for the live drag.
    private weak var hoveredStore: SidebarDragRegionStore?
    private var lastHover: SidebarDragSession.Hover?

    /// This app's windows under a screen point, front to back, without
    /// hidden or click-through (overlay) windows. Injectable for tests.
    var windowsAtScreenPoint: (CGPoint) -> [NSWindow] = { point in
        NSApp.orderedWindows.filter { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point) }
    }

    func register(_ store: SidebarDragRegionStore) {
        stores[ObjectIdentifier(store)] = WeakStore(store)
    }

    func unregister(_ store: SidebarDragRegionStore) {
        stores[ObjectIdentifier(store)] = nil
        if hoveredStore === store {
            hoveredStore = nil
            lastHover = nil
        }
    }

    /// The target a `kind` payload from `source` would land on at
    /// `screenPoint`, in a sidebar other than `source`'s.
    func resolve(screenPoint: CGPoint, kind: String?, from source: SidebarDragRegionStore) -> Resolution? {
        // Only the frontmost window under the pointer can take the drop: a
        // window behind it is covered there.
        guard let window = windowsAtScreenPoint(screenPoint).first else { return nil }
        for entry in stores.values {
            guard let store = entry.store, store !== source,
                  let globalPoint = store.globalPoint(forScreenPoint: screenPoint, in: window),
                  let hover = SidebarDragSession.resolveHover(
                      at: globalPoint, regions: store.regions, kind: kind, sourceFrame: nil
                  ) else { continue }
            return Resolution(store: store, hover: hover)
        }
        return nil
    }

    /// Updates the other-window hover feedback for a drag at `screenPoint`
    /// (`nil` clears it), redrawing only the sidebars whose hover changed.
    func updateHover(screenPoint: CGPoint?, kind: String?, from source: SidebarDragRegionStore) {
        let resolution = screenPoint.flatMap { resolve(screenPoint: $0, kind: kind, from: source) }
        if hoveredStore !== resolution?.store {
            hoveredStore?.onRemoteHover?(nil)
            hoveredStore = resolution?.store
            lastHover = nil
        }
        guard let resolution, lastHover != resolution.hover else { return }
        lastHover = resolution.hover
        resolution.store.onRemoteHover?(resolution.hover)
    }

    /// Runs the drop of `payload` on the other-window target at `screenPoint`.
    /// - Returns: Whether a target accepted it.
    @discardableResult
    func drop(payload: String, kind: String?, screenPoint: CGPoint, from source: SidebarDragRegionStore) -> Bool {
        updateHover(screenPoint: nil, kind: kind, from: source)
        guard let resolution = resolve(screenPoint: screenPoint, kind: kind, from: source),
              let dispatch = resolution.store.dispatch else { return false }
        dispatch.run(resolution.hover.spec.resolvedAction(payload: payload, zone: resolution.hover.zone))
        return true
    }

    private struct WeakStore {
        weak var store: SidebarDragRegionStore?
        init(_ store: SidebarDragRegionStore) { self.store = store }
    }
}

/// Non-observed holder for one sidebar's drag geometry and its cross-window
/// endpoints. Written from preference/geometry callbacks, read only by the
/// gesture and the router, so it never invalidates the view.
@MainActor
final class SidebarDragRegionStore {
    /// Latest reported regions, in the `.global` space.
    var regions: [SidebarDragRegion] = []
    /// The sidebar root's frame in the `.global` space.
    var rootGlobalFrame: CGRect = .zero
    /// Every live anchor view SwiftUI made for this sidebar. SwiftUI can
    /// mount a replacement before removing the old one, so the store keeps
    /// them all (weakly) instead of trusting whichever was made last.
    private let anchors = NSHashTable<NSView>.weakObjects()

    /// The anchor that is in a window right now: a flipped AppKit view
    /// covering the sidebar root, for screen conversion.
    var anchor: NSView? {
        anchors.allObjects.first { $0.window != nil } ?? anchors.allObjects.first
    }

    /// Records an anchor view SwiftUI mounted for this sidebar.
    func addAnchor(_ view: NSView) {
        anchors.add(view)
    }
    /// Runs a drop that lands here from another window.
    var dispatch: SidebarActionDispatch?
    /// Draws (or clears) a hover from a drag that started in another window.
    var onRemoteHover: ((SidebarDragSession.Hover?) -> Void)?

    /// `screenPoint` in this sidebar's `.global` space when it falls inside
    /// this sidebar's root and the sidebar is in `window`; `nil` otherwise.
    func globalPoint(forScreenPoint screenPoint: CGPoint, in window: NSWindow) -> CGPoint? {
        guard let anchor = anchors.allObjects.first(where: { $0.window === window }) else { return nil }
        let local = anchor.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard anchor.bounds.contains(local) else { return nil }
        return CGPoint(x: rootGlobalFrame.minX + local.x, y: rootGlobalFrame.minY + local.y)
    }
}

/// A transparent, flipped view that records itself as its sidebar's anchor.
final class SidebarDragAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
