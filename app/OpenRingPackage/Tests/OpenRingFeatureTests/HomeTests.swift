import Testing
import Foundation
@testable import OpenRingFeature

@Suite struct AskDoorTests {
    @Test func questionsAreRecognised() {
        #expect(AskDoor("did DPD come today?")?.kind == .yesNo)
        #expect(AskDoor("when did the postie come")?.kind == .when)
        #expect(AskDoor("How many times did someone ring this week?")?.kind == .howMany)
        #expect(AskDoor("DPD last week") == nil, "plain searches stay searches")
    }

    @Test func fillerWordsAreDropped() {
        #expect(AskDoor("did DPD come today?")?.searchText == "dpd today")
        let a = AskDoor("has anyone been in the garden this week?")!
        #expect(a.searchText == "garden this week" && a.peopleOnly)
    }

    @Test func answersWhenNothingMatches() {
        #expect(AskDoor("did DPD come?")!.answer([], days: 14) == "No, not that Doorstep saw in the last 14 days.")
        #expect(AskDoor("how many times did DPD come?")!.answer([], days: 14) == "None in the last 14 days.")
    }
}

@Suite struct RoutineTests {
    @Test func postieNeedsAWeekThenUsesTheLateQuarter() {
        #expect(PostieRoutine.usuallyBy([660, 670, 680]) == nil)
        #expect(PostieRoutine.usuallyBy([600, 610, 620, 630, 640, 700, 710, 720]) == 710)
    }

    @Test func fortnightlyBins() {
        let cal = Calendar.current
        let anchor = cal.date(from: DateComponents(year: 2026, month: 11, day: 16))!     // a Monday
        let bin = BinCollection(name: "Recycling", weekday: 2, fortnightly: true, anchor: anchor)
        #expect(bin.isCollected(on: anchor))
        #expect(!bin.isCollected(on: cal.date(byAdding: .day, value: 7, to: anchor)!))
        #expect(bin.isCollected(on: cal.date(byAdding: .day, value: 14, to: anchor)!))
        #expect(!bin.isCollected(on: cal.date(byAdding: .day, value: 15, to: anchor)!))
    }

    @Test func bankHolidayFeedParses() {
        let json = #"{"england-and-wales":{"division":"england-and-wales","events":[{"title":"Christmas Day","date":"2026-12-25"}]},"scotland":{"events":[{"title":"St Andrew's Day","date":"2026-11-30"}]}}"#
        #expect(BankHolidays.parse(Data(json.utf8), region: .englandWales) == ["2026-12-25": "Christmas Day"])
        #expect(BankHolidays.parse(Data(json.utf8), region: .scotland)["2026-11-30"] == "St Andrew's Day")
    }
}

@Suite struct BusyTests {
    /// Reads the real hardware state; it only has to answer without crashing.
    @Test func callDetectionRuns() {
        _ = Busy.micInUse()
        _ = Busy.cameraInUse()
    }
}
