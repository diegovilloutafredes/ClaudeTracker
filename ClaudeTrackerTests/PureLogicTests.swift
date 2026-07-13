import XCTest
import SwiftUI
@testable import ClaudeTracker

/// Tests for the pure tuning/maintenance helpers and the API fixture decoding.
final class PureLogicTests: XCTestCase {

    // MARK: - pollInterval: stale window

    func testPollIntervalStaleWindowPollsAggressively() {
        let now = Date()
        // Reset passed 10s ago — 2s regardless of utilization.
        XCTAssertEqual(pollInterval(utilization: 40, resetsAt: now.addingTimeInterval(-10), projectedMinutes: nil, now: now), 2)
        XCTAssertEqual(pollInterval(utilization: 100, resetsAt: now.addingTimeInterval(-10), projectedMinutes: nil, now: now), 2)
    }

    // MARK: - pollInterval: at 100%

    func testPollIntervalAtFullWithUnknownReset() {
        XCTAssertEqual(pollInterval(utilization: 100, resetsAt: nil, projectedMinutes: nil), 30)
    }

    func testPollIntervalAtFullTiersByTimeToReset() {
        let now = Date()
        XCTAssertEqual(pollInterval(utilization: 100, resetsAt: now.addingTimeInterval(3600), projectedMinutes: nil, now: now), 300)
        XCTAssertEqual(pollInterval(utilization: 100, resetsAt: now.addingTimeInterval(700), projectedMinutes: nil, now: now), 120)
        XCTAssertEqual(pollInterval(utilization: 100, resetsAt: now.addingTimeInterval(200), projectedMinutes: nil, now: now), 30)
        XCTAssertEqual(pollInterval(utilization: 100, resetsAt: now.addingTimeInterval(60), projectedMinutes: nil, now: now), 10)
    }

    func testPollIntervalJustBelowFullThresholdUsesFallback() {
        let now = Date()
        // 99.8% is below the 99.9 threshold → falls through to utilization tiers (95... → 3)
        XCTAssertEqual(pollInterval(utilization: 99.8, resetsAt: now.addingTimeInterval(3600), projectedMinutes: nil, now: now), 3)
    }

    // MARK: - pollInterval: pace-driven

    func testPollIntervalUsesProjectedMinutesWhenAvailable() {
        let now = Date()
        let reset = now.addingTimeInterval(4 * 3600)
        XCTAssertEqual(pollInterval(utilization: 50, resetsAt: reset, projectedMinutes: 120, now: now), 10)
        XCTAssertEqual(pollInterval(utilization: 50, resetsAt: reset, projectedMinutes: 45, now: now), 8)
        XCTAssertEqual(pollInterval(utilization: 50, resetsAt: reset, projectedMinutes: 20, now: now), 5)
        XCTAssertEqual(pollInterval(utilization: 50, resetsAt: reset, projectedMinutes: 10, now: now), 3)
        XCTAssertEqual(pollInterval(utilization: 50, resetsAt: reset, projectedMinutes: 3, now: now), 2)
        XCTAssertEqual(pollInterval(utilization: 50, resetsAt: reset, projectedMinutes: 1, now: now), 1)
    }

    // MARK: - pollInterval: utilization fallback

    func testPollIntervalFallbackTiersByUtilization() {
        let now = Date()
        let reset = now.addingTimeInterval(4 * 3600)
        XCTAssertEqual(pollInterval(utilization: 96, resetsAt: reset, projectedMinutes: nil, now: now), 3)
        XCTAssertEqual(pollInterval(utilization: 85, resetsAt: reset, projectedMinutes: nil, now: now), 5)
        XCTAssertEqual(pollInterval(utilization: 60, resetsAt: reset, projectedMinutes: nil, now: now), 8)
        XCTAssertEqual(pollInterval(utilization: 10, resetsAt: reset, projectedMinutes: nil, now: now), 10)
        XCTAssertEqual(pollInterval(utilization: 10, resetsAt: nil, projectedMinutes: nil, now: now), 10)
    }

