import Foundation

/// A Claude Code turn state read from a mirrored pane's terminal title.
enum RemoteTmuxPaneAgentStatus: String, Equatable, Sendable {
    case idle
    case working
}

/// A mirrored pane's program-set terminal title (`#{pane_title}`, which tmux
/// keeps from the program's OSC 0/2 title sequences) and the Claude Code turn
/// state that title encodes.
///
/// Claude Code titles its terminal `✳ <topic>` between turns and swaps the
/// glyph for a Braille spinner frame (`⠂ <topic>`, `⠐ <topic>`) while a turn
/// runs. A remote tmux pane has no cmux hooks (the ssh-tmux transport has no
/// socket relay), so this title is the only turn signal the mirror sees.
struct RemoteTmuxPaneTerminalTitle: Equatable, Sendable {
    /// The title exactly as tmux reports it.
    let raw: String
    /// The turn state the leading glyph encodes, before any foreground-command
    /// gating (see ``agentStatus(foregroundCommand:)``).
    let glyphStatus: RemoteTmuxPaneAgentStatus?
    /// The title without its leading turn glyph.
    let topic: String
    /// When ``glyphStatus`` last changed, or `nil` when the state already held
    /// at first sight. First sight (a connect, a reconnect, an app relaunch)
    /// says nothing about when the turn ended, so it is not a change: treating
    /// it as one made an hour-idle pane read as a fresh turn.
    private(set) var glyphStatusSince: Date?

    /// Claude Code's between-turns title glyph.
    static let idleGlyph: Character = "\u{2733}"
    /// The one glyph shown for a working turn in place of the spinner frame
    /// Claude advances every second (see ``displayTitle``).
    static let workingDisplayGlyph: Character = "\u{283F}"

    /// The title cmux shows (tab, sidebar): `raw`, except a working turn's
    /// spinner frame is pinned to ``workingDisplayGlyph`` so the shown title
    /// changes only with the topic or turn state, not once a second.
    var displayTitle: String {
        glyphStatus == .working ? "\(Self.workingDisplayGlyph) \(topic)" : raw
    }

    /// `text` with every Braille spinner frame (U+2801–U+28FF) collapsed to
    /// one, so two renderings of the same text that differ only by which
    /// spinner frame they caught compare equal.
    static func ignoringSpinnerFrames(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isSpinnerFrame) else { return text }
        let blank: Unicode.Scalar = "\u{2800}"
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(isSpinnerFrame(scalar) ? blank : scalar)
        }
        return String(scalars)
    }

    private static func isSpinnerFrame(_ scalar: Unicode.Scalar) -> Bool {
        (0x2801...0x28FF).contains(scalar.value)
    }

    /// Parses `raw`, carrying `previous`'s status timestamp forward while the
    /// turn state is unchanged (spinner frames churn every second mid-turn).
    /// Without a `previous` the timestamp is unknown (`nil`).
    init(raw: String, previous: RemoteTmuxPaneTerminalTitle?, now: Date) {
        self.raw = raw
        let parsed = Self.parse(raw)
        glyphStatus = parsed.status
        topic = parsed.topic
        if let previous {
            glyphStatusSince = previous.glyphStatus == parsed.status ? previous.glyphStatusSince : now
        } else {
            glyphStatusSince = nil
        }
    }

    /// Fills an unknown status timestamp from a remembered one (see
    /// ``RemoteTmuxPaneStatusSinceStore``). A known timestamp is kept.
    mutating func restoreGlyphStatusSince(_ since: Date?) {
        guard glyphStatusSince == nil else { return }
        glyphStatusSince = since
    }

    /// Whether moving from `previous` to this title changes anything a reader
    /// shows: the topic or the turn state. A spinner frame advancing is not a
    /// change, so it does not re-run every mirror's reconcile once a second.
    func isMeaningfulChange(from previous: RemoteTmuxPaneTerminalTitle?) -> Bool {
        guard let previous else { return true }
        return previous.topic != topic || previous.glyphStatus != glyphStatus
    }

    /// The Claude turn state for a pane running `foregroundCommand`, or nil
    /// when the pane is not running Claude.
    ///
    /// A plain shell in the foreground means Claude exited and left its last
    /// title behind. A Braille frame is any CLI's spinner, so it counts only
    /// while `claude` itself is the foreground command. `✳` is Claude's own
    /// glyph and counts for any non-shell command (npm installs run as `node`).
    func agentStatus(foregroundCommand: String?) -> RemoteTmuxPaneAgentStatus? {
        let command = foregroundCommand?.trimmingCharacters(in: .whitespaces) ?? ""
        if RemoteTmuxPaneForegroundState.plainShellCommands.contains(command) { return nil }
        switch glyphStatus {
        case .idle:
            return .idle
        case .working:
            return command == "claude" ? .working : nil
        case nil:
            return nil
        }
    }

    private static func parse(_ raw: String) -> (status: RemoteTmuxPaneAgentStatus?, topic: String) {
        let trimmed = raw.drop(while: \.isWhitespace)
        guard let glyph = trimmed.first else { return (nil, raw) }
        let rest = trimmed.dropFirst()
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return (nil, raw) }
        let status: RemoteTmuxPaneAgentStatus
        if glyph == idleGlyph {
            status = .idle
        } else if glyph.unicodeScalars.count == 1,
                  let scalar = glyph.unicodeScalars.first,
                  isSpinnerFrame(scalar) {
            status = .working
        } else {
            return (nil, raw)
        }
        return (status, String(rest.drop(while: \.isWhitespace)))
    }
}
