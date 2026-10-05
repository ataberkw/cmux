import Foundation

/// Selection contract for a remote tmux split. Every mutation caller must state
/// whether tmux may select the created pane; background automation uses
/// `preserveActivePane`, which maps to `split-window -d`.
enum RemoteTmuxSplitFocusIntent: Sendable, Equatable {
    case preserveActivePane
    case focusCreatedPane

    /// Builds the `split-window` command for a mirror split.
    ///
    /// `workingDirectory` is the split pane's remote cwd, as cmux tracks it
    /// from `pane_current_path`, so the new pane starts where the split pane is,
    /// like a local split. It is a literal path on purpose: tmux expands a
    /// `-c '#{pane_current_path}'` format against the session's current window
    /// rather than the `-t` pane, and cmux never `select-window`s the remote.
    /// A nil/blank path, or one carrying control bytes that could end the
    /// command line, omits `-c` and tmux uses the session's start directory.
    func command(
        vertical: Bool,
        windowID: Int,
        paneID: Int,
        insertBefore: Bool = false,
        workingDirectory: String? = nil
    ) -> String {
        let focusContract = self == .preserveActivePane
            ? "-d"
            : "-P -F '#{pane_id}'"
        let placement = insertBefore ? " -b" : ""
        var command = "split-window \(focusContract) \(vertical ? "-v" : "-h")\(placement) -t @\(windowID).%\(paneID)"
        if let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty,
           RemoteTmuxHost.controlModeLineSafeName(directory) != nil {
            command += " -c \(RemoteTmuxHost.shellSingleQuoted(directory))"
        }
        return command
    }

    func agentForkCommand(
        vertical: Bool,
        windowID: Int,
        paneID: Int,
        insertBefore: Bool,
        shellCommand: String,
        workingDirectory: String?
    ) -> String? {
        guard RemoteTmuxHost.controlModeLineSafeName(shellCommand) != nil else {
            return nil
        }
        var command = command(
            vertical: vertical,
            windowID: windowID,
            paneID: paneID,
            insertBefore: insertBefore
        )
        if let workingDirectory {
            guard RemoteTmuxHost.controlModeLineSafeName(workingDirectory) != nil else {
                return nil
            }
            command += " -c \(RemoteTmuxHost.shellSingleQuoted(workingDirectory))"
        }
        command += " \(RemoteTmuxHost.shellSingleQuoted(shellCommand))"
        return command
    }
}
