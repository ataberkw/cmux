import Foundation
import SwiftUI

/// Plays the user's notification sound once when an agent session's prompt
/// cache is ~10 min from its 1h idle expiry (50 min since the last turn), so a
/// session about to lose its warm cache gets an audible warning. Re-arms per
/// session on each new turn and skips ended sessions; the sound choice and
/// silence follow the app's notification-sound settings (Focus/DND-gated).
/// The 1h assumption matches Claude's extended cache; Cursor is treated the same.
///
/// Runs only while a custom sidebar is on screen (see
/// ``View/cacheExpiryWarningDemand()``) and never polls: each session-record
/// change, and each one-shot timer set for the earliest pending warning,
/// re-sweeps. With no pending warning there is no timer at all.
@MainActor
final class CacheExpiryWarningCenter {
    /// One agent session as the sweep sees it.
    struct Session: Equatable {
        let id: String
        let lastActivityAt: Date
        let isEnded: Bool
    }

    static let shared = CacheExpiryWarningCenter(
        sessions: {
            (TerminalController.shared.agentChatTranscriptService?.sessionRecords(workspaceID: nil) ?? [])
                .map { record in
                    let isEnded: Bool
                    if case .ended = record.state { isEnded = true } else { isEnded = false }
                    return Session(id: record.sessionID, lastActivityAt: record.lastActivityAt, isEnded: isEnded)
                }
        },
        playSound: { NotificationSoundSettings.playSelectedSound() }
    )

    static let cacheTTL: TimeInterval = 3600
    /// 50 min idle, 10 min before expiry.
    static let warnAfterIdle: TimeInterval = 3000
    /// Lets the system coalesce the wakeup with others; the warning is a
    /// 10-minute heads-up, so up to 30 s late is harmless.
    static let timerTolerance: TimeInterval = 30

    private let sessions: @MainActor () -> [Session]
    private let playSound: @MainActor () -> Void
    private let now: () -> Date
    private var demand = 0
    private var timer: Timer?
    private var warnedSessions: Set<String> = []
    private var lastActivityBySession: [String: Date] = [:]

    init(
        sessions: @escaping @MainActor () -> [Session],
        playSound: @escaping @MainActor () -> Void,
        now: @escaping () -> Date = { Date() }
    ) {
        self.sessions = sessions
        self.playSound = playSound
        self.now = now
    }

    /// Whether a one-shot timer is pending (for tests).
    var hasPendingTimer: Bool { timer != nil }

    /// A custom sidebar appeared; starts sweeping on the first one.
    func retain() {
        demand += 1
        if demand == 1 { reschedule() }
    }

    /// A custom sidebar disappeared; stops everything on the last one.
    func release() {
        guard demand > 0 else { return }
        demand -= 1
        if demand == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    /// A session record changed (a new turn, a state change, a removal).
    func sessionsDidChange() {
        guard demand > 0 else { return }
        reschedule()
    }

    /// Sweeps now, then arms one timer for the earliest pending warning.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard demand > 0 else { return }
        let current = sessions()
        let date = now()
        sweep(current, now: date)
        guard let fireAt = Self.nextWarningDate(sessions: current, warned: warnedSessions, now: date) else { return }
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        timer.tolerance = Self.timerTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Re-arms sessions with a new turn, warns each idle-enough live session
    /// once, and forgets sessions that are gone.
    private func sweep(_ sessions: [Session], now: Date) {
        var live: Set<String> = []
        for session in sessions {
            live.insert(session.id)
            if lastActivityBySession[session.id] != session.lastActivityAt {
                lastActivityBySession[session.id] = session.lastActivityAt
                warnedSessions.remove(session.id)  // fresh turn → re-arm the warning
            }
            if session.isEnded { continue }
            let idle = now.timeIntervalSince(session.lastActivityAt)
            if idle >= Self.warnAfterIdle, idle < Self.cacheTTL, !warnedSessions.contains(session.id) {
                warnedSessions.insert(session.id)
                playSound()
            }
        }
        warnedSessions.formIntersection(live)
        lastActivityBySession = lastActivityBySession.filter { live.contains($0.key) }
    }

    /// The earliest moment a live, not-yet-warned session crosses the warning
    /// threshold after `now`, or `nil` when none will.
    static func nextWarningDate(sessions: [Session], warned: Set<String>, now: Date) -> Date? {
        sessions
            .filter { !$0.isEnded && !warned.contains($0.id) }
            .map { $0.lastActivityAt.addingTimeInterval(warnAfterIdle) }
            .filter { $0 > now }
            .min()
    }
}

extension View {
    /// Keeps ``CacheExpiryWarningCenter`` running while this custom sidebar
    /// surface is on screen.
    func cacheExpiryWarningDemand() -> some View {
        onAppear { CacheExpiryWarningCenter.shared.retain() }
            .onDisappear { CacheExpiryWarningCenter.shared.release() }
    }
}