    func testPollIntervalForProjectedMinutesMatchesTiers() {
        XCTAssertEqual(pollIntervalForProjectedMinutes(60), 10)
        XCTAssertEqual(pollIntervalForProjectedMinutes(30), 8)
        XCTAssertEqual(pollIntervalForProjectedMinutes(15), 5)
        XCTAssertEqual(pollIntervalForProjectedMinutes(5), 3)
        XCTAssertEqual(pollIntervalForProjectedMinutes(2), 2)
        XCTAssertEqual(pollIntervalForProjectedMinutes(1), 1)
    }

    // MARK: - Error backoff

    func testErrorBackoffScalesAndCaps() {
        XCTAssertEqual(errorBackoff(consecutiveErrors: 0), 0)
        XCTAssertEqual(errorBackoff(consecutiveErrors: 1), 10)
        XCTAssertEqual(errorBackoff(consecutiveErrors: 3), 30)
        XCTAssertEqual(errorBackoff(consecutiveErrors: 6), 60)
        XCTAssertEqual(errorBackoff(consecutiveErrors: 10), 60)
    }

    // MARK: - Pace history reset guard

    func testPaceHistoryResetsOnLargeDrop() {
        XCTAssertTrue(shouldResetPaceHistory(last: 30, current: 9))
    }

    func testPaceHistoryKeepsOnDropOfExactlyTwenty() {
        XCTAssertFalse(shouldResetPaceHistory(last: 30, current: 10))
    }

    func testPaceHistoryResetsOnLowUtilizationCrossingFive() {
        // 6% → 4%: small drop, but crossing below 5% from ≥5% signals a reset.
        XCTAssertTrue(shouldResetPaceHistory(last: 6, current: 4))
    }

    func testPaceHistoryKeepsWhenAlreadyBelowFive() {
        XCTAssertFalse(shouldResetPaceHistory(last: 4, current: 3))
    }

    func testPaceHistoryKeepsOnIncrease() {
        XCTAssertFalse(shouldResetPaceHistory(last: 4, current: 6))
        XCTAssertFalse(shouldResetPaceHistory(last: 50, current: 60))
    }

    func testPaceHistoryKeepsOnModerateDrop() {
        XCTAssertFalse(shouldResetPaceHistory(last: 50, current: 40))
    }

    // MARK: - Chart history append/prune/cap

    private func point(_ date: Date, _ v: Double = 50) -> UsageDataPoint {
        UsageDataPoint(timestamp: date, fiveHour: v, sevenDay: v, fiveHourPace: nil, sevenDayPace: nil)
    }

    func testAppendDataPointThrottledWithinFiveMinutes() {
        let now = Date()
        let history = [point(now.addingTimeInterval(-100))]
        XCTAssertNil(appendPrunedDataPoint(point(now), to: history, lastTimestamp: now.addingTimeInterval(-100)))
    }

