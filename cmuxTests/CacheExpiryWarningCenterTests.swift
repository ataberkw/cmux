import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The cache-expiry warning used to poll every 30 s forever; it now arms one
/// timer for the earliest pending warning, only while a sidebar wants it.
@MainActor
struct CacheExpiryWarningCenterTests {
    private typealias Session = CacheExpiryWarningCenter.Session
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test func nextWarningPicksEarliestLiveUnwarnedSession() {
        let sessions = [
            Session(id: "late", lastActivityAt: now.addingTimeInterval(-60), isEnded: false),
            Session(id: "early", lastActivityAt: now.addingTimeInterval(-600), isEnded: false),
            Session(id: "ended", lastActivityAt: now.addingTimeInterval(-2_900), isEnded: true),
            Session(id: "warned", lastActivityAt: now.addingTimeInterval(-2_950), isEnded: false),
        ]
        let next = CacheExpiryWarningCenter.nextWarningDate(sessions: sessions, warned: ["warned"], now: now)
        #expect(next == now.addingTimeInterval(-600 + CacheExpiryWarningCenter.warnAfterIdle))
    }

    @Test func noSessionsMeansNoTimer() {
        let center = CacheExpiryWarningCenter(sessions: { [] }, playSound: {}, now: { self.now })
        center.retain()
        #expect(!center.hasPendingTimer)
        center.release()
    }

    @Test func warnsOnceThenRearmsOnNewTurn() {
        var sessions = [Session(id: "s", lastActivityAt: now.addingTimeInterval(-3_100), isEnded: false)]
        var plays = 0
        let center = CacheExpiryWarningCenter(sessions: { sessions }, playSound: { plays += 1 }, now: { self.now })

        center.retain()
        #expect(plays == 1)
        #expect(!center.hasPendingTimer)  // already warned, nothing pending

        center.sessionsDidChange()
        #expect(plays == 1)  // same turn, no repeat

        sessions = [Session(id: "s", lastActivityAt: now, isEnded: false)]
        center.sessionsDidChange()
        #expect(plays == 1)
        #expect(center.hasPendingTimer)  // armed for the new turn's 50-minute mark
        center.release()
    }

    @Test func releasingLastDemandStopsTheTimerAndIgnoresChanges() {
        var plays = 0
        let sessions = [Session(id: "s", lastActivityAt: now, isEnded: false)]
        let center = CacheExpiryWarningCenter(sessions: { sessions }, playSound: { plays += 1 }, now: { self.now })

        center.retain()
        center.retain()
        #expect(center.hasPendingTimer)
        center.release()
        #expect(center.hasPendingTimer)
        center.release()
        #expect(!center.hasPendingTimer)
        center.sessionsDidChange()
        #expect(!center.hasPendingTimer)
        #expect(plays == 0)
    }
}
