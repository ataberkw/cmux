import AppKit
import Bonsplit
import CmuxAgentChat
import CmuxRemoteSession
import CmuxSidebar
import CmuxSwiftRender
import Foundation

extension Workspace {
    /// Projects live workspace state into the custom-sidebar interpreter input snapshot.
    func customSidebarWorkspaceSnapshot(
        index: Int,
        selectedId: UUID?,
        unreadCount: Int
    ) -> CustomSidebarWorkspaceSnapshot {
        CacheExpiryWarningCenter.shared.ensureStarted()
        let focusedPanelId = focusedPanelId
        let firstBranch = sidebarGitBranchesInDisplayOrder().first
        let progress = self.progress.map {
            CustomSidebarWorkspaceSnapshot.Progress(value: $0.value, label: $0.label)
        }
        let remote = remoteDisplayTarget.map { target in
            CustomSidebarWorkspaceSnapshot.Remote(
                target: target,
                stateRawValue: remoteConnectionState.rawValue,
                isConnected: remoteConnectionState == .connected
            )
        }
        // Pane geometry from the same Bonsplit layout snapshot the socket
        // `pane.list` command reads, keyed by pane id (uuidString) so each
        // surface can carry its split cell's pixel frame.
        let layout = bonsplitController.layoutSnapshot()
        let containerFrame = CustomSidebarWorkspaceSnapshot.ContainerSize(
            x: layout.containerFrame.x,
            y: layout.containerFrame.y,
            width: layout.containerFrame.width,
            height: layout.containerFrame.height
        )
        let frameByPaneId = Dictionary(
            layout.panes.map { pane in
                (
                    pane.paneId,
                    CustomSidebarSurfaceSnapshot.Frame(
                        x: pane.frame.x,
                        y: pane.frame.y,
                        width: pane.frame.width,
                        height: pane.frame.height
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Agent session state + kind per surface (idle/working/needs_input/ended;
        // claude/cursor/codex/…), so the split tree can carry each pane's live
        // agent status and which agent it is (the sidebar colors idle by kind).
        let agentSnapshots = customSidebarAgentSnapshots()
        let statusBySurfaceId = Dictionary(
            agentSnapshots.compactMap { agent -> (String, String)? in
                guard let surfaceId = agent.surfaceId else { return nil }
                return (surfaceId.uuidString, agent.status)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let kindBySurfaceId = Dictionary(
            agentSnapshots.compactMap { agent -> (String, String)? in
                guard let surfaceId = agent.surfaceId else { return nil }
                return (surfaceId.uuidString, agent.kind)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Last agent turn per surface (epoch seconds), so a sidebar can draw the
        // rolling prompt-cache countdown (cache stays warm ~1h from the last turn).
        let lastActivityBySurfaceId = Dictionary(
            agentSnapshots.compactMap { agent -> (String, Int)? in
                guard let surfaceId = agent.surfaceId else { return nil }
                return (surfaceId.uuidString, Int(agent.lastActivityAt.timeIntervalSince1970))
            },
            uniquingKeysWith: { first, _ in first }
        )
        // The same layout as a recursive split tree, projected straight to
        // interpreter values so a sidebar can draw the schema with nested
        // stacks (no pixel math). Empty layouts collapse to `nil`.
        let layoutTree = Self.customSidebarLayoutTreeValue(
            bonsplitController.treeSnapshot(),
            focusedPaneId: layout.focusedPaneId,
            statusBySurfaceId: statusBySurfaceId,
            kindBySurfaceId: kindBySurfaceId,
            lastActivityBySurfaceId: lastActivityBySurfaceId,
            panelIdForSurfaceId: { raw in
                UUID(uuidString: raw).flatMap { self.panelIdFromSurfaceId(TabID(uuid: $0)) }?.uuidString
            },
            nestedTreeForPanelId: { raw, containerFocused in
                UUID(uuidString: raw).flatMap {
                    self.customSidebarRemoteTmuxLayoutTreeValue(
                        containerPanelId: $0,
                        containerFocused: containerFocused
                    )
                }
            }
        )
        // Portable per-folder identities (name + emoji/image from
        // `<dir>/.cmux/profile.json`, folder-basename fallback), merged when
        // two of the workspace's folders resolve to the same identity.
        let folderIdentities = customSidebarFolderIdentityValues()
        return CustomSidebarWorkspaceSnapshot(
            id: id,
            title: customTitle ?? title,
            isSelected: id == selectedId,
            isPinned: isPinned,
            index: index,
            directory: presentedCurrentDirectory ?? "",
            listeningPorts: listeningPorts,
            unreadCount: unreadCount,
            surfaces: customSidebarSurfaceSnapshots(
                focusedPanelId: focusedPanelId,
                frameByPaneId: frameByPaneId
            ),
            surfaceCount: bonsplitController.allPaneIds.reduce(0) {
                $0 + bonsplitController.tabs(inPane: $1).count
            },
            customDescription: customDescription,
            customColor: customColor,
            gitBranch: firstBranch?.branch,
            gitIsDirty: firstBranch?.isDirty ?? false,
            pullRequestValues: customSidebarPullRequestValues(),
            progress: progress,
            latestConversationMessage: latestConversationMessage,
            latestSubmittedMessage: latestSubmittedMessage,
            latestSubmittedAt: latestSubmittedAt,
            remote: remote,
            agents: agentSnapshots,
            groupId: groupId,
            containerFrame: containerFrame,
            layoutTree: layoutTree,
            folderIdentities: folderIdentities
        )
    }

    /// At most this many agent sessions are projected per workspace; the
    /// registry returns most-recent-first, so the cap drops the oldest.
    private static let customSidebarAgentLimit = 24

    /// Projects the agent-chat session registry's records hosted by this
    /// workspace's terminals into `workspaces[i].agents` snapshots.
    ///
    /// A record binds to this workspace when its hook-resolved surface id is
    /// one of this workspace's live terminal panels. Records without a
    /// surface binding fall back to their stored workspace id; records bound
    /// to a panel that lives elsewhere (or was closed) are excluded even when
    /// their stored workspace id matches, because that stored id goes stale
    /// across relaunches while the panel binding stays authoritative.
    private func customSidebarAgentSnapshots() -> [CustomSidebarAgentSnapshot] {
        guard let service = TerminalController.shared.agentChatTranscriptService else { return [] }
        let records = service.sessionRecords(workspaceID: nil)
        guard !records.isEmpty else { return [] }
        var surfaceIdByPanelId: [UUID: UUID] = [:]
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id) else { continue }
                surfaceIdByPanelId[panelId] = tab.id.uuid
            }
        }
        let workspaceIdString = id.uuidString
        var agents: [CustomSidebarAgentSnapshot] = []
        for record in records {
            let panelId = record.surfaceID.flatMap(UUID.init(uuidString:))
            if let panelId {
                guard surfaceIdByPanelId[panelId] != nil else { continue }
            } else {
                guard record.workspaceID == workspaceIdString else { continue }
            }
            let status: String
            let stateSince: Date?
            switch record.state {
            case .idle:
                status = "idle"
                stateSince = nil
            case .working(let since):
                status = "working"
                stateSince = since
            case .needsInput(let since):
                status = "needs_input"
                stateSince = since
            case .ended:
                status = "ended"
                stateSince = nil
            }
            agents.append(
                CustomSidebarAgentSnapshot(
                    sessionId: record.sessionID,
                    kind: record.agentKind.sourceName,
                    name: record.agentKind.displayName,
                    status: status,
                    stateSince: stateSince,
                    lastActivityAt: record.lastActivityAt,
                    title: record.title,
                    panelId: panelId,
                    surfaceId: panelId.flatMap { surfaceIdByPanelId[$0] },
                    workingDirectory: record.workingDirectory,
                    transcriptPath: record.transcriptPath,
                    pid: record.pid,
                    children: record.children.map { child in
                        CustomSidebarAgentChildSnapshot(
                            id: child.id,
                            label: child.label,
                            isRunning: child.isRunning,
                            startedAt: child.startedAt,
                            endedAt: child.endedAt
                        )
                    }
                )
            )
            if agents.count >= Self.customSidebarAgentLimit { break }
        }
        return agents
    }

    private func customSidebarSurfaceSnapshots(
        focusedPanelId: UUID?,
        frameByPaneId: [String: CustomSidebarSurfaceSnapshot.Frame]
    ) -> [CustomSidebarSurfaceSnapshot] {
        var surfaces: [CustomSidebarSurfaceSnapshot] = []
        for paneId in bonsplitController.allPaneIds {
            // Every tab in a pane shares that pane's split-cell frame.
            let frame = frameByPaneId[paneId.id.uuidString]
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id) else { continue }
                let git = reportedPanelGitBranch(panelId: panelId)
                surfaces.append(
                    CustomSidebarSurfaceSnapshot(
                        panelId: panelId,
                        surfaceId: tab.id.uuid,
                        title: tab.title,
                        isFocused: panelId == focusedPanelId,
                        isPinned: pinnedPanelIds.contains(panelId),
                        directory: reportedPanelDirectory(panelId: panelId),
                        gitBranch: git?.branch,
                        gitIsDirty: git?.isDirty ?? false,
                        listeningPorts: surfaceListeningPorts[panelId] ?? [],
                        frame: frame
                    )
                )
            }
        }
        return surfaces
    }

    /// Projects a Bonsplit ``ExternalTreeNode`` into the recursive interpreter
    /// value a sidebar draws the split schema from. A split becomes
    /// `{kind:"split", orientation, ratio, first, second}` and a pane leaf
    /// `{kind:"pane", paneId, focused, surfaceId, panelId, title}`, where
    /// `surfaceId` is the pane's selected tab (what `surface.focus` accepts)
    /// and `panelId` the panel behind it (what `surface.move` moves; a sidebar
    /// drags it and drops it on a `paneId`).
    private static func customSidebarLayoutTreeValue(
        _ node: ExternalTreeNode,
        focusedPaneId: String?,
        statusBySurfaceId: [String: String],
        kindBySurfaceId: [String: String],
        lastActivityBySurfaceId: [String: Int],
        panelIdForSurfaceId: (String) -> String?,
        nestedTreeForPanelId: (String, Bool) -> SwiftValue?
    ) -> SwiftValue {
        switch node {
        case let .split(split):
            return .object([
                "kind": .string("split"),
                "orientation": .string(split.orientation),
                "ratio": .double(split.dividerPosition),
                "first": customSidebarLayoutTreeValue(
                    split.first, focusedPaneId: focusedPaneId,
                    statusBySurfaceId: statusBySurfaceId, kindBySurfaceId: kindBySurfaceId,
                    lastActivityBySurfaceId: lastActivityBySurfaceId,
                    panelIdForSurfaceId: panelIdForSurfaceId,
                    nestedTreeForPanelId: nestedTreeForPanelId),
                "second": customSidebarLayoutTreeValue(
                    split.second, focusedPaneId: focusedPaneId,
                    statusBySurfaceId: statusBySurfaceId, kindBySurfaceId: kindBySurfaceId,
                    lastActivityBySurfaceId: lastActivityBySurfaceId,
                    panelIdForSurfaceId: panelIdForSurfaceId,
                    nestedTreeForPanelId: nestedTreeForPanelId),
            ])
        case let .pane(pane):
            var fields: [String: SwiftValue] = [
                "kind": .string("pane"),
                "paneId": .string(pane.id),
                "focused": .bool(pane.id == focusedPaneId),
            ]
            let selectedTab =
                pane.selectedTabId.flatMap { sel in pane.tabs.first(where: { $0.id == sel }) }
                ?? pane.tabs.first
            if let selectedTab {
                fields["surfaceId"] = .string(selectedTab.id)
                if let panelId = panelIdForSurfaceId(selectedTab.id) {
                    // A mirrored tmux window renders its own pane tree inside
                    // this one cell; draw that tree instead of a single leaf.
                    if let nested = nestedTreeForPanelId(panelId, pane.id == focusedPaneId) {
                        return nested
                    }
                    fields["panelId"] = .string(panelId)
                }
                fields["title"] = .string(selectedTab.title)
                if let status = statusBySurfaceId[selectedTab.id] {
                    fields["status"] = .string(status)
                }
                if let agentKind = kindBySurfaceId[selectedTab.id] {
                    fields["agentKind"] = .string(agentKind)
                }
                if let lastActivityAt = lastActivityBySurfaceId[selectedTab.id] {
                    fields["lastActivityAt"] = .int(lastActivityAt)
                }
            }
            return .object(fields)
        }
    }

    /// Expands a mirrored tmux window's container cell into that window's own
    /// pane tree, so a sidebar draws the tmux split schema instead of one cell.
    /// Reads the BASE layout (every pane, even while one is zoomed) and marks
    /// the zoomed pane. Leaves carry `nested: true`: they live inside one cmux
    /// surface and cannot be moved between cmux panes, but `surfaceId` still
    /// focuses them through `surface.focus`.
    private func customSidebarRemoteTmuxLayoutTreeValue(
        containerPanelId: UUID,
        containerFocused: Bool
    ) -> SwiftValue? {
        guard let mirror = remoteTmuxWindowMirror(forPanelId: containerPanelId) else { return nil }
        let panes = Dictionary(
            remoteTmuxControlPanes(containerPanelID: containerPanelId).map {
                ($0.pane.tmuxPaneID, $0.pane)
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard !panes.isEmpty else { return nil }
        return Self.customSidebarRemoteTmuxNodeValue(
            mirror.layout,
            panes: panes,
            zoomedPaneId: mirror.zoomed ? mirror.visibleLayout?.paneIDsInOrder.first : nil,
            containerFocused: containerFocused
        )
    }

    private static func customSidebarRemoteTmuxNodeValue(
        _ node: RemoteTmuxLayoutNode,
        panes: [Int: RemoteTmuxControlPane],
        zoomedPaneId: Int?,
        containerFocused: Bool
    ) -> SwiftValue {
        switch node.content {
        case let .pane(tmuxPaneId):
            var fields: [String: SwiftValue] = [
                "kind": .string("pane"),
                "nested": .bool(true),
                "focused": .bool(containerFocused && panes[tmuxPaneId]?.isFocused == true),
            ]
            if tmuxPaneId == zoomedPaneId {
                fields["zoomed"] = .bool(true)
            }
            if let pane = panes[tmuxPaneId] {
                fields["paneId"] = .string(pane.paneID.id.uuidString)
                fields["surfaceId"] = .string(pane.panel.id.uuidString)
                fields["panelId"] = .string(pane.panel.id.uuidString)
                fields["title"] = .string(pane.title)
            }
            return .object(fields)
        case let .horizontal(children):
            return customSidebarRemoteTmuxSplitValue(
                children[...], horizontal: true,
                panes: panes, zoomedPaneId: zoomedPaneId, containerFocused: containerFocused
            )
        case let .vertical(children):
            return customSidebarRemoteTmuxSplitValue(
                children[...], horizontal: false,
                panes: panes, zoomedPaneId: zoomedPaneId, containerFocused: containerFocused
            )
        }
    }

    /// tmux splits are n-ary while the sidebar schema is binary, so
    /// `[a, b, c]` folds into `split(a, split(b, c))`, each ratio taken from
    /// the children's cell extents along the split axis.
    private static func customSidebarRemoteTmuxSplitValue(
        _ children: ArraySlice<RemoteTmuxLayoutNode>,
        horizontal: Bool,
        panes: [Int: RemoteTmuxControlPane],
        zoomedPaneId: Int?,
        containerFocused: Bool
    ) -> SwiftValue {
        let node: (RemoteTmuxLayoutNode) -> SwiftValue = {
            customSidebarRemoteTmuxNodeValue(
                $0, panes: panes, zoomedPaneId: zoomedPaneId, containerFocused: containerFocused
            )
        }
        guard let first = children.first else { return .object(["kind": .string("pane")]) }
        guard children.count > 1 else { return node(first) }
        let extent: (RemoteTmuxLayoutNode) -> Int = { horizontal ? $0.width : $0.height }
        let total = children.reduce(0) { $0 + extent($1) }
        return .object([
            "kind": .string("split"),
            "orientation": .string(horizontal ? "horizontal" : "vertical"),
            "ratio": .double(total > 0 ? Double(extent(first)) / Double(total) : 0.5),
            "first": node(first),
            "second": customSidebarRemoteTmuxSplitValue(
                children.dropFirst(), horizontal: horizontal,
                panes: panes, zoomedPaneId: zoomedPaneId, containerFocused: containerFocused
            ),
        ])
    }

    /// Resolves this workspace's distinct pane folders into portable identity
    /// values (`{dir, name, emoji?, image?}`), reading `<dir>/.cmux/profile.json`
    /// (folder-basename fallback) and merging folders that resolve to the same
    /// identity. Order follows first appearance across the panes.
    private func customSidebarFolderIdentityValues() -> [SwiftValue] {
        var seenDirs: Set<String> = []
        var orderedDirs: [String] = []
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let dir = reportedPanelDirectory(panelId: panelId), !dir.isEmpty
                else { continue }
                if seenDirs.insert(dir).inserted { orderedDirs.append(dir) }
            }
        }
        if orderedDirs.isEmpty, let workspaceDir = presentedCurrentDirectory, !workspaceDir.isEmpty {
            orderedDirs.append(workspaceDir)
        }
        var seenIdentities: Set<String> = []
        var values: [SwiftValue] = []
        for dir in orderedDirs {
            let identity = CmuxFolderProfileStore.identity(forDir: dir)
            let key = identity.name + "\u{1}" + (identity.emoji ?? "img:\(identity.imageBase64?.count ?? 0)")
            guard seenIdentities.insert(key).inserted else { continue }
            var fields: [String: SwiftValue] = [
                "dir": .string(identity.dir),
                "name": .string(identity.name),
            ]
            if let emoji = identity.emoji { fields["emoji"] = .string(emoji) }
            if let image = identity.imageBase64 { fields["image"] = .string(image) }
            values.append(.object(fields))
        }
        return values
    }
}

/// A per-folder identity profile stored as `<dir>/.cmux/profile.json`
/// (`{ "name": "…", "iconType": "emoji"|"image", "icon": "🎮" }`), with the
/// image variant's already-shrunk PNG beside it at `<dir>/.cmux/icon.png`.
/// This is the portable, project-tied workspace identity the Split Map sidebar
/// renders; it travels with the folder (git/dotfiles) instead of living only in
/// cmux app state.
private struct CmuxFolderProfileData: Decodable {
    var name: String?
    var iconType: String?
    var icon: String?
}

/// One folder's resolved identity: a display name (profile name, else the
/// folder basename) and an optional emoji or base64-PNG icon.
struct CmuxFolderIdentity {
    let dir: String
    let name: String
    let emoji: String?
    let imageBase64: String?
}

/// Reads and caches `.cmux/profile.json` / `.cmux/icon.png` identities by
/// modification time so the once-per-second sidebar snapshot never re-parses an
/// unchanged file.
@MainActor
enum CmuxFolderProfileStore {
    private struct CacheEntry {
        let profileMTime: Date?
        let imageMTime: Date?
        let identity: CmuxFolderIdentity
    }
    private static var cache: [String: CacheEntry] = [:]

    static func identity(forDir dir: String) -> CmuxFolderIdentity {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: dir)
        let profileURL = base.appendingPathComponent(".cmux/profile.json")
        let imageURL = base.appendingPathComponent(".cmux/icon.png")
        let profileMTime = (try? fm.attributesOfItem(atPath: profileURL.path))?[.modificationDate] as? Date
        let imageMTime = (try? fm.attributesOfItem(atPath: imageURL.path))?[.modificationDate] as? Date
        if let cached = cache[dir],
           cached.profileMTime == profileMTime,
           cached.imageMTime == imageMTime {
            return cached.identity
        }
        var name = base.lastPathComponent
        var emoji: String?
        var imageBase64: String?
        if let data = try? Data(contentsOf: profileURL),
           let profile = try? JSONDecoder().decode(CmuxFolderProfileData.self, from: data) {
            if let trimmed = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                name = trimmed
            }
            let iconType = profile.iconType ?? (profile.icon != nil ? "emoji" : nil)
            if iconType == "emoji", let icon = profile.icon, !icon.isEmpty {
                emoji = icon
            } else if iconType == "image", let imageData = try? Data(contentsOf: imageURL) {
                imageBase64 = imageData.base64EncodedString()
            }
        }
        let identity = CmuxFolderIdentity(dir: dir, name: name, emoji: emoji, imageBase64: imageBase64)
        cache[dir] = CacheEntry(profileMTime: profileMTime, imageMTime: imageMTime, identity: identity)
        return identity
    }

    // MARK: - Writes (invoked by the workspace.set_folder_* socket methods)

    /// Merges fields into `<dir>/.cmux/profile.json`. A non-nil `name` sets the
    /// display name; a non-nil `emoji` sets the emoji icon (and flips
    /// `iconType` to "emoji"). Returns true on success.
    @discardableResult
    static func setProfile(dir: String, name: String? = nil, emoji: String? = nil) -> Bool {
        var data = readRaw(dir: dir)
        if let name { data["name"] = name }
        if let emoji {
            data["icon"] = emoji
            data["iconType"] = "emoji"
        }
        return writeRaw(dir: dir, data)
    }

    /// Shrinks + compresses `image` to a small square PNG at `<dir>/.cmux/icon.png`
    /// and flips the profile to the image icon (clearing any emoji).
    @discardableResult
    static func setImage(dir: String, image: NSImage, maxSize: CGFloat = 64) -> Bool {
        guard let png = shrunkPNG(image, maxSize: maxSize) else { return false }
        let cmuxDir = URL(fileURLWithPath: dir).appendingPathComponent(".cmux")
        try? FileManager.default.createDirectory(at: cmuxDir, withIntermediateDirectories: true)
        do {
            try png.write(to: cmuxDir.appendingPathComponent("icon.png"))
        } catch {
            return false
        }
        var data = readRaw(dir: dir)
        data["iconType"] = "image"
        data.removeValue(forKey: "icon")
        return writeRaw(dir: dir, data)
    }

    /// Removes any icon (emoji or image) and deletes `icon.png`, leaving just
    /// the name (or the folder basename when none).
    @discardableResult
    static func clearIcon(dir: String) -> Bool {
        let cmuxDir = URL(fileURLWithPath: dir).appendingPathComponent(".cmux")
        try? FileManager.default.removeItem(at: cmuxDir.appendingPathComponent("icon.png"))
        var data = readRaw(dir: dir)
        data.removeValue(forKey: "icon")
        data.removeValue(forKey: "iconType")
        return writeRaw(dir: dir, data)
    }

    private static func readRaw(dir: String) -> [String: Any] {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".cmux/profile.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    @discardableResult
    private static func writeRaw(dir: String, _ data: [String: Any]) -> Bool {
        let cmuxDir = URL(fileURLWithPath: dir).appendingPathComponent(".cmux")
        try? FileManager.default.createDirectory(at: cmuxDir, withIntermediateDirectories: true)
        let url = cmuxDir.appendingPathComponent("profile.json")
        guard let out = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        do {
            try out.write(to: url)
            cache.removeValue(forKey: dir)
            return true
        } catch {
            return false
        }
    }

    /// Aspect-fits `image` (no upscaling past `maxSize`) centered on a
    /// transparent `maxSize`×`maxSize` canvas and encodes it as PNG.
    private static func shrunkPNG(_ image: NSImage, maxSize: CGFloat) -> Data? {
        let src = image.size
        guard src.width > 0, src.height > 0 else { return nil }
        let fit = min(maxSize / src.width, maxSize / src.height)
        let drawW = src.width * fit
        let drawH = src.height * fit
        let canvas = NSImage(size: NSSize(width: maxSize, height: maxSize))
        canvas.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: (maxSize - drawW) / 2, y: (maxSize - drawH) / 2, width: drawW, height: drawH),
            from: .zero, operation: .sourceOver, fraction: 1.0)
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }
}

/// Plays the user's notification sound once when an agent session's prompt
/// cache is ~10 min from its 1h idle expiry (50 min since the last turn), so a
/// session about to lose its warm cache gets an audible warning. Re-arms per
/// session on each new turn and skips ended sessions; the sound choice and
/// silence follow the app's notification-sound settings (Focus/DND-gated).
/// The 1h assumption matches Claude's extended cache; Cursor is treated the same.
@MainActor
final class CacheExpiryWarningCenter {
    static let shared = CacheExpiryWarningCenter()

