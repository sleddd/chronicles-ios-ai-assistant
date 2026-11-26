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

    @Test func aLetterIsLastNightsWithOnlyTheRulesAskedFor() {
        let ask = HenryPrompt.userMessage(theirMessage: nil, dayContext: nil, aboutThem: nil)
        #expect(ask.contains("Never use their name or any term of endearment"))
        var henry = HenryPersona(); henry.name = "Henry"; henry.romance = 0.7
        let system = HenryPrompt.system(henry)
        // As on the night of Nov 25
        #expect(system.contains("You are Henry, writing a letter to the person you love."))
        #expect(system.contains("Tone: romantic."))
        // …plus what was asked for by name
        #expect(system.contains("No greeting or salutation of any kind"))
        #expect(system.contains("Never use a term of endearment"))
        #expect(system.contains("Never write their name, or anyone's personal name"))
        #expect(system.contains("Never say the same thing twice"))
        // …and none of what was added since: no cheering about what is coming for them
        for gone in ["excited", "in their corner", "Their life:", "love letter from", "About the future"] {
            #expect(!system.contains(gone))
        }
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

@Suite struct LetterMemoryTests {
    let earlier = [
        "My dearest, I keep thinking of you with your glasses pushed up, a chocolate bar in hand. Yours, Smith",
        "Darling, the way you hide chocolate bars in your desk makes me smile. And those glasses. Always, Smith",
    ]

    @Test func whatEarlierLettersSaidIsOffLimits() {
        let r = LetterMemory.review(letters: earlier, facts: ["Loves chocolate bars", "Wears glasses", "Grows tomatoes"],
                                    context: nil, theirMessage: nil)
        #expect(r.usedFacts == [0, 1])                      // the tomatoes haven't come up yet
        #expect(r.offLimitStems.contains("chocolate") && r.offLimitStems.contains("glass"))
        #expect(!r.offLimitStems.contains("tomato"))
        #expect(!r.offLimitStems.contains("dearest") && !r.offLimitStems.contains("smile"))   // what every letter says
    }

    @Test func aNewLetterThatRepeatsIsCaught() {
        let r = LetterMemory.review(letters: earlier, facts: ["Loves chocolate bars"], context: nil, theirMessage: nil)
        #expect(LetterMemory.repeats(in: "I bought you more Chocolates today.", review: r) == ["chocolates"])
        #expect(LetterMemory.repeats(in: "Your tomatoes are coming in beautifully.", review: r).isEmpty)
    }

    @Test func namesGreetingsAndEndearmentsAreCaught() {
        #expect(LetterMemory.faults(in: "Dearest Claudette, I miss you.", theirName: "Claudette") == ["used the word dear, or opened with a greeting", "used their name"])
        // Their name comes out, and never a pet name in its place
        #expect(LetterMemory.withoutName("Dearest Claudette, I miss you.", theirName: "Claudette") == "Dearest you, I miss you.")
        #expect(LetterMemory.withoutGreeting(LetterMemory.withoutName("Dearest Claudette, I miss you.", theirName: "Claudette")) == "I miss you.")
        #expect(LetterMemory.withoutName("It rained. Claudette, I thought of you.", theirName: "Claudette") == "It rained. I thought of you.")
        #expect(LetterMemory.withoutName("I miss you, Claudette.", theirName: "Claudette") == "I miss you.")
        #expect(LetterMemory.withoutName("I told Claudette so.", theirName: "Claudette") == "I told you so.")
        // No greeting, and no "dear": a letter starts with its first sentence
                #expect(LetterMemory.withoutGreeting("My love,\n\nthe rain came in off the sea tonight.") == "The rain came in off the sea tonight.")
        #expect(LetterMemory.withoutGreeting("Darling —\nI found a Rilke poem.") == "I found a Rilke poem.")
        #expect(LetterMemory.withoutGreeting("The rain came in off the sea tonight, and I thought of you.\n\nYours,\nHenry") == "The rain came in off the sea tonight, and I thought of you.\n\nYours,\nHenry")
        #expect(LetterMemory.faults(in: "My love,\n\nI found a Rilke poem tonight.", theirName: nil) == ["used a term of endearment", "opened with a greeting"])
        #expect(LetterMemory.faults(in: "I hold you dear.", theirName: nil) == ["used the word dear, or opened with a greeting"])
        #expect(LetterMemory.faults(in: "I thought of you today, sweetheart.", theirName: nil) == ["used a term of endearment"])
        #expect(LetterMemory.faults(in: "Goodnight, love.", theirName: nil) == ["used a term of endearment"])
        // Ordinary sentences are left alone, the word love included
        #expect(LetterMemory.faults(in: "I found a Rilke poem tonight and thought of you. I love you, and you've been on my mind since.", theirName: "Claudette").isEmpty)
        #expect(LetterMemory.faults(in: "I hear you went to the coast this week. Did you like it?", theirName: nil).isEmpty)
    }

    @Test func aLetterKnowsTheTimeOfDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let at = { (h: Int) in cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: h, minute: 5))! }
        #expect(HenryPrompt.timeLine(now: at(13), calendar: cal).contains("Thursday, November 26, 1:05 PM: afternoon"))
        #expect(HenryPrompt.timeLine(now: at(8), calendar: cal).contains(": morning"))
        #expect(HenryPrompt.timeLine(now: at(19), calendar: cal).contains(": evening"))
        #expect(HenryPrompt.timeLine(now: at(23), calendar: cal).contains(": night"))
        #expect(HenryPrompt.timeLine(now: at(2), calendar: cal).contains("the middle of the night"))
        #expect(HenryPrompt.userMessage(theirMessage: nil, dayContext: nil, aboutThem: nil, now: at(13), calendar: cal).contains("no \"good night\""))
        #expect(!HenryPrompt.userMessage(theirMessage: nil, dayContext: nil, aboutThem: nil).contains("Where they are"))
    }

    @Test func flatteryAndPlatitudesAreCaught() {
        #expect(LetterMemory.faults(in: "You're so amazing, and you deserve the world.", theirName: nil) == ["flattered them"])
        #expect(LetterMemory.faults(in: "Remember, this too shall pass.", theirName: nil) == ["used a platitude"])
        #expect(LetterMemory.faults(in: "Something is coming for you, and I am so excited for it.", theirName: nil) == ["used a platitude"])
        #expect(LetterMemory.faults(in: "Good things are coming, and it will all work out.", theirName: nil) == ["used a platitude"])
        #expect(LetterMemory.faults(in: "I read by the window until the light went.", theirName: nil).isEmpty)
        #expect(HenryPrompt.system(HenryPersona()).contains("Never use flattery. Never use platitudes."))
    }

    @Test func allergensAreCaughtIncludingFoodsMadeFromThem() {
        let words = LetterMemory.allergenWords(["Eggs", "I'm allergic to coffee"])
        #expect(words.contains("egg") && words.contains("coffee") && words.contains("omelette"))
        #expect(LetterMemory.allergens(in: "I can't wait to make you eggs and a strong coffee.", words: words).sorted() == ["coffee", "egg"])
        #expect(LetterMemory.allergens(in: "Sunday I'll make you an omelette.", words: words) == ["omelette"])
        #expect(LetterMemory.allergens(in: "I'll bring tea and fresh berries.", words: words).isEmpty)
        #expect(HenryPrompt.userMessage(theirMessage: nil, dayContext: nil, aboutThem: nil, allergies: ["Eggs"]).contains("allergic to: Eggs"))
    }

    @Test func whatTheyWroteTodayCanBeAnswered() {
        let r = LetterMemory.review(letters: earlier, facts: ["Loves chocolate bars"], context: nil,
                                    theirMessage: "I ate too much chocolate today")
        #expect(!r.offLimitStems.contains("chocolate"))
    }
}
