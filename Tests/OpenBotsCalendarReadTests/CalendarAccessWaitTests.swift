import EventKit
import Foundation
import Testing
@testable import openbots_calendar_read

/// The first calendar read after the permission prompt used to wait the full
/// 120 s. The reader blocked on a semaphore for EventKit's completion
/// and never looked at the status, so a grant whose completion did not arrive
/// (or arrived on the main queue it was blocking) was invisible until the
/// deadline. These drive the wait with a stubbed request and status; nothing
/// here touches the real TCC database, so these do not stand in for a run
/// against a real permission prompt.
struct CalendarAccessWaitTests {
    @Test("A grant seen in the status ends the wait even when the completion never comes")
    func statusGrantEndsTheWait() {
        var polls = 0
        let answer = awaitCalendarAccess(
            request: { _ in },
            status: {
                polls += 1
                return polls >= 3 ? .fullAccess : .notDetermined
            },
            timeout: 30, pollInterval: 0.01)
        #expect(answer == .grantedByStatus)
        #expect(polls >= 3)
    }

    @Test("Access already allowed keeps the store it was asked on")
    func alreadyAllowedIsAPlainGrant() {
        let answer = awaitCalendarAccess(request: { _ in }, status: { .fullAccess },
                                         timeout: 30, pollInterval: 0.01)
        #expect(answer == .granted)
    }

    @Test("A refusal seen in the status ends the wait too")
    func statusRefusalEndsTheWait() {
        var polls = 0
        let answer = awaitCalendarAccess(
            request: { _ in },
            status: {
                polls += 1
                return polls >= 2 ? .denied : .notDetermined
            },
            timeout: 30, pollInterval: 0.01)
        #expect(answer == .refused(nil))
    }

    @Test("The completion's own answer wins when it comes, from any queue")
    func completionAnswers() {
        let granted = awaitCalendarAccess(
            request: { reply in DispatchQueue.global().async { reply(true, nil) } },
            status: { .notDetermined }, timeout: 30, pollInterval: 0.01)
        #expect(granted == .granted)

        struct Refusal: LocalizedError { var errorDescription: String? { "not now" } }
        let refused = awaitCalendarAccess(
            request: { reply in DispatchQueue.global().async { reply(false, Refusal()) } },
            status: { .notDetermined }, timeout: 30, pollInterval: 0.01)
        #expect(refused == .refused("not now"))
    }

    @Test("Write-only access is not full access: it keeps waiting, then times out")
    func nothingComesBack() {
        #expect(awaitCalendarAccess(request: { _ in }, status: { .notDetermined },
                                    timeout: 0.05, pollInterval: 0.01) == .timedOut)
        #expect(awaitCalendarAccess(request: { _ in }, status: { .writeOnly },
                                    timeout: 0.05, pollInterval: 0.01) == .timedOut)
    }
}
