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
        // One Bonsplit tree walk feeds both the pane geometry and the split
        // tree. Pane frames use the same math as `layoutSnapshot()` (what the
        // socket `pane.list` reads), keyed by pane id (uuidString) so each
        // surface can carry its split cell's pixel frame.
        let tree = bonsplitController.treeSnapshot()
        let geometry = Self.customSidebarPaneGeometry(tree)
        // Agent fields per surface: state (idle/working/needs_input/ended),
        // kind (claude/cursor/codex/…, the sidebar colors idle by kind), and
        // the last turn in epoch seconds (the rolling prompt-cache countdown).
        let agentSnapshots = customSidebarAgentSnapshots()
        let agentFieldsBySurfaceId = Self.customSidebarAgentFieldsBySurfaceId(agentSnapshots)
        // The same layout as a recursive split tree, projected straight to
        // interpreter values so a sidebar can draw the schema with nested
        // stacks (no pixel math). Empty layouts collapse to `nil`.
        let layoutTree = Self.customSidebarLayoutTreeValue(
            tree,
            focusedPaneId: bonsplitController.focusedPaneId?.id.uuidString,
            agentFieldsBySurfaceId: agentFieldsBySurfaceId,
            panelIdForSurfaceId: { raw in
                UUID(uuidString: raw).flatMap { self.panelIdFromSurfaceId(TabID(uuid: $0)) }?.uuidString
            },
            nestedTreeForPanelId: { raw, containerFocused in
                UUID(uuidString: raw).flatMap {
                    self.customSidebarRemoteTmuxLayoutTreeValue(
                        containerPanelId: $0,
                        containerFocused: containerFocused,
                        agentFieldsBySurfaceId: agentFieldsBySurfaceId
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
                frameByPaneId: geometry.frameByPaneId
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
            containerFrame: geometry.containerFrame,
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
        let records = TerminalController.shared.agentChatTranscriptService?
            .sessionRecords(workspaceID: nil) ?? []
        var surfaceIdByPanelId: [UUID: UUID] = [:]
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id) else { continue }
                surfaceIdByPanelId[panelId] = tab.id.uuid
            }
        }
        // A mirrored tmux window's panes are panels nested inside its one
        // container tab, each addressed by its own panel id (the layout
        // tree's `surfaceId` for that pane).
        for mirror in remoteTmuxWindowMirrors.values {
            for panel in mirror.panelsByPaneId.values {
                surfaceIdByPanelId[panel.id] = panel.id
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
        appendCustomSidebarRemoteTmuxTitleAgents(to: &agents)
        return agents
    }

    /// Adds a Claude agent for each mirrored tmux pane whose terminal title
    /// carries Claude's turn glyph and that no hook-backed record already
    /// covers. Remote tmux panes have no cmux hooks (the ssh-tmux transport
    /// has no socket relay), so the title is their only turn signal.
    private func appendCustomSidebarRemoteTmuxTitleAgents(
        to agents: inout [CustomSidebarAgentSnapshot]
    ) {
        guard !remoteTmuxWindowMirrors.isEmpty else { return }
        let boundSurfaceIds = Set(agents.compactMap(\.surfaceId))
        let now = Date()
        for mirror in remoteTmuxWindowMirrors.values {
            for (tmuxPaneId, panel) in mirror.panelsByPaneId.sorted(by: { $0.key < $1.key }) {
                guard agents.count < Self.customSidebarAgentLimit else { return }
                guard !boundSurfaceIds.contains(panel.id),
                      let agent = mirror.agentStatus(forPane: tmuxPaneId) else { continue }
                let isWorking = agent.status == .working
                agents.append(
                    CustomSidebarAgentSnapshot(
                        sessionId: "tmux-title-\(panel.id.uuidString)",
                        kind: ChatAgentKind.claude.sourceName,
                        name: ChatAgentKind.claude.displayName,
                        status: agent.status.rawValue,
                        stateSince: isWorking ? agent.since : nil,
                        lastActivityAt: isWorking ? now : agent.since,
                        title: mirror.paneTerminalTitles[tmuxPaneId]?.topic,
                        panelId: panel.id,
                        surfaceId: panel.id,
                        workingDirectory: mirror.cwdByPaneId[tmuxPaneId],
                        transcriptPath: nil,
                        pid: nil,
                        children: []
                    )
                )
            }
        }
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
        agentFieldsBySurfaceId: [String: [String: SwiftValue]],
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
                    agentFieldsBySurfaceId: agentFieldsBySurfaceId,
                    panelIdForSurfaceId: panelIdForSurfaceId,
                    nestedTreeForPanelId: nestedTreeForPanelId),
                "second": customSidebarLayoutTreeValue(
                    split.second, focusedPaneId: focusedPaneId,
                    agentFieldsBySurfaceId: agentFieldsBySurfaceId,
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
                if let agentFields = agentFieldsBySurfaceId[selectedTab.id] {
                    fields.merge(agentFields, uniquingKeysWith: { _, agent in agent })
                }
            }
            return .object(fields)
        }
    }

    /// Pane-leaf agent fields (`status`, `agentKind`, `lastActivityAt`) per
    /// surface id, built in one pass. The first (most recent) agent bound to a
    /// surface wins.
    private static func customSidebarAgentFieldsBySurfaceId(
        _ agents: [CustomSidebarAgentSnapshot]
    ) -> [String: [String: SwiftValue]] {
        var fieldsBySurfaceId: [String: [String: SwiftValue]] = [:]
        for agent in agents {
            guard let surfaceId = agent.surfaceId?.uuidString,
                  fieldsBySurfaceId[surfaceId] == nil else { continue }
            fieldsBySurfaceId[surfaceId] = [
                "status": .string(agent.status),
                "agentKind": .string(agent.kind),
                "lastActivityAt": .int(Int(agent.lastActivityAt.timeIntervalSince1970)),
            ]
        }
        return fieldsBySurfaceId
    }

    /// The dock container frame and each pane's pixel frame (keyed by pane id
    /// uuidString), read off one ``ExternalTreeNode`` walk. Pane cells tile
    /// the container exactly, so the container is the union of the leaves.
    static func customSidebarPaneGeometry(_ tree: ExternalTreeNode) -> (
        containerFrame: CustomSidebarWorkspaceSnapshot.ContainerSize,
        frameByPaneId: [String: CustomSidebarSurfaceSnapshot.Frame]
    ) {
        var frameByPaneId: [String: CustomSidebarSurfaceSnapshot.Frame] = [:]
        var container: CGRect?
        func visit(_ node: ExternalTreeNode) {
            switch node {
            case let .split(split):
                visit(split.first)
                visit(split.second)
            case let .pane(pane):
                let frame = pane.frame
                if frameByPaneId[pane.id] == nil {
                    frameByPaneId[pane.id] = CustomSidebarSurfaceSnapshot.Frame(
                        x: frame.x, y: frame.y, width: frame.width, height: frame.height
                    )
                }
                let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
                container = container.map { $0.union(rect) } ?? rect
            }
        }
        visit(tree)
        let bounds = container ?? .zero
        return (
            CustomSidebarWorkspaceSnapshot.ContainerSize(
                x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height
            ),
            frameByPaneId
        )
    }

    /// Expands a mirrored tmux window's container cell into that window's own
    /// pane tree, so a sidebar draws the tmux split schema instead of one cell.
    /// Reads the BASE layout (every pane, even while one is zoomed) and marks
    /// the zoomed pane. Leaves carry `nested: true`: they live inside one cmux
    /// surface and cannot be moved between cmux panes, but `surfaceId` still
    /// focuses them through `surface.focus`.
    private func customSidebarRemoteTmuxLayoutTreeValue(
        containerPanelId: UUID,
        containerFocused: Bool,
        agentFieldsBySurfaceId: [String: [String: SwiftValue]]
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
            containerFocused: containerFocused,
            agentFieldsBySurfaceId: agentFieldsBySurfaceId
        )
    }

    private static func customSidebarRemoteTmuxNodeValue(
        _ node: RemoteTmuxLayoutNode,
        panes: [Int: RemoteTmuxControlPane],
        zoomedPaneId: Int?,
        containerFocused: Bool,
        agentFieldsBySurfaceId: [String: [String: SwiftValue]]
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
                if let agentFields = agentFieldsBySurfaceId[pane.panel.id.uuidString] {
                    fields.merge(agentFields, uniquingKeysWith: { _, agent in agent })
                }
            }
            return .object(fields)
        case let .horizontal(children):
            return customSidebarRemoteTmuxSplitValue(
                children[...], horizontal: true,
                panes: panes, zoomedPaneId: zoomedPaneId, containerFocused: containerFocused,
                agentFieldsBySurfaceId: agentFieldsBySurfaceId
            )
        case let .vertical(children):
            return customSidebarRemoteTmuxSplitValue(
                children[...], horizontal: false,
                panes: panes, zoomedPaneId: zoomedPaneId, containerFocused: containerFocused,
                agentFieldsBySurfaceId: agentFieldsBySurfaceId
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
        containerFocused: Bool,
        agentFieldsBySurfaceId: [String: [String: SwiftValue]]
    ) -> SwiftValue {
        let node: (RemoteTmuxLayoutNode) -> SwiftValue = {
            customSidebarRemoteTmuxNodeValue(
                $0, panes: panes, zoomedPaneId: zoomedPaneId, containerFocused: containerFocused,
                agentFieldsBySurfaceId: agentFieldsBySurfaceId
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
                panes: panes, zoomedPaneId: zoomedPaneId, containerFocused: containerFocused,
                agentFieldsBySurfaceId: agentFieldsBySurfaceId
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
        // A remote workspace's directories name paths on the remote host, so
        // reading `.cmux/profile.json` here would only stat local paths that
        // don't exist (or worse, unrelated local ones).
        let readsLocalProfiles = !isRemoteWorkspace && !isRemoteTmuxMirror
        var seenIdentities: Set<String> = []
        var values: [SwiftValue] = []
        for dir in orderedDirs {
            let identity = readsLocalProfiles
                ? CmuxFolderProfileStore.identity(forDir: dir)
                : CmuxFolderProfileStore.basenameIdentity(forDir: dir)
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
