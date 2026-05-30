import XCTest
@testable import ClaudeTracker

final class ClaudeTrackerTests: XCTestCase {

    // MARK: - ISO 8601 date parsing

    func testResetsAtDateWithFractionalSeconds() {
        let w = UsageWindow(utilization: 50, resetsAt: "2025-01-15T10:00:00.000Z")
        XCTAssertNotNil(w.resetsAtDate)
    }

    func testResetsAtDateWithoutFractionalSeconds() {
        let w = UsageWindow(utilization: 50, resetsAt: "2025-01-15T10:00:00Z")
        XCTAssertNotNil(w.resetsAtDate)
    }

    func testResetsAtDateInvalid() {
        let w = UsageWindow(utilization: 50, resetsAt: "not-a-date")
        XCTAssertNil(w.resetsAtDate)
    }

    func testResetsAtDateParsesCorrectly() {
        let w = UsageWindow(utilization: 50, resetsAt: "2025-01-15T10:00:00Z")
        var comps = DateComponents()
        comps.year = 2025; comps.month = 1; comps.day = 15
        comps.hour = 10; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: comps)
        XCTAssertEqual(w.resetsAtDate, expected)
    }

    // MARK: - Utilization fraction clamping

    func testUtilizationFractionNormal() {
        XCTAssertEqual(UsageWindow(utilization: 50, resetsAt: "").utilizationFraction, 0.5)
    }

    func testUtilizationFractionAtZero() {
        XCTAssertEqual(UsageWindow(utilization: 0, resetsAt: "").utilizationFraction, 0.0)
    }

    func testUtilizationFractionAtHundred() {
        XCTAssertEqual(UsageWindow(utilization: 100, resetsAt: "").utilizationFraction, 1.0)
    }

    func testUtilizationFractionClampsAboveHundred() {
        XCTAssertEqual(UsageWindow(utilization: 110, resetsAt: "").utilizationFraction, 1.0)
    }

    // MARK: - Subscription label inference

    func testSubscriptionLabelMax20x() {
        XCTAssertEqual(makeInfo(caps: ["claude_max"], tier: "default_claude_max_20x").subscriptionLabel, "Max 20×")
    }

    func testSubscriptionLabelMax5x() {
        XCTAssertEqual(makeInfo(caps: ["claude_max"], tier: "default_claude_max_5x").subscriptionLabel, "Max 5×")
    }

    func testSubscriptionLabelMax() {
        XCTAssertEqual(makeInfo(caps: ["claude_max"], tier: "default_claude_max").subscriptionLabel, "Max")
    }

    func testSubscriptionLabelProViaCaps() {
        XCTAssertEqual(makeInfo(caps: ["claude_pro"], tier: "").subscriptionLabel, "Pro")
    }

    func testSubscriptionLabelProViaTier() {
        XCTAssertEqual(makeInfo(caps: [], tier: "default_pro").subscriptionLabel, "Pro")
    }

    func testSubscriptionLabelTeam() {
        XCTAssertEqual(makeInfo(caps: ["claude_team"], tier: "").subscriptionLabel, "Team")
    }

    func testSubscriptionLabelEnterprise() {
        XCTAssertEqual(makeInfo(caps: ["claude_enterprise"], tier: "").subscriptionLabel, "Enterprise")
    }

    func testSubscriptionLabelNilForFreeAccount() {
        XCTAssertNil(makeInfo(caps: [], tier: "").subscriptionLabel)
    }

    func testSubscriptionLabelNilWhenNoMemberships() {
        let info = AccountInfo(fullName: nil, emailAddress: "x@x.com", memberships: nil)
        XCTAssertNil(info.subscriptionLabel)
    }

    // MARK: - Version comparison

    func testVersionIsNewer() {
        XCTAssertTrue(isNewerVersion("1.9.0", than: "1.8.0"))
    }

    func testVersionIsOlder() {
        XCTAssertFalse(isNewerVersion("1.7.0", than: "1.8.0"))
    }

    func testVersionIsSame() {
        XCTAssertFalse(isNewerVersion("1.8.0", than: "1.8.0"))
    }

    func testVersionMajorBump() {
        XCTAssertTrue(isNewerVersion("2.0.0", than: "1.9.9"))
    }

    func testVersionPatchLevel() {
        XCTAssertTrue(isNewerVersion("1.8.1", than: "1.8.0"))
    }

    func testVersionTwoDigitMinor() {
        // Ensures numeric comparison (not lexicographic): "1.10.0" > "1.9.0"
        XCTAssertTrue(isNewerVersion("1.10.0", than: "1.9.0"))
    }

    // MARK: - Pace calculation

    func testPaceNilWhenHistoryEmpty() {
        XCTAssertNil(computePace(history: []))
    }

    func testPaceNilWhenOnlyOneEntry() {
        XCTAssertNil(computePace(history: [(Date(), 10.0)]))
    }

    func testPaceNilWhenElapsedTooShort() {
        let now = Date()
        // 10 seconds elapsed — below the 15s minimum
        let history = [(now.addingTimeInterval(-10), 10.0), (now, 11.0)]
        XCTAssertNil(computePace(history: history))
    }

    func testPaceNilWhenRateNegligible() {
        let now = Date()
        // 1 hr elapsed, 0.05% delta → rate = 0.05 %/hr ≤ 0.1 threshold
        let history = [(now.addingTimeInterval(-3600), 10.0), (now, 10.05)]
        XCTAssertNil(computePace(history: history))
    }

    func testPaceReturnsCorrectRate() {
        let now = Date()
        // 1 hr elapsed, 10% delta → rate = 10 %/hr
        let history = [(now.addingTimeInterval(-3600), 50.0), (now, 60.0)]
        let result = computePace(history: history)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.rate, 10.0, accuracy: 0.01)
    }

    func testPaceProjectedHours() {
        let now = Date()
        // 1 hr elapsed, 10% delta → rate = 10 %/hr; 40% remaining (100-60) → projected = 4 hr
        let history = [(now.addingTimeInterval(-3600), 50.0), (now, 60.0)]
        let result = computePace(history: history)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.projectedHours!, 4.0, accuracy: 0.01)
    }

    func testPaceProjectedHoursNilAtFull() {
        let now = Date()
        // Already at 100% → remaining = 0 → projectedHours = nil
        let history = [(now.addingTimeInterval(-3600), 90.0), (now, 100.0)]
        let result = computePace(history: history)
        XCTAssertNotNil(result)
        XCTAssertNil(result!.projectedHours)
    }

    // MARK: - Adaptive update-check interval

    func testAdaptiveCheckIntervalDefaultsWithoutEnoughDates() {
        XCTAssertEqual(adaptiveCheckInterval(from: []), 12 * 3600, accuracy: 0.5)
        XCTAssertEqual(adaptiveCheckInterval(from: [Date()]), 12 * 3600, accuracy: 0.5)
    }

    func testAdaptiveCheckIntervalClampsToFloor() {
        // Two releases 8h apart → half = 4h (the floor).
        let now = Date()
        XCTAssertEqual(adaptiveCheckInterval(from: [now, now.addingTimeInterval(-8 * 3600)]),
                       4 * 3600, accuracy: 0.5)
    }

    func testAdaptiveCheckIntervalClampsToCeiling() {
        // ~10 days apart → half = 5 days, clamped to the 24h ceiling.
        let now = Date()
        XCTAssertEqual(adaptiveCheckInterval(from: [now, now.addingTimeInterval(-10 * 24 * 3600)]),
                       24 * 3600, accuracy: 0.5)
    }

    func testAdaptiveCheckIntervalAveragesGapsAndIgnoresOrder() {
        // Gaps of 20h and 40h → avg 30h → half = 15h. Input deliberately unsorted.
        let now = Date()
        let dates = [now.addingTimeInterval(-60 * 3600), now, now.addingTimeInterval(-20 * 3600)]
        XCTAssertEqual(adaptiveCheckInterval(from: dates), 15 * 3600, accuracy: 1)
    }

    // MARK: - Window reset detection

    func testIsWindowResetTrueOnLargeForwardJumpAndLowUtil() {
        let prev = Date()
        XCTAssertTrue(isWindowReset(previous: prev, next: prev.addingTimeInterval(5 * 3600), utilization: 2))
    }

    func testIsWindowResetFalseAtExactlyOneHour() {
        let prev = Date()
        XCTAssertFalse(isWindowReset(previous: prev, next: prev.addingTimeInterval(3600), utilization: 0))
    }

    func testIsWindowResetFalseWhenUtilizationStillHigh() {
        let prev = Date()
        XCTAssertFalse(isWindowReset(previous: prev, next: prev.addingTimeInterval(5 * 3600), utilization: 6))
    }

    // MARK: - Stale data detection

    func testWindowIsStaleWhenResetPassedAfterLastFetch() {
        let now = Date()
        XCTAssertTrue(windowIsStale(resetsAt: now.addingTimeInterval(-3600),
                                    lastUpdated: now.addingTimeInterval(-2 * 3600), now: now))
    }

    func testWindowIsStaleFalseWhenFetchedAfterReset() {
        let now = Date()
        XCTAssertFalse(windowIsStale(resetsAt: now.addingTimeInterval(-3600),
                                     lastUpdated: now.addingTimeInterval(-600), now: now))
    }

    func testWindowIsStaleFalseWhenResetInFuture() {
        let now = Date()
        XCTAssertFalse(windowIsStale(resetsAt: now.addingTimeInterval(3600),
                                     lastUpdated: now.addingTimeInterval(-600), now: now))
    }

    func testWindowIsStaleFalseWhenNilInputs() {
        let now = Date()
        XCTAssertFalse(windowIsStale(resetsAt: nil, lastUpdated: now, now: now))
        XCTAssertFalse(windowIsStale(resetsAt: now, lastUpdated: nil, now: now))
    }

    // MARK: - Poll interval from projected minutes
    // Exercises the construction/startup split: a bare UsageViewModel() is now
    // constructible in tests because init() no longer spawns tasks/observers.

    @MainActor
    func testIntervalForProjMinsBoundaries() {
        let vm = UsageViewModel()
        XCTAssertEqual(vm.intervalForProjMins(120), 10)
        XCTAssertEqual(vm.intervalForProjMins(60), 10)
        XCTAssertEqual(vm.intervalForProjMins(45), 8)
        XCTAssertEqual(vm.intervalForProjMins(30), 8)
        XCTAssertEqual(vm.intervalForProjMins(20), 5)
        XCTAssertEqual(vm.intervalForProjMins(15), 5)
        XCTAssertEqual(vm.intervalForProjMins(10), 3)
        XCTAssertEqual(vm.intervalForProjMins(5), 3)
        XCTAssertEqual(vm.intervalForProjMins(3), 2)
        XCTAssertEqual(vm.intervalForProjMins(2), 2)
        XCTAssertEqual(vm.intervalForProjMins(1), 1)
    }

    // MARK: - Helpers

    private func makeInfo(caps: [String], tier: String) -> AccountInfo {
        let org = AccountOrganization(capabilities: caps, rateLimitTier: tier)
        return AccountInfo(fullName: nil, emailAddress: "t@t.com", memberships: [AccountMembership(organization: org)])
    }
}
