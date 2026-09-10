import XCTest
import SwiftUI
@testable import ClaudeTracker

/// Tests for the pure tuning/maintenance helpers (API fixture decoding lives in APIFixtureTests.swift).
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

    // MARK: - Chart series sample lookup

    func testDataPointRoutesBuiltInWindowsToTheirOwnFields() {
        let dp = UsageDataPoint(timestamp: Date(), fiveHour: 12, sevenDay: 34,
                                fiveHourPace: 1.5, sevenDayPace: 2.5)
        XCTAssertEqual(dp.utilization(for: "five_hour"), 12)
        XCTAssertEqual(dp.utilization(for: "seven_day"), 34)
        XCTAssertEqual(dp.paceRate(for: "five_hour"), 1.5)
        XCTAssertEqual(dp.paceRate(for: "seven_day"), 2.5)
    }

    func testDataPointRoutesModelWindowsToTheDictionaries() {
        let dp = UsageDataPoint(timestamp: Date(), fiveHour: 12, sevenDay: 34,
                                fiveHourPace: nil, sevenDayPace: nil,
                                models: ["scoped.Fable": 7, "seven_day_sonnet": 21],
                                modelPaces: ["scoped.Fable": 0.5])
        XCTAssertEqual(dp.utilization(for: "scoped.Fable"), 7)
        XCTAssertEqual(dp.utilization(for: "seven_day_sonnet"), 21)
        XCTAssertEqual(dp.paceRate(for: "scoped.Fable"), 0.5)
        // A model with no pace bucket yet must read as "no sample", not zero.
        XCTAssertNil(dp.paceRate(for: "seven_day_sonnet"))
        XCTAssertNil(dp.utilization(for: "scoped.Nonexistent"))
    }

    func testDataPointDecodesHistoryStoredBeforeModelChartsExisted() throws {
        // A literal payload in the pre-`models` format — a round-trip of the current struct
        // could not catch a regression here, since the encoder writes whatever we decode.
        let json = """
        {"timestamp": 774000000, "fiveHour": 40, "sevenDay": 55, "fiveHourPace": 3, "sevenDayPace": 1}
        """
        let dp = try JSONDecoder().decode(UsageDataPoint.self, from: Data(json.utf8))
        XCTAssertEqual(dp.fiveHour, 40)
        XCTAssertEqual(dp.sevenDay, 55)
        XCTAssertNil(dp.models)
        XCTAssertNil(dp.modelPaces)
        XCTAssertNil(dp.utilization(for: "scoped.Fable"))
    }

    // MARK: - Chart content filter persistence

    func testHiddenKeysRoundTripAndSortStably() {
        let keys: Set<String> = ["seven_day", "scoped.Fable"]
        let raw = encodeHiddenKeys(keys)
        XCTAssertEqual(raw, "scoped.Fable\nseven_day")
        XCTAssertEqual(decodeHiddenKeys(raw), keys)
        // Same set, different construction order — the stored string must not churn.
        XCTAssertEqual(encodeHiddenKeys(["scoped.Fable", "seven_day"]), raw)
    }

    func testHiddenKeysEmptyStringDecodesToEmptySet() {
        XCTAssertTrue(decodeHiddenKeys("").isEmpty)
        XCTAssertEqual(encodeHiddenKeys([]), "")
    }

    func testHiddenKeysPreserveModelNamesContainingSpacesAndCommas() {
        // Keys embed API-supplied display names; a comma separator would split them.
        let keys: Set<String> = ["scoped.Claude 3.5, Sonnet"]
        XCTAssertEqual(decodeHiddenKeys(encodeHiddenKeys(keys)), keys)
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

    func testPaceUrgencyMatchesPaceBands() {
        // The menu bar icon/badge and the popover rows must agree on pace state: a projection
        // that lands after the reset is "safe" everywhere, so its urgency must be 0, not a
        // continuous ratio that reads as near-critical at 1.2× the time to reset.
        XCTAssertEqual(paceUrgency(projectedHours: 4.8, hoursToReset: 4), 0)
        XCTAssertEqual(paceUrgency(projectedHours: 4, hoursToReset: 4), 0)
        XCTAssertEqual(paceUrgency(projectedHours: 3.5, hoursToReset: 4), 0.7)
        XCTAssertEqual(paceUrgency(projectedHours: 2, hoursToReset: 4), 1.0)
        XCTAssertEqual(paceUrgency(projectedHours: 0, hoursToReset: 4), 0)
        XCTAssertEqual(paceUrgency(projectedHours: 2, hoursToReset: 0), 0)
        // The band colors derive from the same urgency values.
        XCTAssertEqual(paceUrgencyColor(proj: 3.5, hoursToReset: 4), urgencyColor(paceUrgency(projectedHours: 3.5, hoursToReset: 4)))
    }

    func testPaceAccentColorSharedByRowAndCharts() {
        let reset = Date().addingTimeInterval(4 * 3600)
        XCTAssertEqual(paceAccentColor(projectedHours: 2, resetsAt: reset, isStale: false), urgencyColor(1.0))
        XCTAssertEqual(paceAccentColor(projectedHours: 5, resetsAt: reset, isStale: false), .secondary)
        // No projection, no reset date, or a stale window → neutral, like the row.
        XCTAssertEqual(paceAccentColor(projectedHours: nil, resetsAt: reset, isStale: false), .secondary)
        XCTAssertEqual(paceAccentColor(projectedHours: 2, resetsAt: nil, isStale: false), .secondary)
        XCTAssertEqual(paceAccentColor(projectedHours: 2, resetsAt: reset, isStale: true), .secondary)
    }

    func testUrgencyNSColorMatchesSwiftUIGradient() {
        // The menu bar (AppKit) and the popover (SwiftUI) must render the same hue for the
        // same urgency. NSColor(hue:) lives in the calibrated/generic RGB space while
        // Color(hue:) is sRGB, so identical components would still render differently.
        for t in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let appKit = urgencyNSColor(t).usingColorSpace(.sRGB)!
            let swiftUI = NSColor(urgencyColor(t)).usingColorSpace(.sRGB)!
            XCTAssertEqual(appKit.redComponent, swiftUI.redComponent, accuracy: 0.005, "t=\(t)")
            XCTAssertEqual(appKit.greenComponent, swiftUI.greenComponent, accuracy: 0.005, "t=\(t)")
            XCTAssertEqual(appKit.blueComponent, swiftUI.blueComponent, accuracy: 0.005, "t=\(t)")
        }
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
