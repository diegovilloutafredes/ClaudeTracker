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

    // MARK: - adaptivePollInterval

    private func window(_ key: String, _ utilization: Double, resetsIn: TimeInterval, now: Date,
                        scoped: Bool = false) -> TrackedWindow {
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(resetsIn))
        return TrackedWindow(key: key, title: key, window: UsageWindow(utilization: utilization, resetsAt: iso),
                             isModelScoped: scoped)
    }

    func testAdaptivePollIntervalFollowsAFillingModelLimit() {
        // A weekly model limit is often the binding one: its pace must drive the cadence
        // even while the built-in windows are calm.
        let now = Date()
        let windows = [window("five_hour", 10, resetsIn: 3 * 3600, now: now),
                       window("seven_day", 30, resetsIn: 3 * 86400, now: now),
                       window("scoped.Fable", 90, resetsIn: 3 * 86400, now: now, scoped: true)]
        let interval = adaptivePollInterval(windows: windows, projectedMinutes: { $0 == "scoped.Fable" ? 10 : nil }, now: now)
        XCTAssertEqual(interval, pollIntervalForProjectedMinutes(10))
    }

    func testAdaptivePollIntervalWithoutWindowsIsTenSeconds() {
        XCTAssertEqual(adaptivePollInterval(windows: [], projectedMinutes: { _ in nil }), 10)
    }

    // MARK: - Menu bar window choice

    private func menuBarCandidates(fiveHour: Double, sevenDay: Double, fable: Double) -> [TrackedWindow] {
        let now = Date()
        return [window("five_hour", fiveHour, resetsIn: 3600, now: now),
                window("seven_day", sevenDay, resetsIn: 86400, now: now),
                window("scoped.Fable", fable, resetsIn: 86400, now: now, scoped: true)]
    }

    func testMenuBarShowsTheChosenBuiltInWindow() {
        let windows = menuBarCandidates(fiveHour: 10, sevenDay: 30, fable: 90)
        XCTAssertEqual(menuBarTrackedWindow(for: .fiveHour, in: windows)?.key, "five_hour")
        XCTAssertEqual(menuBarTrackedWindow(for: .sevenDay, in: windows)?.key, "seven_day")
    }

    func testMenuBarHighestFollowsTheMostUtilizedWindowIncludingModelLimits() {
        XCTAssertEqual(menuBarTrackedWindow(for: .highest, in: menuBarCandidates(fiveHour: 10, sevenDay: 30, fable: 90))?.key,
                       "scoped.Fable")
        XCTAssertEqual(menuBarTrackedWindow(for: .highest, in: menuBarCandidates(fiveHour: 70, sevenDay: 30, fable: 60))?.key,
                       "five_hour")
    }

    func testMenuBarHighestPrefersDisplayOrderOnATie() {
        // A stable pick: the pace badge and VoiceOver label follow the chosen window, so a tie
        // must not flip between windows from poll to poll.
        XCTAssertEqual(menuBarTrackedWindow(for: .highest, in: menuBarCandidates(fiveHour: 40, sevenDay: 40, fable: 40))?.key,
                       "five_hour")
    }

    func testMenuBarHasNoWindowWhenTheChoiceIsMissing() {
        XCTAssertNil(menuBarTrackedWindow(for: .highest, in: []))
        // Team orgs drop an idle `five_hour`.
        XCTAssertNil(menuBarTrackedWindow(for: .fiveHour, in: Array(menuBarCandidates(fiveHour: 0, sevenDay: 30, fable: 5).dropFirst())))
    }

    func testMenuBarDisplayKeepsThePersistedWindowValues() {
        // Stored under the same key as the old MenuBarWindow setting: existing choices must load.
        XCTAssertEqual(MenuBarDisplay(rawValue: MenuBarWindow.fiveHour.rawValue), .fiveHour)
        XCTAssertEqual(MenuBarDisplay(rawValue: MenuBarWindow.sevenDay.rawValue), .sevenDay)
    }

    // MARK: - Poll log throttle

    func testPollLogSkipsARepeatedLineUntilTheHeartbeat() {
        let now = Date()
        let line = "poll: next in 10.0s (base=10.0s util=13%)"
        XCTAssertTrue(shouldLogPoll(line, last: nil, now: now))
        XCTAssertFalse(shouldLogPoll(line, last: (line, now.addingTimeInterval(-60)), now: now))
        XCTAssertTrue(shouldLogPoll(line, last: (line, now.addingTimeInterval(-600)), now: now))
    }

    func testPollLogKeepsEveryChange() {
        let now = Date()
        XCTAssertTrue(shouldLogPoll("poll: next in 5.0s (base=5.0s util=81%)",
                                    last: ("poll: next in 8.0s (base=8.0s util=79%)", now.addingTimeInterval(-3)), now: now))
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

    // MARK: - Chart downsampling

    /// 30 days of 5-minute samples: a sawtooth that climbs to a peak and drops at each reset.
    private func monthOfSamples(end: Date) -> [(Date, Double)] {
        (0..<8640).map { i -> (Date, Double) in
            let time = end.addingTimeInterval(-Double(8639 - i) * 300)
            let value = Double(i % 2016) / 2016 * 97
            return (time, i == 5000 ? value + 3 : value)
        }
    }

    func testDownsampleCapsTheMarksAChartDraws() {
        let end = Date()
        let pairs = monthOfSamples(end: end)
        let plotted = downsample(pairs, buckets: 150, over: pairs[0].0...end)
        XCTAssertLessThanOrEqual(plotted.count, 2 * 150 + 2)
        XCTAssertEqual(plotted.map { $0.0 }, plotted.map { $0.0 }.sorted())
    }

    func testDownsampleKeepsPeaksDropsAndEndpoints() {
        let end = Date()
        let pairs = monthOfSamples(end: end)
        let plotted = downsample(pairs, buckets: 150, over: pairs[0].0...end)
        XCTAssertEqual(plotted.map { $0.1 }.max(), pairs.map { $0.1 }.max())
        XCTAssertEqual(plotted.map { $0.1 }.min(), pairs.map { $0.1 }.min())
        XCTAssertEqual(plotted.first?.0, pairs.first?.0)
        XCTAssertEqual(plotted.last?.0, pairs.last?.0)
    }

    func testDownsampleLeavesShortSeriesUntouched() {
        let end = Date()
        let pairs = (0..<60).map { (end.addingTimeInterval(-Double(59 - $0) * 300), Double($0)) }
        let plotted = downsample(pairs, buckets: 150, over: pairs[0].0...end)
        XCTAssertEqual(plotted.map { $0.0 }, pairs.map { $0.0 })
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

    // MARK: - Pace alert state machine

    func testPaceAlertFiresOncePerConcerningEpisode() {
        let first = paceAlertStep(watched: true, warned: false, projectedMinutes: 20, threshold: 30)
        XCTAssertEqual(first, PaceAlertStep(fire: true, warned: true))
        let second = paceAlertStep(watched: true, warned: true, projectedMinutes: 15, threshold: 30)
        XCTAssertEqual(second, PaceAlertStep(warned: true))
    }

    func testPaceAlertDismissesButStaysWarnedInsideTheHysteresisBand() {
        // 35 min clears the 30-min threshold but not 1.25× (37.5): re-arming here would
        // re-fire toast and sound every few polls as the regression jitters.
        XCTAssertEqual(paceAlertStep(watched: true, warned: true, projectedMinutes: 35, threshold: 30),
                       PaceAlertStep(dismiss: true, warned: true))
    }

    func testPaceAlertRearmsPastTheHysteresisBandOrWhenPaceVanishes() {
        XCTAssertEqual(paceAlertStep(watched: true, warned: true, projectedMinutes: 40, threshold: 30),
                       PaceAlertStep(dismiss: true, warned: false))
        XCTAssertEqual(paceAlertStep(watched: true, warned: true, projectedMinutes: nil, threshold: 30),
                       PaceAlertStep(dismiss: true, warned: false))
    }

    func testPaceAlertClearsAnUnwatchedWindow() {
        // Also how a window that left the response is cleared, so it can warn if it returns.
        XCTAssertEqual(paceAlertStep(watched: false, warned: true, projectedMinutes: 10, threshold: 30),
                       PaceAlertStep(dismiss: true, warned: false))
    }

    func testPaceAlertStaysQuietBelowTheThreshold() {
        XCTAssertEqual(paceAlertStep(watched: true, warned: false, projectedMinutes: 35, threshold: 30),
                       PaceAlertStep(warned: false))
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

    func testContrastRatioSpansBlackOnWhite() {
        XCTAssertEqual(contrastRatio(.black, .white), 21, accuracy: 0.01)
        XCTAssertEqual(contrastRatio(.white, .white), 1, accuracy: 0.01)
    }

    func testUrgencyTextColorIsLegibleOnBothPopoverBackgrounds() {
        // The raw gradient is 1.2–2.4:1 on the light popover from green to orange, and
        // red is ~3:1 on the dark one; text needs WCAG AA (4.5:1) across the whole range.
        for i in 0...20 {
            let t = Double(i) / 20
            for isDark in [false, true] {
                let ratio = contrastRatio(urgencyTextNSColor(t, isDark: isDark), popoverBackground(isDark: isDark))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "t=\(t) dark=\(isDark)")
            }
        }
    }

    func testUrgencyTextColorKeepsTheGradientHue() {
        for t in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let base = urgencyNSColor(t).usingColorSpace(.sRGB)!
            for isDark in [false, true] {
                let text = urgencyTextNSColor(t, isDark: isDark).usingColorSpace(.sRGB)!
                XCTAssertEqual(text.hueComponent, base.hueComponent, accuracy: 0.01, "t=\(t) dark=\(isDark)")
            }
        }
    }

    func testPaceTextColorsUseTheLegibleVariant() {
        let reset = Date().addingTimeInterval(4 * 3600)
        XCTAssertEqual(paceUrgencyColor(proj: 3.5, hoursToReset: 4, forTextIn: .light), urgencyTextColor(0.7, isDark: false))
        XCTAssertEqual(paceAccentColor(projectedHours: 2, resetsAt: reset, isStale: false, forTextIn: .dark),
                       urgencyTextColor(1.0, isDark: true))
        // A safe pace stays neutral as text too.
        XCTAssertEqual(paceUrgencyColor(proj: 5, hoursToReset: 4, forTextIn: .light), .secondary)
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

    // MARK: - detectResets

    private func tracked(_ key: String, _ utilization: Double, _ resetsAt: Date?) -> TrackedWindow {
        let iso = resetsAt.map { ISO8601DateFormatter().string(from: $0) }
        return TrackedWindow(key: key, title: key, window: UsageWindow(utilization: utilization, resetsAt: iso),
                             isModelScoped: false)
    }

    func testDetectResetsFiresWhenResetsAtGoesNullAfterStoredResetPassed() {
        let now = Date()
        let stored = ["five_hour": now.addingTimeInterval(-30)]
        let result = detectResets(stored: stored, windows: [tracked("five_hour", 0, nil)], now: now)
        XCTAssertEqual(result.reset, ["five_hour"])
        // Dropped, so the next window's first date reads as a baseline, not a second reset.
        XCTAssertNil(result.stored["five_hour"])
    }

    func testDetectResetsWaitsWhileNullResetsAtPrecedesStoredReset() {
        let now = Date()
        let reset = now.addingTimeInterval(600)
        let result = detectResets(stored: ["five_hour": reset], windows: [tracked("five_hour", 0, nil)], now: now)
        XCTAssertEqual(result.reset, [])
        XCTAssertEqual(result.stored["five_hour"], reset)
    }

    func testDetectResetsIgnoresNullResetsAtWhileUtilizationIsHigh() {
        let now = Date()
        let reset = now.addingTimeInterval(-30)
        let result = detectResets(stored: ["five_hour": reset], windows: [tracked("five_hour", 40, nil)], now: now)
        XCTAssertEqual(result.reset, [])
        XCTAssertEqual(result.stored["five_hour"], reset)
    }

    func testDetectResetsBaselinesTheNextWindowAfterANullReset() {
        let now = Date()
        let first = detectResets(stored: ["five_hour": now.addingTimeInterval(-30)],
                                 windows: [tracked("five_hour", 0, nil)], now: now)
        let nextReset = now.addingTimeInterval(5 * 3600)
        let second = detectResets(stored: first.stored, windows: [tracked("five_hour", 1, nextReset)], now: now)
        XCTAssertEqual(second.reset, [])
        XCTAssertEqual(second.stored["five_hour"]?.timeIntervalSince1970 ?? 0, nextReset.timeIntervalSince1970, accuracy: 1)
    }

    func testDetectResetsFiresWhenAWindowVanishesAfterItsReset() {
        // Team orgs drop an idle `five_hour` from the response altogether.
        let now = Date()
        let result = detectResets(stored: ["five_hour": now.addingTimeInterval(-30)], windows: [], now: now)
        XCTAssertEqual(result.reset, ["five_hour"])
        XCTAssertNil(result.stored["five_hour"])
    }

    func testDetectResetsKeepsAVanishedWindowUntilItsResetPasses() {
        let now = Date()
        let reset = now.addingTimeInterval(600)
        let result = detectResets(stored: ["five_hour": reset], windows: [], now: now)
        XCTAssertEqual(result.reset, [])
        XCTAssertEqual(result.stored["five_hour"], reset)
    }

    func testDetectResetsKeepsTheForwardJumpRule() {
        let now = Date()
        let old = now.addingTimeInterval(-30)
        let result = detectResets(stored: ["seven_day": old],
                                  windows: [tracked("seven_day", 1, now.addingTimeInterval(7 * 86400))], now: now)
        XCTAssertEqual(result.reset, ["seven_day"])
        XCTAssertNotNil(result.stored["seven_day"])
    }

    func testVanishedWindowIdentityMatchesTheLiveWindow() {
        // A window can leave the response a poll or more before its reset passes, so its
        // reset toast can't rely on the previous response for a title.
        let fiveHour = TrackedWindow(vanishedKey: "five_hour")
        XCTAssertEqual(fiveHour.title, MenuBarWindow.fiveHour.label)
        XCTAssertFalse(fiveHour.isModelScoped)
        let fable = TrackedWindow(vanishedKey: "scoped.Fable")
        XCTAssertEqual(fable.title, String(format: String(localized: "7-Day %@"), "Fable"))
        XCTAssertTrue(fable.isModelScoped)
        XCTAssertEqual(TrackedWindow(vanishedKey: "seven_day_sonnet").title, String(localized: "7-Day Sonnet"))
    }

    func testDetectResetsBaselinesWindowsWithoutAStoredReset() {
        let now = Date()
        let result = detectResets(stored: [:], windows: [tracked("five_hour", 0, now.addingTimeInterval(3600)),
                                                         tracked("seven_day", 0, nil)], now: now)
        XCTAssertEqual(result.reset, [])
        XCTAssertNotNil(result.stored["five_hour"])
        XCTAssertNil(result.stored["seven_day"])
    }

    // MARK: - PaceRateUnit formatting

    /// Pace chart y-axis labels carry no unit (the stats row above states it), so they are
    /// as narrow as the utilization charts' and the stacked plots line up.
    func testPaceAxisLabelIsTheCompactConvertedNumber() {
        XCTAssertEqual(PaceRateUnit.perHour.axisLabel(26), "26")
        XCTAssertEqual(PaceRateUnit.perMinute.axisLabel(25.02), "0.42")
        XCTAssertEqual(PaceRateUnit.perSecond.axisLabel(26), "0.0072")
        XCTAssertEqual(PaceRateUnit.perMinute.axisLabel(0), "0")
    }

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

    // MARK: - Pace outlook wording

    /// resets_at lands a fraction of a second either side of its 10-minute mark from poll to
    /// poll; the outlook sentence used to switch phrasing between polls because of it.
    func testOutlookMessageIndexIsStableAcrossResetJitter() {
        let mark = Date(timeIntervalSince1970: 1_790_197_200) // 2026-09-24 21:00 UTC, a 10-minute mark
        XCTAssertEqual(outlookMessageIndex(reset: mark.addingTimeInterval(-0.454), count: 5),
                       outlookMessageIndex(reset: mark.addingTimeInterval(0.108), count: 5))
        // …while still varying between windows (seconds-based picks were always index 0).
        XCTAssertNotEqual(outlookMessageIndex(reset: mark, count: 5),
                          outlookMessageIndex(reset: mark.addingTimeInterval(600), count: 5))
    }

    /// The "over" line must never claim more lead than there is: a 1.53 h lead rounded to
    /// "~2h" sat directly under "Resets in 1 hr, 34 min".
    func testEarlyFillLeadNeverOverstatesTheLead() {
        let lead = earlyFillLead(hours: 1.53)
        XCTAssertEqual(lead.hours, 1)
        XCTAssertEqual(lead.minutes, 31)
        XCTAssertEqual(earlyFillLead(hours: 2).hours, 2)
        XCTAssertEqual(earlyFillLead(hours: 2).minutes, 0)
        XCTAssertEqual(earlyFillLead(hours: 0.001).minutes, 1) // never "~0m"
    }

    // MARK: - Orphaned data stores

    /// The launch sweep deletes WebKit stores whose account is gone (a removal that raced a
    /// live web view, a cancelled add) and must never touch one the roster owns — including
    /// a pending placeholder's, whose login may still be in progress.
    func testOrphanedDataStoreIDsKeepsEveryStoreTheRosterOwns() {
        let owned = Account(label: "Work")
        let pending = Account(label: "Claude account", pending: true)
        let orphan = UUID()
        let existing = [owned.dataStoreIdentifier, orphan, pending.dataStoreIdentifier]
        XCTAssertEqual(orphanedDataStoreIDs(existing: existing, roster: [owned, pending]), [orphan])
        XCTAssertEqual(orphanedDataStoreIDs(existing: [], roster: [owned]), [])
    }

    // MARK: - FetchFailure

    /// A Cloudflare-challenged fetch must never read as an auth failure: two of them in a
    /// row would mark a valid session expired. The tokens arrive as the thrown error's
    /// message (see `jsExceptionMessage`), so classification is by substring.
    func testFetchFailureClassifiesTheThrownToken() {
        XCTAssertEqual(FetchFailure(message: "Error: CF_CHALLENGE"), .challenge)
        XCTAssertEqual(FetchFailure(message: "Error: HTTP_401"), .unauthorized)
        XCTAssertEqual(FetchFailure(message: "Error: HTTP_403"), .unauthorized)
        XCTAssertEqual(FetchFailure(message: "Error: HTTP_429"), .rateLimited)
        XCTAssertEqual(FetchFailure(message: "Error: HTTP_404"), .notFound)
        XCTAssertEqual(FetchFailure(message: "Error: HTTP_500"), .http)
        XCTAssertEqual(FetchFailure(message: "TypeError: Load failed"), .network)
        // A message wrapped in other text still classifies (the description fallback).
        XCTAssertEqual(FetchFailure(message: "A JavaScript exception occurred: Error: HTTP_401"), .unauthorized)
    }

    /// WebKit's error text is only "A JavaScript exception occurred"; the thrown message
    /// travels in userInfo. Shape captured from `callAsyncJavaScript` on macOS 27.
    func testJSExceptionMessageReadsTheThrownErrorFromUserInfo() {
        let error = NSError(domain: "WKErrorDomain", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "A JavaScript exception occurred",
            "WKJavaScriptExceptionMessage": "Error: HTTP_401",
        ])
        XCTAssertEqual(FetchFailure(message: jsExceptionMessage(error)), .unauthorized)
    }

    func testJSExceptionMessageFallsBackToTheDescription() {
        let error = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "offline"])
        XCTAssertEqual(jsExceptionMessage(error), "offline")
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

    func testResetTimeTextRoundsJitteredResetToNearestMinute() {
        let cal = gmtCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let boundary = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 18, minute: 0))!
        // Live resets_at lands a fraction of a second either side of the boundary from poll to
        // poll (20:59:59.546 vs 21:00:00.108 observed 2026-09-23); both must read as the same minute.
        let early = resetTimeText(reset: boundary.addingTimeInterval(-0.454), now: now, use24Hour: true, calendar: cal, locale: enUS)
        let late = resetTimeText(reset: boundary.addingTimeInterval(0.108), now: now, use24Hour: true, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(early), "18:00")
        XCTAssertEqual(normalizedTime(late), "18:00")
    }

    func testResetTimeTextRoundsBeforeTheSameDayCheck() {
        let cal = gmtCalendar()
        // A reset jittered to just before midnight is tomorrow's 00:00 — it needs the weekday.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let midnight = cal.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 0, minute: 0))!
        let text = resetTimeText(reset: midnight.addingTimeInterval(-0.4), now: now, use24Hour: true, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "Thu 00:00")
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

    // MARK: - Install destination

    func testInstallDestinationReplacesTheRunningBundleWhenItsFolderIsWritable() throws {
        let running = try makeBundle(named: "Running.app", marker: "old")
        let fallback = URL(fileURLWithPath: "/Applications/ClaudeTracker.app")
        XCTAssertEqual(installDestination(runningBundle: running, fallback: fallback), running)
    }

    func testInstallDestinationFallsBackWhenTheRunningBundlesFolderIsReadOnly() throws {
        // A translocated or disk-image launch runs from a read-only folder.
        let folder = tmpDir.appendingPathComponent("ReadOnly")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let running = folder.appendingPathComponent("Running.app")
        try FileManager.default.createDirectory(at: running, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let fallback = URL(fileURLWithPath: "/Applications/ClaudeTracker.app")
        XCTAssertEqual(installDestination(runningBundle: running, fallback: fallback), fallback)
    }

    // MARK: - Auto-install retry cap

    func testInstallFailureCountAccumulatesForTheSameVersion() {
        XCTAssertEqual(installFailureCount(version: "1.30.0", failedVersion: "1.30.0", previousCount: 2), 3)
    }

    func testInstallFailureCountRestartsForANewVersion() {
        XCTAssertEqual(installFailureCount(version: "1.31.0", failedVersion: "1.30.0", previousCount: 3), 1)
    }

    func testAutoInstallStopsRetryingAtTheCap() {
        XCTAssertTrue(shouldRetryAutoInstall(failures: maxAutoInstallAttempts - 1))
        XCTAssertFalse(shouldRetryAutoInstall(failures: maxAutoInstallAttempts))
    }
}
