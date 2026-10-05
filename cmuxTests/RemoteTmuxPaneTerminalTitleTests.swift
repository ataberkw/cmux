import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A remote tmux pane has no cmux hooks, so Claude's turn state reaches the
/// mirror only through the terminal title Claude sets (`#{pane_title}`).
@MainActor
struct RemoteTmuxPaneTerminalTitleTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func claudeIdleGlyphReadsAsIdleWithItsTopic() {
        let title = RemoteTmuxPaneTerminalTitle(raw: "✳ Q3 revenue report analysis", previous: nil, now: start)
        #expect(title.glyphStatus == .idle)
        #expect(title.topic == "Q3 revenue report analysis")
        #expect(title.agentStatus(foregroundCommand: "claude") == .idle)
        // npm installs run as `node`; ✳ is Claude's own glyph.
        #expect(title.agentStatus(foregroundCommand: "node") == .idle)
    }

    @Test func brailleSpinnerCountsOnlyWhileClaudeIsTheForegroundCommand() {
        let title = RemoteTmuxPaneTerminalTitle(raw: "⠂ Ödeme ekranı tasarımı", previous: nil, now: start)
        #expect(title.glyphStatus == .working)
        #expect(title.topic == "Ödeme ekranı tasarımı")
        #expect(title.agentStatus(foregroundCommand: "claude") == .working)
        // Any other CLI can draw a Braille spinner.
        #expect(title.agentStatus(foregroundCommand: "npm") == nil)
    }

    /// Claude exits and leaves its last title behind; the shell prompt is back.
    @Test func plainShellForegroundMeansNoAgent() {
        let title = RemoteTmuxPaneTerminalTitle(raw: "✳ dashboard layout", previous: nil, now: start)
        #expect(title.agentStatus(foregroundCommand: "bash") == nil)
        #expect(title.agentStatus(foregroundCommand: "-zsh") == nil)
    }

    @Test func ordinaryTitlesCarryNoTurnState() {
        for raw in ["vim main.swift", "user@host: ~/dt", "✳", "⠂", "✳topic"] {
            let title = RemoteTmuxPaneTerminalTitle(raw: raw, previous: nil, now: start)
            if raw == "✳" {
                #expect(title.glyphStatus == .idle)
                #expect(title.topic == "")
            } else if raw == "⠂" {
                #expect(title.glyphStatus == .working)
            } else {
                #expect(title.glyphStatus == nil, "\(raw)")
                #expect(title.topic == raw)
            }
        }
    }

    /// The status timestamp survives spinner frames and resets on a turn edge,
    /// so the sidebar's last-activity time is the end of the last turn.
    @Test func statusSinceCarriesAcrossSpinnerFramesAndResetsOnTurnEdge() {
        let first = RemoteTmuxPaneTerminalTitle(raw: "⠂ task", previous: nil, now: start)
        let frame = RemoteTmuxPaneTerminalTitle(raw: "⠐ task", previous: first, now: start + 1)
        #expect(frame.glyphStatus == .working)
        #expect(frame.glyphStatusSince == start)
        #expect(!frame.isMeaningfulChange(from: first))

        let done = RemoteTmuxPaneTerminalTitle(raw: "✳ task", previous: frame, now: start + 30)
        #expect(done.glyphStatusSince == start + 30)
        #expect(done.isMeaningfulChange(from: frame))
    }

    /// Mid-turn spinner frames arrive once a second; each topology notify
    /// re-runs every mirror's reconcile, so only real changes may notify.
    @Test func titleSubscriptionNotifiesOnlyOnTopicOrTurnChanges() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_title_4", value: "⠂ task"))
        #expect(connection.paneTerminalTitles[4]?.raw == "⠂ task")
        #expect(notifies == 1)

        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_title_4", value: "⠐ task"))
        #expect(connection.paneTerminalTitles[4]?.raw == "⠐ task")
        #expect(notifies == 1)

        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_title_4", value: "✳ task"))
        #expect(notifies == 2)

        // tmux's default title (the host name) arrives as empty: back to the
        // window-based name.
        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_title_4", value: ""))
        #expect(connection.paneTerminalTitles[4] == nil)
        #expect(notifies == 3)
    }

    /// The shown title pins a working turn to one glyph, so tab and sidebar
    /// titles change with the topic or turn state, not every spinner frame.
    @Test func displayTitlePinsSpinnerFramesToOneGlyph() {
        let first = RemoteTmuxPaneTerminalTitle(raw: "⠂ task", previous: nil, now: start)
        let next = RemoteTmuxPaneTerminalTitle(raw: "⠐ task", previous: first, now: start + 1)
        #expect(first.displayTitle == "⠿ task")
        #expect(next.displayTitle == first.displayTitle)
        #expect(RemoteTmuxPaneTerminalTitle(raw: "✳ task", previous: nil, now: start).displayTitle == "✳ task")
        #expect(RemoteTmuxPaneTerminalTitle(raw: "vim main.swift", previous: nil, now: start).displayTitle == "vim main.swift")
    }

    @Test func ignoringSpinnerFramesCollapsesOnlyBrailleFrames() {
        typealias Title = RemoteTmuxPaneTerminalTitle
        #expect(Title.ignoringSpinnerFrames("0 \"⠂ task\"") == Title.ignoringSpinnerFrames("0 \"⠐ task\""))
        #expect(Title.ignoringSpinnerFrames("0 \"⠂ task\"") != Title.ignoringSpinnerFrames("0 \"✳ task\""))
        #expect(Title.ignoringSpinnerFrames("0 \"⠂ task\"") != Title.ignoringSpinnerFrames("0 \"⠂ other\""))
        #expect(Title.ignoringSpinnerFrames("plain") == "plain")
    }

    /// tmux's default `pane-border-format` embeds `#{pane_title}`, so the
    /// header subscription re-sends every spinner frame too. Those must not
    /// re-run the session's reconcile; real header changes still must.
    @Test func headerSubscriptionIgnoresSpinnerOnlyChanges() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_hdr_4", value: "0 \"⠂ task\""))
        #expect(notifies == 1)

        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_hdr_4", value: "0 \"⠐ task\""))
        #expect(connection.paneHeaderLabels[4] == "0 \"⠐ task\"")
        #expect(notifies == 1)

        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_hdr_4", value: "0 \"✳ task\""))
        #expect(notifies == 2)

        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_hdr_4", value: "#[reverse]0 \"✳ task\""))
        #expect(notifies == 2)  // style tokens only: same label
    }
}