    private var timer: Timer?
    private var warnedSessions: Set<String> = []
    private var lastActivityBySession: [String: TimeInterval] = [:]
    private let cacheTTL: TimeInterval = 3600
    private let warnAfterIdle: TimeInterval = 3000  // 50 min → 10 min before expiry

    /// Idempotent; safe to call from the once-per-second sidebar snapshot.
    func ensureStarted() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in CacheExpiryWarningCenter.shared.sweep() }
        }
    }

    private func sweep() {
        guard let service = TerminalController.shared.agentChatTranscriptService else { return }
        let records = service.sessionRecords(workspaceID: nil)
        let now = Date().timeIntervalSince1970
        var live: Set<String> = []
        for record in records {
            let sessionID = record.sessionID
            live.insert(sessionID)
            let lastActivity = record.lastActivityAt.timeIntervalSince1970
            if lastActivityBySession[sessionID] != lastActivity {
                lastActivityBySession[sessionID] = lastActivity
                warnedSessions.remove(sessionID)  // fresh turn → re-arm the warning
            }
            if case .ended = record.state { continue }
            let idle = now - lastActivity
            if idle >= warnAfterIdle, idle < cacheTTL, !warnedSessions.contains(sessionID) {
                warnedSessions.insert(sessionID)
                NotificationSoundSettings.playSelectedSound()
            }
        }
        warnedSessions.formIntersection(live)
        lastActivityBySession = lastActivityBySession.filter { live.contains($0.key) }
    }
}
