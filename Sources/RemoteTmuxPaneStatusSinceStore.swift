import Foundation

/// Remembers when each mirrored tmux pane's Claude turn state began, so a
/// reconnect or app relaunch that sees a pane's title again restores the real
/// timestamp instead of leaving it unknown.
///
/// Keyed by host and tmux pane id (`%N` is unique across a tmux server). An
/// entry is restored only when the pane still shows the same turn state and
/// topic, so a reused pane id or a turn that ran while cmux was away is never
/// credited with the old timestamp's state.
@MainActor
final class RemoteTmuxPaneStatusSinceStore {
    struct Entry: Codable, Equatable {
        let status: String
        let topic: String
        let since: TimeInterval
    }

    /// The app's persistent store. Test runs get a memory-only store per
    /// connection instead (see ``forNewConnection()``).
    static let shared = RemoteTmuxPaneStatusSinceStore(defaults: .standard)

    static let defaultsKey = "remoteTmux.paneStatusSince.v1"
    /// Entries older than this are dropped; the prompt cache they would time
    /// is 1 h, so a longer-gone timestamp reads the same as an unknown one.
    static let retention: TimeInterval = 6 * 3600
    static let maxEntries = 256

    private let defaults: UserDefaults?
    private var entries: [String: Entry]

    /// - Parameter defaults: Where entries persist; `nil` keeps them in memory.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// The store a new connection uses: ``shared`` in the app, a fresh
    /// memory-only one under XCTest so tests never see each other's panes.
    static func forNewConnection() -> RemoteTmuxPaneStatusSinceStore {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return RemoteTmuxPaneStatusSinceStore(defaults: nil)
        }
        return shared
    }

    /// The remembered start of `title`'s turn state on this pane, when the
    /// pane last showed the same state and topic.
    func since(hostId: String, paneId: Int, title: RemoteTmuxPaneTerminalTitle, now: Date) -> Date? {
        guard let status = title.glyphStatus,
              let entry = entries[Self.key(hostId: hostId, paneId: paneId)],
              entry.status == status.rawValue,
              entry.topic == title.topic,
              entry.since <= now.timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: entry.since)
    }

    /// Records `title`'s known turn-state start for this pane. A title with no
    /// turn state or an unknown start leaves the entry alone.
    func record(hostId: String, paneId: Int, title: RemoteTmuxPaneTerminalTitle, now: Date) {
        guard let status = title.glyphStatus, let since = title.glyphStatusSince else { return }
        let entry = Entry(status: status.rawValue, topic: title.topic, since: since.timeIntervalSince1970)
        let key = Self.key(hostId: hostId, paneId: paneId)
        guard entries[key] != entry else { return }
        entries[key] = entry
        prune(now: now)
        persist()
    }

    private func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 - Self.retention
        entries = entries.filter { $0.value.since >= cutoff }
        guard entries.count > Self.maxEntries else { return }
        let keep = entries.sorted { $0.value.since > $1.value.since }.prefix(Self.maxEntries)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func key(hostId: String, paneId: Int) -> String {
        "\(hostId)|%\(paneId)"
    }
}