    func testAppendDataPointAppendsAfterThrottleWindow() {
        let now = Date()
        let history = [point(now.addingTimeInterval(-400))]
        let result = appendPrunedDataPoint(point(now), to: history, lastTimestamp: now.addingTimeInterval(-400))
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?.last?.timestamp, now)
    }

    func testAppendDataPointAppendsWhenNoPriorTimestamp() {
        let now = Date()
        let result = appendPrunedDataPoint(point(now), to: [], lastTimestamp: nil)
        XCTAssertEqual(result?.count, 1)
    }

    func testAppendDataPointPrunesEntriesOlderThanThirtyDays() {
        let now = Date()
        let old = point(now.addingTimeInterval(-31 * 24 * 3600))
        let recent = point(now.addingTimeInterval(-3600))
        let result = appendPrunedDataPoint(point(now), to: [old, recent], lastTimestamp: now.addingTimeInterval(-3600))
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?.first?.timestamp, recent.timestamp)
    }

    func testAppendDataPointCapsAtLimitKeepingNewest() {
        let now = Date()
        // Chronological order, oldest first — matching how history is stored.
        let history = (1...5).reversed().map { point(now.addingTimeInterval(Double(-$0 * 400))) }
        let result = appendPrunedDataPoint(point(now), to: history, lastTimestamp: history.last?.timestamp, cap: 5)
        XCTAssertEqual(result?.count, 5)
        XCTAssertEqual(result?.last?.timestamp, now)
        // The oldest entry was dropped to respect the cap.
        XCTAssertFalse(result!.contains { $0.timestamp == now.addingTimeInterval(-2000) })
    }

    // MARK: - PaceBand

    func testPaceBandSafeWhenProjectionBeyondReset() {
        XCTAssertEqual(PaceBand(projectedHours: 5, hoursToReset: 4), .safe)
        XCTAssertEqual(PaceBand(projectedHours: 4, hoursToReset: 4), .safe)
    }

    func testPaceBandCloseWithinEightyPercentOfReset() {
        XCTAssertEqual(PaceBand(projectedHours: 3.5, hoursToReset: 4), .close)
        XCTAssertEqual(PaceBand(projectedHours: 3.2, hoursToReset: 4), .close)
    }

    func testPaceBandOverWhenFillingWellBeforeReset() {
        XCTAssertEqual(PaceBand(projectedHours: 2, hoursToReset: 4), .over)
    }

    func testPaceBandSafeOnInvalidInputs() {
        XCTAssertEqual(PaceBand(projectedHours: 0, hoursToReset: 4), .safe)
        XCTAssertEqual(PaceBand(projectedHours: -1, hoursToReset: 4), .safe)
        XCTAssertEqual(PaceBand(projectedHours: 2, hoursToReset: 0), .safe)
    }

    // MARK: - Urgency colors

    func testUrgencyColorClampsOutOfRangeInputs() {
        XCTAssertEqual(urgencyColor(-1), urgencyColor(0))
        XCTAssertEqual(urgencyColor(2), urgencyColor(1))
    }

    func testPaceUrgencyColorBands() {
        // safe → secondary
        XCTAssertEqual(paceUrgencyColor(proj: 5, hoursToReset: 4), .secondary)
        // close (≥ 0.8×) → urgencyColor(0.7)
        XCTAssertEqual(paceUrgencyColor(proj: 3.5, hoursToReset: 4), urgencyColor(0.7))
        // over → urgencyColor(1.0)
        XCTAssertEqual(paceUrgencyColor(proj: 2, hoursToReset: 4), urgencyColor(1.0))
        // invalid inputs → secondary
        XCTAssertEqual(paceUrgencyColor(proj: 0, hoursToReset: 4), .secondary)
        XCTAssertEqual(paceUrgencyColor(proj: 2, hoursToReset: 0), .secondary)
    }

    // MARK: - Window reset detection (backward jump)

    func testIsWindowResetFalseOnBackwardTimestampJump() {
        let prev = Date()
        XCTAssertFalse(isWindowReset(previous: prev, next: prev.addingTimeInterval(-5 * 3600), utilization: 2))
    }

    // MARK: - PaceRateUnit formatting

    func testPerHourFormatUsesOneDecimalBelowTen() {
        XCTAssertEqual(PaceRateUnit.perHour.format(9.5), "9.5%/hr")
    }

    func testPerHourFormatRoundsToIntegerAtTenOrMore() {
        XCTAssertEqual(PaceRateUnit.perHour.format(45.4), "45%/hr")
    }

    func testPerHourFormatShortWithPrefix() {
        XCTAssertEqual(PaceRateUnit.perHour.format(45, prefix: true, short: true), "+45%/h")
    }

    func testPerMinuteFormatBelowOne() {
        // 30 %/hr = 0.5 %/min → three decimals
        XCTAssertEqual(PaceRateUnit.perMinute.format(30), "0.500%/min")
    }

    func testPerMinuteFormatAtOneOrMore() {
        // 90 %/hr = 1.5 %/min → two decimals
        XCTAssertEqual(PaceRateUnit.perMinute.format(90), "1.50%/min")
    }

    func testPerSecondFormat() {
        // 36 %/hr = 0.01 %/s
        XCTAssertEqual(PaceRateUnit.perSecond.format(36), "0.0100%/s")
    }

    // MARK: - resetTimeText

    private func gmtCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        return cal
    }

    /// ICU inserts a narrow no-break space before AM/PM on recent OSes; normalize for comparison.
    private func normalizedTime(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ")
         .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private let enUS = Locale(identifier: "en_US")

    func testResetTimeTextSameDay12Hour() {
        let cal = gmtCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 17, minute: 30))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: false, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "5:30 PM")
    }

    func testResetTimeTextSameDay24Hour() {
        let cal = gmtCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 17, minute: 30))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: true, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "17:30")
    }

    func testResetTimeTextNextDayAddsWeekday() {
        let cal = gmtCalendar()
        // 2026-07-01 is a Wednesday; reset lands Thursday 2026-07-02.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 23, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 17, minute: 30))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: false, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "Thu 5:30 PM")
    }

    func testResetTimeTextSixDaysOutAddsWeekday24Hour() {
        let cal = gmtCalendar()
        // Reset lands Tuesday 2026-07-07.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9, minute: 5))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: true, calendar: cal, locale: enUS)
        // ICU zero-pads the hour in 24-hour mode ("09:05", digital-clock style).
        XCTAssertEqual(normalizedTime(text), "Tue 09:05")
    }

    func testResetTimeTextWithDateAddsMonthDay24Hour() {
        let cal = gmtCalendar()
        // 7-day-style horizon: reset lands Tuesday 2026-07-07.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9, minute: 5))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: true, includeDate: true, calendar: cal, locale: enUS)
        // ICU joins a full date and time with a locale connector ("at" in English).
        XCTAssertEqual(normalizedTime(text), "Tue, Jul 7 at 09:05")
    }

    func testResetTimeTextWithDateAddsMonthDay12Hour() {
        let cal = gmtCalendar()
        // Reset lands Thursday 2026-07-02, the day after `now`.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 23, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 17, minute: 30))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: false, includeDate: true, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "Thu, Jul 2 at 5:30 PM")
    }

    func testResetTimeTextWithDateSameDayShowsTimeOnly() {
        let cal = gmtCalendar()
        // A 7-day window resetting today: the countdown already covers it — no date.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 17, minute: 30))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: true, includeDate: true, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "17:30")
    }

    func testPrefers24HourClockByLocale() {
        XCTAssertFalse(prefers24HourClock(Locale(identifier: "en_US")))  // h12
        XCTAssertTrue(prefers24HourClock(Locale(identifier: "de_DE")))   // h23
        XCTAssertTrue(prefers24HourClock(Locale(identifier: "fr_FR")))   // h23
    }

    func testPinnedHourCycleLocaleOverridesBase() {
        XCTAssertEqual(pinnedHourCycleLocale(use24Hour: true, base: Locale(identifier: "en_US")).hourCycle,
                       .zeroToTwentyThree)
        XCTAssertEqual(pinnedHourCycleLocale(use24Hour: false, base: Locale(identifier: "de_DE")).hourCycle,
                       .oneToTwelve)
    }
}

