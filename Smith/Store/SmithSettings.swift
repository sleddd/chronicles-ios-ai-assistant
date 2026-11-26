import Foundation
import SmithCore

/// Everything the person chooses in Settings. Synced between devices as one blob.
enum WeatherSource: String, Codable, CaseIterable {
    case chronicles, device, city
    var label: String {
        switch self { case .chronicles: "Home city from Chronicles"; case .device: "This device’s location"; case .city: "A city I choose" }
    }
}

struct SmithSettings: Codable, Equatable {
    var name = "Smith"
    var model: ClaudeModel = .sonnet
    var smithVoiceID: String?
    var henryVoiceID: String?
    var speechRate: Float = 0.5
    /// ElevenLabs voices (your own key) instead of Apple's.
    var useElevenLabs = false
    var elevenModel: ElevenLabs.Model = .v4Turbo
    var elevenSmithVoice: String?
    var elevenHenryVoice: String?
    /// Speak replies to typed messages too.
    var speakTypedReplies = true
    var muted = false
    /// Seconds of silence before Smith decides you're done talking. 0 = until you tap the orb.
    var pauseWait: Double = 3
    var fahrenheit = Locale.current.measurementSystem == .us
    /// Where the weather is for: Chronicles' home city, this device's location, or a city typed here.
    var weatherSource: WeatherSource = .chronicles
    var weatherCity: HomePlace?
    /// The home city last read from Chronicles (so the weather still works while locked).
    var chroniclesHome: HomePlace?
    /// The account's sealed "Don't share with AI" choices as last opened, and whose they
    /// are. Kept so that a server which stops sending them can't make Smith forget them.
    var chroniclesPrivacy: JSONValue?
    var chroniclesPrivacyAccount: String?
    /// The highest revision seen of the account's AI key setting (an older one is a replay).
    var chroniclesAIConfigRev: Double = 0

    var journalMode: JournalShareMode = .general
    /// Chronicles topic ids never mentioned (left out of the journal digest).
    var neverMentionTopics: Set<String> = []
    /// Bill ids named just "a bill".
    var privateBills: Set<String> = []
    /// Privacy moved to Chronicles: Smith's own choices above were cleared once.
    var privacyFromChronicles = false

    var memoryEnabled = true
    var concerns = ConcernSettings()
    var freshness = Freshness.Settings()
    var goalMentionInBriefing = true

    var henry = HenryPersona()
    /// Letters were first signed "Henry"; that default moved to the assistant's own name.
    var lettersRenamed = false

    /// Who signs the letters: the name chosen for them, or the assistant's own name.
    var letterName: String {
        let n = henry.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? name : n
    }

    /// Chronicles sign-in: the email and server are remembered; the password never is.
    var chroniclesEmail: String?
    var chroniclesServer: String?
    /// Lock after this many idle minutes (0 = only when you lock or quit).
    var autoLockMinutes = 30
    /// Use the Anthropic key saved in Chronicles (In-App AI) instead of one saved in Smith.
    var useChroniclesAIKey = true
    /// Unlock with Face ID / Touch ID within the same Chronicles session.
    var quickUnlock = false

    /// Words and phrases Smith must never use, added by the person (on top of the built-in list).
    var customBannedPhrases: [String] = []
    var bannedPhrases: [String] { BannedPhrases.all + customBannedPhrases.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// The stats card on the home screen can be hidden.
    var statsHidden = false

    var macWakeWord = false
    var greetOnWake = true
    var lastGreetingDay: String?

    var updatedAt = Date.distantPast
}

/// Decodes saved JSON on top of the current defaults, so adding a new setting
/// (or field) in an update never wipes what was saved before.
nonisolated enum Tolerant {
    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) -> T? {
        guard let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)),
              let saved = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let merged = merge(base, saved)
        guard let out = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(T.self, from: out)
    }

    private static func merge(_ base: Any, _ saved: Any) -> Any {
        guard var b = base as? [String: Any], let s = saved as? [String: Any] else { return saved }
        for (k, v) in s { b[k] = b[k].map { merge($0, v) } ?? v }
        return b
    }
}
