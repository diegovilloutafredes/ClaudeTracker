import XCTest
import SwiftUI
@testable import ClaudeTracker

/// Verbatim /api/organizations/{id}/usage response captured 2026-09-10 (Max 5x org).
private let livePayload20260910 = """
{
  "five_hour": {
    "utilization": 4,
    "resets_at": "2026-09-10T17:30:00.444237+00:00",
    "limit_dollars": null,
    "used_dollars": null,
    "remaining_dollars": null,
    "locked_reason": null
  },
  "seven_day": {
    "utilization": 38,
    "resets_at": "2026-09-10T21:00:00.444261+00:00",
    "limit_dollars": null,
    "used_dollars": null,
    "remaining_dollars": null,
    "locked_reason": null
  },
  "seven_day_oauth_apps": null,
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "seven_day_cowork": null,
  "seven_day_omelette": null,
  "tangelo": null,
  "iguana_necktie": null,
  "omelette_promotional": null,
  "nimbus_quill": {
    "utilization": 0,
    "resets_at": null,
    "limit_dollars": null,
    "used_dollars": null,
    "remaining_dollars": null,
    "locked_reason": null
  },
  "cinder_cove": null,
  "copper_kite": null,
  "amber_ladder": null,
  "juniper_tide": null,
  "extra_usage": {
    "is_enabled": false,
    "monthly_limit": null,
    "used_credits": null,
    "utilization": null,
    "currency": null,
    "decimal_places": null,
    "disabled_reason": null,
    "user_disabled": false,
    "spend_limit_reached": false,
    "credits_ever_enabled": false,
    "daily": null,
    "weekly": null
  },
  "limits": [
    {
      "kind": "session",
      "group": "session",
      "percent": 4,
      "severity": "normal",
      "resets_at": "2026-09-10T17:30:00.444237+00:00",
      "scope": null,
      "is_active": false
    },
    {
      "kind": "weekly_all",
      "group": "weekly",
      "percent": 38,
      "severity": "normal",
      "resets_at": "2026-09-10T21:00:00.444261+00:00",
      "scope": null,
      "is_active": false
    },
    {
      "kind": "weekly_scoped",
      "group": "weekly",
      "percent": 75,
      "severity": "warning",
      "resets_at": "2026-09-10T21:00:00.444470+00:00",
      "scope": {
        "model": {
          "id": null,
          "display_name": "Fable"
        },
        "surface": null
      },
      "is_active": true
    }
  ],
  "spend": {
    "used": {
      "amount_minor": 0,
      "currency": "USD",
      "exponent": 2
    },
    "limit": null,
    "percent": 0,
    "severity": "normal",
    "enabled": false,
    "disabled_reason": null,
    "cap": null,
    "balance": null,
    "auto_reload": null,
    "disclaimer": "Usage credits cover you when you hit your plan limits. [Learn more](https://support.claude.com/articles/12429409)",
    "can_purchase_credits": true,
    "can_toggle": true
  },
  "member_dashboard_available": false,
  "seven_day_breakdown": null
}
"""

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

    func testExtraUsageDecodesDisabledState() throws {
        // Mirrors a live Team payload where usage credits ran out: is_enabled flips false
        // but disabled_reason/credits_ever_enabled say why. Decode-only — the popover
        // hides the section while is_enabled is false (a disabled-state row was tried
        // and deliberately removed as noise).
        let json = """
        {
          "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null,
                          "utilization": null, "currency": "USD", "decimal_places": 2,
                          "disabled_reason": "out_of_credits", "user_disabled": false,
                          "spend_limit_reached": false, "credits_ever_enabled": true,
                          "daily": null, "weekly": null}
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.extraUsage?.isEnabled, false)
        XCTAssertEqual(r.extraUsage?.disabledReason, "out_of_credits")
        XCTAssertEqual(r.extraUsage?.userDisabled, false)
        XCTAssertEqual(r.extraUsage?.creditsEverEnabled, true)
    }

    func testExtraUsageToleratesWrongTypedOptionalField() throws {
        // Per-field lenient decode: a shape change in a non-load-bearing field must not
        // nil the whole extraUsage (which would silently hide the section).
        let json = """
        {
          "extra_usage": {"is_enabled": true, "monthly_limit": 50, "used_credits": 12.5,
                          "utilization": 25, "disabled_reason": {"code": 7}}
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.extraUsage?.isEnabled, true)
        XCTAssertEqual(r.extraUsage?.usedCredits, 12.5)
        XCTAssertNil(r.extraUsage?.disabledReason)
    }

    func testUsageLimitToleratesWrongTypedOptionalField() throws {
        // A wrong-typed severity/is_active must degrade that field to nil, not make
        // FailableLimit drop the whole entry (losing the model's row and pace bucket).
        let json = """
        {
          "limits": [
            {"kind": "weekly_scoped", "percent": 8, "severity": 3, "is_active": "yes",
             "resets_at": "2026-08-17T21:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
          ]
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.limits?.count, 1)
        XCTAssertNil(r.limits?.first?.severity)
        XCTAssertNil(r.limits?.first?.isActive)
        XCTAssertEqual(r.scopedModelWindows.first?.label, "Fable")
    }

    // MARK: - spend / locked_reason (decode-only, logged never displayed)

    func testSpendAndLockedReasonDecodeFromLivePayloadShape() throws {
        // Shape observed live 2026-09-02 on a Max 5x org.
        let json = """
        {
          "five_hour": {"utilization": 12.0, "resets_at": "2026-09-02T12:10:00.294700+00:00",
                        "limit_dollars": null, "used_dollars": null, "remaining_dollars": null,
                        "locked_reason": null},
          "seven_day": {"utilization": 2.0, "resets_at": "2026-09-03T21:00:00.294739+00:00",
                        "locked_reason": "spend_limit_reached"},
          "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null,
                          "utilization": null, "currency": null, "decimal_places": null,
                          "disabled_reason": null, "user_disabled": false,
                          "spend_limit_reached": false, "credits_ever_enabled": false,
                          "daily": null, "weekly": null},
          "spend": {"used": {"amount_minor": 1250, "currency": "USD", "exponent": 2},
                    "limit": null, "percent": 0, "severity": "normal", "enabled": false,
                    "disabled_reason": null, "cap": null, "balance": null, "auto_reload": null,
                    "disclaimer": "Usage credits cover you when you hit your plan limits.",
                    "can_purchase_credits": true, "can_toggle": true},
          "member_dashboard_available": false
        }
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertNil(r.fiveHour?.lockedReason)
        XCTAssertEqual(r.sevenDay?.lockedReason, "spend_limit_reached")
        XCTAssertEqual(r.spend?.enabled, false)
        XCTAssertEqual(r.spend?.percent, 0)
        XCTAssertEqual(r.spend?.severity, "normal")
        XCTAssertEqual(r.spend?.used?.amountMinor, 1250)
        XCTAssertEqual(r.spend?.used?.currency, "USD")
        XCTAssertEqual(r.spend?.used?.exponent, 2)
        XCTAssertEqual(r.spend?.canPurchaseCredits, true)
    }

    func testSpendAndLockedReasonAbsentOnOlderPayloads() throws {
        let json = """
        {"five_hour": {"utilization": 5, "resets_at": null}}
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertNil(r.fiveHour?.lockedReason)
        XCTAssertNil(r.spend)
    }

    func testWrongTypedLockedReasonDoesNotDropWindow() throws {
        let json = """
        {"five_hour": {"utilization": 5, "resets_at": null, "locked_reason": {"code": 1}}}
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(r.fiveHour?.utilization, 5)
        XCTAssertNil(r.fiveHour?.lockedReason)
    }

    func testWrongTypedSpendFieldDegradesToNilNotWholeObject() throws {
        let json = """
        {"spend": {"enabled": "yes", "percent": 40, "severity": "warning", "used": 7}}
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertNotNil(r.spend)
        XCTAssertNil(r.spend?.enabled)
        XCTAssertEqual(r.spend?.percent, 40)
        XCTAssertEqual(r.spend?.severity, "warning")
        XCTAssertNil(r.spend?.used)
    }

    func testUsageDiagnosticsEmptyForQuietLivePayload() throws {
        // Disabled spend that agrees with extra_usage, normal severity, no locks → nothing to log.
        let json = """
        {
          "five_hour": {"utilization": 12, "resets_at": null, "locked_reason": null},
          "extra_usage": {"is_enabled": false},
          "spend": {"enabled": false, "percent": 0, "severity": "normal"}
        }
        """
        XCTAssertEqual(usageDiagnostics(try decode(UsageResponse.self, json)), "")
        XCTAssertEqual(usageDiagnostics(try decode(UsageResponse.self, "{}")), "")
    }

    func testUsageDiagnosticsReportsLocksSpendEnabledAndDisagreement() throws {
        let locked = """
        {"five_hour": {"utilization": 100, "resets_at": null, "locked_reason": "abuse"},
         "seven_day_sonnet": {"utilization": 1, "resets_at": null, "locked_reason": "paused"}}
        """
        XCTAssertEqual(usageDiagnostics(try decode(UsageResponse.self, locked)),
                       "five_hour.locked=abuse seven_day_sonnet.locked=paused")

        let enabled = """
        {"extra_usage": {"is_enabled": true},
         "spend": {"enabled": true, "percent": 35.5, "severity": "normal",
                   "used": {"amount_minor": 1250, "currency": "USD", "exponent": 2}}}
        """
        XCTAssertEqual(usageDiagnostics(try decode(UsageResponse.self, enabled)),
                       "spend=enabled(pct=35.5,sev=normal,used=1250 USD e2,reason=nil)")

        let disagree = """
        {"extra_usage": {"is_enabled": true},
         "spend": {"enabled": false, "severity": "normal", "disabled_reason": "out_of_credits"}}
        """
        XCTAssertEqual(usageDiagnostics(try decode(UsageResponse.self, disagree)),
                       "spend=disabled(pct=nil,sev=normal,used=nil,reason=out_of_credits) extra_usage.is_enabled=true")

        let abnormal = """
        {"spend": {"enabled": false, "severity": "exceeded"}}
        """
        XCTAssertEqual(usageDiagnostics(try decode(UsageResponse.self, abnormal)),
                       "spend=disabled(pct=nil,sev=exceeded,used=nil,reason=nil)")
    }

    // MARK: - Severity log signature

    func testAbnormalSeveritiesEmptyWhenAllNormal() throws {
        let json = """
        {"limits": [
          {"kind": "session", "percent": 4, "severity": "normal", "is_active": true},
          {"kind": "weekly_all", "percent": 4}
        ]}
        """
        let r = try decode(UsageResponse.self, json)
        XCTAssertEqual(abnormalSeverities(r.limits), "")
        XCTAssertEqual(abnormalSeverities(nil), "")
    }

    func testAbnormalSeveritiesLabelsScopedModelsAndSortsOrderIndependently() throws {
        let jsonA = """
        {"limits": [
          {"kind": "weekly_scoped", "percent": 90, "severity": "warning", "is_active": true,
           "scope": {"model": {"display_name": "Fable"}}},
          {"kind": "session", "percent": 99, "severity": "exceeded", "is_active": false}
        ]}
        """
        let jsonB = """
        {"limits": [
          {"kind": "session", "percent": 99, "severity": "exceeded", "is_active": false},
          {"kind": "weekly_scoped", "percent": 90, "severity": "warning", "is_active": true,
           "scope": {"model": {"display_name": "Fable"}}}
        ]}
        """
        let a = abnormalSeverities(try decode(UsageResponse.self, jsonA).limits)
        let b = abnormalSeverities(try decode(UsageResponse.self, jsonB).limits)
        XCTAssertEqual(a, "session=exceeded(active=false) weekly_scoped(Fable)=warning(active=true)")
        // A server-side reorder of the same entries must not read as a transition.
        XCTAssertEqual(a, b)
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
        XCTAssertEqual(r.limits?.first?.severity, "normal")
        XCTAssertEqual(r.limits?.first?.isActive, true)
        XCTAssertEqual(r.limits?.last?.isActive, false)
        let scoped = r.scopedModelWindows
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.label, "Fable")
        XCTAssertEqual(scoped.first?.paceKey, "scoped.Fable")
        XCTAssertEqual(scoped.first?.window.utilization, 1)
        XCTAssertNotNil(scoped.first?.window.resetsAtDate)
    }

    func testUsageResponseDecodesLivePayload20260910() throws {
        // Verbatim /api/organizations/{id}/usage response captured 2026-09-10 (Max 5x org).
        // First live sighting of a non-"normal" severity and of an is_active == true entry
        // sitting on the highest-percent window; also carries the unmodeled top-level keys
        // (copper_kite, seven_day_breakdown) that Codable must keep dropping silently.
        let r = try decode(UsageResponse.self, livePayload20260910)
        XCTAssertEqual(r.fiveHour?.utilization, 4)
        XCTAssertEqual(r.sevenDay?.utilization, 38)
        XCTAssertNil(r.sevenDaySonnet)
        XCTAssertEqual(r.extraUsage?.isEnabled, false)
        XCTAssertEqual(r.limits?.count, 3)
        let fable = r.scopedModelWindows
        XCTAssertEqual(fable.count, 1)
        XCTAssertEqual(fable.first?.window.utilization, 75)
        XCTAssertEqual(r.limits?.last?.severity, "warning")
        XCTAssertEqual(r.limits?.last?.isActive, true)
        XCTAssertEqual(abnormalSeverities(r.limits), "weekly_scoped(Fable)=warning(active=true)")
        XCTAssertEqual(r.spend?.enabled, false)
        XCTAssertEqual(r.spend?.canPurchaseCredits, true)
        XCTAssertEqual(usageDiagnostics(r), "")
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

    // MARK: - Tracked windows

    func testTrackedWindowsListsBuiltInsThenScopedModelsFromLivePayload() throws {
        let r = try decode(UsageResponse.self, livePayload20260910)
        let tracked = r.trackedWindows
        XCTAssertEqual(tracked.map(\.key), ["five_hour", "seven_day", "scoped.Fable"])
        XCTAssertEqual(tracked.map(\.isModelScoped), [false, false, true])
        XCTAssertEqual(tracked.map(\.isSevenDay), [false, true, true])
        XCTAssertEqual(tracked.last?.title, "7-Day Fable")
        XCTAssertEqual(tracked.last?.window.utilization, 75)
        XCTAssertEqual(tracked.first?.title, MenuBarWindow.fiveHour.label)
    }

    func testTrackedWindowsKeepsLegacySonnetAndSkipsItsScopedDuplicate() throws {
        let json = """
        {
          "seven_day": {"utilization": 10, "resets_at": "2026-07-16T21:00:00Z"},
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
        let tracked = r.trackedWindows
        // No five_hour in the payload → it is simply absent, not a placeholder.
        XCTAssertEqual(tracked.map(\.key), ["seven_day", "seven_day_sonnet", "scoped.Fable"])
        XCTAssertEqual(tracked[1].title, "7-Day Sonnet")
        XCTAssertTrue(tracked[1].isModelScoped)
        // The Charts tab's model sections come from the same list.
        XCTAssertEqual(chartSeries(for: r).map(\.key), ["five_hour", "seven_day", "seven_day_sonnet", "scoped.Fable"])
    }

    // MARK: - Charts tab series

    func testChartSeriesKeepsBuiltInWindowsWithoutAResponse() {
        // Before the first fetch (or while one is failing) the Charts tab still renders the
        // built-in windows from persisted history — dropping them would blank real data.
        let series = chartSeries(for: nil)
        XCTAssertEqual(series.map(\.key), ["five_hour", "seven_day"])
        XCTAssertTrue(series.allSatisfy { $0.window == nil })
        XCTAssertEqual(series.first?.duration, 5 * 3600)
        XCTAssertEqual(series.last?.duration, 7 * 24 * 3600)
    }

    func testChartSeriesAppendsModelWindowsInDisplayOrder() throws {
        let json = """
        {
          "five_hour": {"utilization": 3, "resets_at": "2026-07-11T14:49:59Z"},
          "seven_day": {"utilization": 10, "resets_at": "2026-07-16T20:59:59Z"},
          "seven_day_sonnet": {"utilization": 30, "resets_at": "2026-07-16T21:00:00Z"},
          "limits": [
            {"kind": "weekly_scoped", "percent": 1, "resets_at": "2026-07-16T21:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Fable"}}}
          ]
        }
        """
        let series = chartSeries(for: try decode(UsageResponse.self, json))
        XCTAssertEqual(series.map(\.key), ["five_hour", "seven_day", "seven_day_sonnet", "scoped.Fable"])
        // Every section must resolve a live window, or its forecast chart never renders.
        XCTAssertTrue(series.allSatisfy { $0.window != nil })
        XCTAssertEqual(series.last?.window?.utilization, 1)
        XCTAssertEqual(series.last?.duration, 7 * 24 * 3600)
    }

    func testChartSeriesOmitsModelWindowsTheResponseDoesNotReport() throws {
        let json = """
        {"five_hour": {"utilization": 3, "resets_at": null}, "seven_day_sonnet": null, "limits": []}
        """
        let series = chartSeries(for: try decode(UsageResponse.self, json))
        XCTAssertEqual(series.map(\.key), ["five_hour", "seven_day"])
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

    func testAccountInfoDerivesFreeLabelFromBaseTier() throws {
        // Mirrors a live free-plan payload: bare "chat" capability on the base tier.
        let json = """
        {
          "email_address": "d@example.com",
          "memberships": [
            {"organization": {"capabilities": ["chat"], "rate_limit_tier": "default_claude_ai"}}
          ]
        }
        """
        let info = try decode(AccountInfo.self, json)
        XCTAssertEqual(info.subscriptionLabel, "Free")
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
        // Legacy rows must decode with pending == nil — a non-nil default would make
        // the launch-time reclamation pass delete real signed-in accounts.
        XCTAssertNil(accounts.first?.pending)
    }

    func testAccountPendingFlagRoundTrips() throws {
        let acct = Account(label: "New", pending: true)
        let data = try JSONEncoder().encode([acct])
        let decoded = try JSONDecoder().decode([Account].self, from: data)
        XCTAssertEqual(decoded.first?.pending, true)
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