/// Fixture-based decoding tests against captured shapes of the unofficial claude.ai API.
final class APIFixtureTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - UsageResponse

    func testUsageResponseDecodesFullPayload() throws {
        let json = """
        {
          "five_hour": {"utilization": 42.5, "resets_at": "2026-06-09T18:00:00.000Z"},
          "seven_day": {"utilization": 80, "resets_at": "2026-06-12T10:00:00Z"},
          "seven_day_opus": {"utilization": 12, "resets_at": null},
          "seven_day_sonnet": {"utilization": 30, "resets_at": "2026-06-12T10:00:00Z"},
          "extra_usage": {"is_enabled": true, "monthly_limit": 50, "used_credits": 12.5, "utilization": 25}
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.fiveHour?.utilization, 42.5)
        XCTAssertNotNil(r.fiveHour?.resetsAtDate)
        XCTAssertEqual(r.sevenDay?.utilization, 80)
        XCTAssertEqual(r.sevenDayOpus?.utilization, 12)
        XCTAssertNil(r.sevenDayOpus?.resetsAtDate)
        XCTAssertEqual(r.sevenDaySonnet?.utilization, 30)
        XCTAssertEqual(r.extraUsage?.isEnabled, true)
        XCTAssertEqual(r.extraUsage?.usedCredits, 12.5)
    }

    func testUsageResponseToleratesNullResetsAtAfterReset() throws {
        let json = """
        {"five_hour": {"utilization": 0.5, "resets_at": null}}
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.fiveHour?.utilization, 0.5)
        XCTAssertNil(r.fiveHour?.resetsAtDate)
        XCTAssertNil(r.sevenDay)
    }

    func testUsageResponseIgnoresUnknownFutureFields() throws {
        let json = """
        {
          "five_hour": {"utilization": 10, "resets_at": "2026-06-09T18:00:00Z", "new_field": 1},
          "brand_new_window": {"utilization": 5},
          "some_flag": true
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.fiveHour?.utilization, 10)
    }

    func testUsageResponseSurvivesMalformedUnusedWindow() throws {
        // A malformed sub-window (null utilization) must not poison the whole response.
        let json = """
        {
          "five_hour": {"utilization": 42, "resets_at": "2026-06-09T18:00:00Z"},
          "seven_day": {"utilization": 80, "resets_at": "2026-06-12T10:00:00Z"},
          "seven_day_opus": {"utilization": null, "resets_at": null}
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.fiveHour?.utilization, 42)
        XCTAssertEqual(r.sevenDay?.utilization, 80)
        XCTAssertNil(r.sevenDayOpus)
    }

    func testUsageResponseSurvivesWindowOfWrongType() throws {
        let json = """
        {
          "five_hour": {"utilization": 42, "resets_at": "2026-06-09T18:00:00Z"},
          "seven_day_sonnet": "unexpected-string"
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.fiveHour?.utilization, 42)
        XCTAssertNil(r.sevenDaySonnet)
    }

    // MARK: - Limits array (model-scoped windows)

    func testUsageResponseDecodesScopedModelLimits() throws {
        // Mirrors the live payload shape: the Fable-era API reports per-model usage in the
        // `limits` array (kind == "weekly_scoped") instead of the legacy seven_day_* fields.
        let json = """
        {
          "five_hour": {"utilization": 3, "resets_at": "2026-07-11T14:49:59.540253+00:00"},
          "seven_day": {"utilization": 0, "resets_at": "2026-07-16T20:59:59.540280+00:00"},
          "seven_day_sonnet": null,
          "limits": [
            {"kind": "session", "group": "session", "percent": 3, "severity": "normal",
             "resets_at": "2026-07-11T14:49:59.732320+00:00", "scope": null, "is_active": true},
            {"kind": "weekly_all", "group": "weekly", "percent": 0, "severity": "normal",
             "resets_at": "2026-07-16T20:59:59.732344+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 1, "severity": "normal",
             "resets_at": "2026-07-16T20:59:59.732614+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
          ]
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.limits?.count, 3)
        let scoped = r.scopedModelWindows
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.label, "Fable")
        XCTAssertEqual(scoped.first?.paceKey, "scoped.Fable")
        XCTAssertEqual(scoped.first?.window.utilization, 1)
        XCTAssertNotNil(scoped.first?.window.resetsAtDate)
    }

    func testScopedModelWindowsSkipEntriesWithoutModelOrPercent() throws {
        let json = """
        {
          "limits": [
            {"kind": "weekly_scoped", "percent": 5, "scope": {"model": null}},
            {"kind": "weekly_scoped", "percent": null, "scope": {"model": {"id": null, "display_name": "Fable"}}},
            {"kind": "session", "percent": 3, "scope": null}
          ]
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.limits?.count, 3)
        XCTAssertTrue(r.scopedModelWindows.isEmpty)
    }

    func testScopedModelWindowsOmitDuplicateOfLegacySonnetWindow() throws {
        // If the API ever ships both the legacy seven_day_sonnet window and a scoped
        // "Sonnet" limit, only the legacy row should render — no duplicate bars.
        let json = """
        {
          "seven_day_sonnet": {"utilization": 30, "resets_at": "2026-07-16T21:00:00Z"},
          "limits": [
            {"kind": "weekly_scoped", "percent": 30, "resets_at": "2026-07-16T21:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Sonnet"}}},
            {"kind": "weekly_scoped", "percent": 1, "resets_at": "2026-07-16T21:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Fable"}}}
          ]
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.scopedModelWindows.map(\.label), ["Fable"])
    }

    func testLimitsDecodeIsPerElementFailSoft() throws {
        // One malformed entry must not wipe the whole array — the Fable row would
        // silently disappear otherwise.
        let json = """
        {
          "limits": [
            {"kind": 42},
            {"kind": "weekly_scoped", "percent": 1, "resets_at": "2026-07-16T21:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Fable"}}}
          ]
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.scopedModelWindows.map(\.label), ["Fable"])
    }

    func testScopedModelWindowsDedupeDuplicateLabels() throws {
        // The scope object also carries a `surface` axis, so two weekly_scoped entries
        // for the same model are plausible. Keep the max-percent one — a duplicate label
        // would collide on ForEach identity and interleave two series into one pace bucket.
        let json = """
        {
          "limits": [
            {"kind": "weekly_scoped", "percent": 5, "resets_at": "2026-07-16T21:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": "a"}},
            {"kind": "weekly_scoped", "percent": 40, "resets_at": "2026-07-16T21:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": "b"}},
            {"kind": "weekly_scoped", "percent": 2, "resets_at": "2026-07-16T21:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Haiku"}}}
          ]
        }
        """
        let r = try decode(UsageResponse.self, json)
        let scoped = r.scopedModelWindows
        XCTAssertEqual(scoped.map(\.label), ["Fable", "Haiku"])
        XCTAssertEqual(scoped.first?.window.utilization, 40)
    }

    func testScopedModelWindowsSkipEmptyDisplayName() throws {
        let json = """
        {
          "limits": [
            {"kind": "weekly_scoped", "percent": 5, "scope": {"model": {"id": null, "display_name": ""}}}
          ]
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertTrue(r.scopedModelWindows.isEmpty)
    }

    func testUsageResponseSurvivesLimitsOfWrongType() throws {
        let json = """
        {
          "five_hour": {"utilization": 42, "resets_at": "2026-06-09T18:00:00Z"},
          "limits": "unexpected-string"
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.fiveHour?.utilization, 42)
        XCTAssertNil(r.limits)
    }

    // MARK: - AccountInfo

    func testAccountInfoDecodesMembershipsAndTier() throws {
        let json = """
        {
          "full_name": "Diego V",
          "email_address": "d@example.com",
          "memberships": [
            {"organization": {
              "uuid": "abc", "name": "Personal",
              "capabilities": ["chat", "claude_max"],
              "rate_limit_tier": "default_claude_max_5x"
            }}
          ]
        }
        """
        let info = try decode(AccountInfo.self, json)
        XCTAssertEqual(info.displayName, "Diego V")
        XCTAssertEqual(info.emailAddress, "d@example.com")
        XCTAssertEqual(info.subscriptionLabel, "Max 5×")
    }

    func testAccountInfoDerivesTeamLabelFromRavenCapability() throws {
        // Team/Enterprise orgs report the "raven" capability with raven_type
        // distinguishing the plan — mirrors a live Team-account payload.
        let json = """
        {
          "email_address": "d@company.com",
          "memberships": [
            {"organization": {
              "uuid": "abc", "name": "Trust Technologies",
              "capabilities": ["raven", "chat"],
              "rate_limit_tier": "default_raven",
              "raven_type": "team"
            }}
          ]
        }
        """
        let info = try decode(AccountInfo.self, json)
        XCTAssertEqual(info.subscriptionLabel, "Team")
    }

    func testAccountInfoDerivesEnterpriseLabelFromRavenType() throws {
        let json = """
        {
          "email_address": "d@company.com",
          "memberships": [
            {"organization": {
              "capabilities": ["raven", "chat"],
              "rate_limit_tier": "default_raven",
              "raven_type": "enterprise"
            }}
          ]
        }
        """
        let info = try decode(AccountInfo.self, json)
        XCTAssertEqual(info.subscriptionLabel, "Enterprise")
    }

    func testAccountInfoRavenWithoutTypeDefaultsToTeam() throws {
        let json = """
        {
          "email_address": "d@company.com",
          "memberships": [
            {"organization": {"capabilities": ["raven", "chat"], "rate_limit_tier": "default_raven"}}
          ]
        }
        """
        let info = try decode(AccountInfo.self, json)
        XCTAssertEqual(info.subscriptionLabel, "Team")
    }

    func testAccountInfoDecodesWithoutMemberships() throws {
        let json = """
        {"email_address": "d@example.com"}
        """
        let info = try decode(AccountInfo.self, json)
        XCTAssertEqual(info.displayName, "d@example.com")
        XCTAssertNil(info.subscriptionLabel)
    }

    // MARK: - Account backward compatibility

    func testAccountDecodesLegacyRosterWithoutOptionalFields() throws {
        // Shape persisted by versions before email/subscriptionLabel/orgName existed.
        // JSONEncoder default date strategy = seconds since reference date.
        let json = """
        [{
          "id": "11111111-2222-3333-4444-555555555555",
          "label": "Claude account",
          "dataStoreIdentifier": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "addedAt": 700000000.0
        }]
        """
        let accounts = try decode([Account].self, json)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.label, "Claude account")
        XCTAssertNil(accounts.first?.email)
        XCTAssertNil(accounts.first?.subscriptionLabel)
        XCTAssertNil(accounts.first?.orgName)
    }

    func testAccountRoundTripsThroughJSON() throws {
        let acct = Account(label: "Work", email: "w@x.com", subscriptionLabel: "Max 5×", orgName: "Org")
        let data = try JSONEncoder().encode([acct])
        let decoded = try JSONDecoder().decode([Account].self, from: data)
        XCTAssertEqual(decoded, [acct])
    }

    // MARK: - AccountStore round-trips

    private var suite: UserDefaults!
    private let suiteName = "com.claudetracker.tests.accountstore"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAccountStoreRoundTripsRoster() {
        let accounts = [Account(label: "One"), Account(label: "Two", email: "two@x.com")]
        AccountStore.saveAccounts(accounts, to: suite)
        XCTAssertEqual(AccountStore.loadAccounts(from: suite), accounts)
    }

    func testAccountStoreLoadsEmptyRosterWhenUnset() {
        XCTAssertEqual(AccountStore.loadAccounts(from: suite), [])
    }

    func testAccountStoreRoundTripsActiveID() {
        let id = UUID()
        AccountStore.saveActiveID(id, to: suite)
        XCTAssertEqual(AccountStore.loadActiveID(from: suite), id)
        AccountStore.saveActiveID(nil, to: suite)
        XCTAssertNil(AccountStore.loadActiveID(from: suite))
    }

    func testAccountStoreIgnoresGarbageActiveID() {
        suite.set("not-a-uuid", forKey: AccountStore.activeAccountIDKey)
        XCTAssertNil(AccountStore.loadActiveID(from: suite))
    }

    // MARK: - GitHub release parsing

    func testParseReleasesFindsNewerVersionWithZipAsset() {
        let json = """
        [
          {"tag_name": "v9.9.9",
           "html_url": "https://github.com/x/y/releases/tag/v9.9.9",
           "published_at": "2026-06-01T00:00:00Z",
           "assets": [
             {"name": "ClaudeTracker.dmg", "browser_download_url": "https://example.com/ClaudeTracker.dmg"},
             {"name": "ClaudeTracker.zip", "browser_download_url": "https://example.com/ClaudeTracker.zip"}
           ]},
          {"tag_name": "v1.0.0",
           "html_url": "https://github.com/x/y/releases/tag/v1.0.0",
           "published_at": "2026-05-01T00:00:00Z",
           "assets": []}
        ]
        """
        let (update, dates) = parseGitHubReleases(Data(json.utf8), currentVersion: "1.20.0")
        XCTAssertEqual(update?.version, "9.9.9")
        XCTAssertEqual(update?.downloadURL?.absoluteString, "https://example.com/ClaudeTracker.zip")
        XCTAssertEqual(update?.releaseURL.absoluteString, "https://github.com/x/y/releases/tag/v9.9.9")
        XCTAssertEqual(dates.count, 2)
    }

    func testParseReleasesReturnsNilWhenCurrentIsNewest() {
        let json = """
        [{"tag_name": "v1.0.0", "html_url": "https://github.com/x/y/releases/tag/v1.0.0",
          "published_at": "2026-05-01T00:00:00Z", "assets": []}]
        """
        let (update, dates) = parseGitHubReleases(Data(json.utf8), currentVersion: "1.20.0")
        XCTAssertNil(update)
        XCTAssertEqual(dates.count, 1)
    }

    func testParseReleasesSkipsPrereleaseAndDraft() {
        // A pre-release published for testing must never reach auto-update users.
        let json = """
        [
          {"tag_name": "v9.9.9", "html_url": "https://github.com/x/y/releases/tag/v9.9.9",
           "published_at": "2026-06-01T00:00:00Z", "prerelease": true, "assets": []},
          {"tag_name": "v9.0.0", "html_url": "https://github.com/x/y/releases/tag/v9.0.0",
           "published_at": "2026-05-15T00:00:00Z", "draft": true, "assets": []},
          {"tag_name": "v2.0.0", "html_url": "https://github.com/x/y/releases/tag/v2.0.0",
           "published_at": "2026-05-01T00:00:00Z", "prerelease": false, "assets": []}
        ]
        """
        let (update, dates) = parseGitHubReleases(Data(json.utf8), currentVersion: "1.0.0")
        XCTAssertEqual(update?.version, "2.0.0")
        XCTAssertEqual(dates.count, 3)
    }

    func testParseReleasesToleratesRateLimitErrorPayload() {
        // GitHub returns a dict (not an array) on 403 rate limits.
        let json = """
        {"message": "API rate limit exceeded", "documentation_url": "https://docs.github.com"}
        """
        let (update, dates) = parseGitHubReleases(Data(json.utf8), currentVersion: "1.0.0")
        XCTAssertNil(update)
        XCTAssertEqual(dates, [])
    }

    func testParseReleasesHandlesUpdateWithoutZipAsset() {
        let json = """
        [{"tag_name": "v9.0.0", "html_url": "https://github.com/x/y/releases/tag/v9.0.0",
          "published_at": "2026-05-01T00:00:00Z", "assets": []}]
        """
        let (update, _) = parseGitHubReleases(Data(json.utf8), currentVersion: "1.0.0")
        XCTAssertEqual(update?.version, "9.0.0")
        XCTAssertNil(update?.downloadURL)
    }
}

/// Filesystem tests for the atomic install swap, using real temp directories.
final class AtomicInstallTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtomicInstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeBundle(named name: String, marker: String) throws -> URL {
        let bundle = tmpDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: bundle.appendingPathComponent("Contents/marker"))
        return bundle
    }

    func testAtomicReplaceSwapsExistingDestination() throws {
        let dest = try makeBundle(named: "Dest.app", marker: "old")
        let source = try makeBundle(named: "Source.app", marker: "new")

        try atomicReplaceItem(at: dest, with: source)

        let marker = try String(contentsOf: dest.appendingPathComponent("Contents/marker"), encoding: .utf8)
        XCTAssertEqual(marker, "new")
        // Source must be left in place (it lives in the temp extract dir, cleaned separately).
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        // No staging or backup leftovers next to the destination.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertEqual(Set(siblings), ["Dest.app", "Source.app"])
    }

    func testAtomicReplaceInstallsWhenDestinationAbsent() throws {
        let source = try makeBundle(named: "Source.app", marker: "new")
        let dest = tmpDir.appendingPathComponent("Dest.app")

        try atomicReplaceItem(at: dest, with: source)

        let marker = try String(contentsOf: dest.appendingPathComponent("Contents/marker"), encoding: .utf8)
        XCTAssertEqual(marker, "new")
    }

    func testAtomicReplaceLeavesDestinationIntactWhenSourceMissing() throws {
        let dest = try makeBundle(named: "Dest.app", marker: "old")
        let missing = tmpDir.appendingPathComponent("Missing.app")

        XCTAssertThrowsError(try atomicReplaceItem(at: dest, with: missing))

        let marker = try String(contentsOf: dest.appendingPathComponent("Contents/marker"), encoding: .utf8)
        XCTAssertEqual(marker, "old")
    }

    // MARK: - Bundle version reading

    func testBundleShortVersionReadsInfoPlist() throws {
        let bundle = tmpDir.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.3.4"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        XCTAssertEqual(bundleShortVersion(at: bundle), "2.3.4")
    }

    func testBundleShortVersionNilWhenPlistMissing() {
        XCTAssertNil(bundleShortVersion(at: tmpDir.appendingPathComponent("Nope.app")))
    }
}
