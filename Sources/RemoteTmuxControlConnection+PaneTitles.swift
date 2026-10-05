import Foundation

extension RemoteTmuxControlConnection {
    /// Records one `cmux_title_<pane>` push. An empty value means the pane
    /// still carries tmux's default title (see ``paneTerminalTitleFormat``).
    ///
    /// Only a topic or turn-state change notifies topology observers: Claude's
    /// spinner advances the title every second mid-turn, and each notify
    /// re-runs every mirror's reconcile. The stored raw title stays current, so
    /// the next reconcile for any reason copies the latest frame.
    func notePaneTerminalTitle(paneId: Int, rawValue: String, now: Date = Date()) {
        let title = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = paneTerminalTitles[paneId]
        guard !title.isEmpty else {
            if paneTerminalTitles.removeValue(forKey: paneId) != nil {
                observers.notifyTopologyChanged()
            }
            return
        }
        let next = RemoteTmuxPaneTerminalTitle(raw: title, previous: previous, now: now)
        guard next != previous else { return }
        paneTerminalTitles[paneId] = next
        if next.isMeaningfulChange(from: previous) {
            observers.notifyTopologyChanged()
        }
    }

    /// Records one `cmux_hdr_<pane>` push (the pane's expanded
    /// `pane-border-format`).
    ///
    /// tmux's default border format embeds `#{pane_title}`, so mid-turn every
    /// Claude spinner frame re-sends the header. A change that is only a
    /// different spinner frame is stored without a topology notify (each
    /// notify reconciles every window of the session); the next reconcile for
    /// any other reason copies the latest frame.
    func notePaneHeaderLabel(paneId: Int, rawValue: String) {
        let label = Self.strippingStyleTokens(rawValue)
        guard let previous = paneHeaderLabels[paneId] else {
            paneHeaderLabels[paneId] = label
            observers.notifyTopologyChanged()
            return
        }
        guard previous != label else { return }
        paneHeaderLabels[paneId] = label
        if RemoteTmuxPaneTerminalTitle.ignoringSpinnerFrames(previous)
            != RemoteTmuxPaneTerminalTitle.ignoringSpinnerFrames(label) {
            observers.notifyTopologyChanged()
        }
    }
}
