import Foundation
import FoundationModels
import SmithCore

/// Apple's on-device model (Apple Intelligence). Nothing here leaves the device.
/// Used to summarize journal entries during import and, when available, to
/// write conversation summaries.
nonisolated enum OnDevice {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off in System Settings."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready."
        default: return "Apple Intelligence isn't available."
        }
    }
}

@Generable
enum GeneratedTone: String { case light, steady, mixed, heavy }

@Generable
enum GeneratedTheme: String { case work, health, family, relationships, creativity, rest, money, growth }

@Generable
struct GeneratedJournalSummary {
    @Guide(description: "The overall emotional tone of the entry")
    var tone: GeneratedTone
    @Guide(description: "Up to three broad themes the entry is about", .maximumCount(3))
    var themes: [GeneratedTheme]
    @Guide(description: "One neutral sentence, under 15 words, summarizing the entry without quoting it or naming anyone")
    var line: String
}

nonisolated struct OnDeviceJournalSummarizer: JournalSummarizer {
    func summarize(_ text: String) async -> JournalSummary? {
        guard OnDevice.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You summarize private journal entries for the person's own reference. Pick the tone and up to three \
            broad themes from the given lists, and write one short neutral sentence. Never quote the entry.
            """)
        do {
            let r = try await session.respond(to: String(text.prefix(6000)), generating: GeneratedJournalSummary.self)
            let s = r.content
            return JournalSummary(tone: JournalTone(rawValue: s.tone.rawValue) ?? .steady,
                                  themes: s.themes.compactMap { JournalTheme(rawValue: $0.rawValue) },
                                  line: String(s.line.prefix(140)))
        } catch {
            return nil
        }
    }
}

@Generable
struct GeneratedFact {
    @Guide(description: "A short third-person line about the person, e.g. 'Loves Sunday hikes'")
    var text: String
    @Guide(description: "One of: aboutYou, people, likes, dislikes, routines, style")
    var category: String
}

@Generable
struct GeneratedWrapUp {
    @Guide(description: "One or two plain sentences: what was talked about and anything decided")
    var summary: String
    @Guide(description: "Up to three things the person clearly said about themselves", .maximumCount(3))
    var facts: [GeneratedFact]
}

nonisolated enum OnDeviceWrapUp {
    static func run(transcript: String) async -> WrapUpResult? {
        guard OnDevice.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: WrapUp.instructions)
        do {
            let r = try await session.respond(to: String(transcript.suffix(8000)), generating: GeneratedWrapUp.self).content
            let facts = r.facts.compactMap { f -> (text: String, category: Fact.Category)? in
                guard let c = Fact.Category(rawValue: f.category), c != .sensitive, !f.text.isEmpty else { return nil }
                return (f.text, c)
            }
            return WrapUpResult(summary: r.summary, facts: facts)
        } catch {
            return nil
        }
    }
}
