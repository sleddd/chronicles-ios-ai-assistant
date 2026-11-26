import Foundation
import Testing
@testable import SmithCore

/// Things that once could stop the app or lose data: numbers too big for an Int,
/// an undo that took back more than it should, the newest memories left out.
@Suite struct HardeningTests {
    @Test func hugeNumbersNeverStopTheApp() throws {
        let v = try JSONValue.parse(Data(#"{"big": 1e30, "neg": -1e30, "ok": 42, "frac": 7.9}"#.utf8))
        #expect(v["big"]?.int == nil)
        #expect(v["neg"]?.int == nil)
        #expect(v["ok"]?.int == 42)
        #expect(v["frac"]?.int == 7)
        #expect(ExportParser.idString(.number(1e30)) == nil)
        #expect(ExportParser.idString(.number(12)) == "12")
    }

    @Test func aDateIsARealMonthAndDay() {
        #expect(Day.parse("2026-11-00") == nil)
        #expect(Day.parse("2026-13-01") == nil)
        #expect(Day.parse("2026-11-30")?.d == 30)
        // The habit log is left alone rather than indexed at -1
        let log: JSONValue = ["7": ["2026-11": "01"]]
        #expect(ChroniclesWriter.incrementHabit(log, habitID: 7, day: "2026-11-00", by: 1) == log)
    }

    @Test func aHugeRepeatIntervalIsClamped() {
        let rule = RepeatRule(fields: ["repeat": "daily", "repeatEvery": 1e30])
        #expect(rule?.every == 99)
        #expect(RepeatRule(fields: ["repeat": "daily", "repeatEvery": -5])?.every == 1)
    }

    @Test func undoingAHabitTakesOneCheckInOff() {
        var log: JSONValue = [:]
        log = ChroniclesWriter.incrementHabit(log, habitID: 7, day: "2026-11-03", by: 1)   // Smith's check-in
        log = ChroniclesWriter.incrementHabit(log, habitID: 9, day: "2026-11-03", by: 1)   // another, made since
        log = ChroniclesWriter.incrementHabit(log, habitID: 7, day: "2026-11-03", by: 1)   // and one in Chronicles
        let undone = ChroniclesWriter.incrementHabit(log, habitID: 7, day: "2026-11-03", by: -1)
        #expect(undone["7"]?["2026-11"]?.string == "001")
        #expect(undone["9"]?["2026-11"]?.string == "001")
    }

    @Test func theNewestFactsReachSmith() {
        var about = AboutYouStore()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<(AboutYouStore.maxInContext + 10) {
            about.facts.append(Fact(text: "Fact number \(i) here", category: .people, source: .addedByYou, confirmed: true,
                                    at: start.addingTimeInterval(Double(i) * 60)))
        }
        let text = about.contextText() ?? ""
        #expect(text.contains("Fact number \(AboutYouStore.maxInContext + 9) here"))
        #expect(!text.contains("Fact number 0 here"))
    }

    @Test func clearingEverythingClearsTheWontLearnMarkers() {
        var about = AboutYouStore()
        let f = about.remember("Sister Anna lives in Portland", category: .people)
        _ = about.delete(f.id)
        #expect(!about.dontLearn.isEmpty)
        about.clearAll()
        #expect(about.dontLearn.isEmpty)
    }
}
