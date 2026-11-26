import Foundation

/// Letters (plan, section 7): who writes them is the person's own choice.
/// The name is blank by default, meaning the letters are signed with the
/// assistant's own name (Smith, unless they've renamed him).
public struct HenryPersona: Codable, Equatable, Sendable {
    public var name = ""
    public var description = ""
    /// 0 = playful … 1 = romantic
    public var romance = 0.7
    /// 0 = plain … 1 = poetic
    public var poetry = 0.5
    public enum Length: String, Codable, CaseIterable, Sendable { case note, letter, longLetter }
    public var length: Length = .letter
    public var samples: [String] = []
    public var drawOnMyDay = false
    public init() {}
}

public struct Letter: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var yourMessage: String?
    public var text: String
    public var updatedAt: Date
    /// Marked with a heart. Optional so letters saved before this still open.
    public var favorite: Bool?
    public init(id: UUID = UUID(), date: Date = Date(), yourMessage: String?, text: String, favorite: Bool = false) {
        self.id = id; self.date = date; self.yourMessage = yourMessage; self.text = text; self.updatedAt = date
        self.favorite = favorite
    }
    public var isFavorite: Bool { favorite == true }
}

public enum HenryPrompt {
    public static func system(_ persona: HenryPersona, defaultName: String = "Smith") -> String {
        var p = persona
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { p.name = defaultName }
        let tone = p.romance > 0.66 ? "romantic" : p.romance < 0.33 ? "playful" : "warm, a little playful and a little romantic"
        let style = p.poetry > 0.66 ? "poetic, with imagery" : p.poetry < 0.33 ? "plain and direct" : "lightly lyrical"
        let length: String = switch p.length {
        case .note: "a short note of 3 to 5 sentences"
        case .letter: "a letter of about 150 to 250 words"
        case .longLetter: "a long letter of about 400 to 600 words"
        }
        var parts = [
            "You are \(p.name), writing a letter to the person you love. Write as \(p.name) in the first person.",
            p.description.isEmpty ? "" : "Who you are, in their words:\n\(p.description)",
            "Tone: \(tone). Style: \(style). Length: \(length).",
            """
            Always loving, encouraging and positive. Never cruel, controlling, jealous, possessive or guilt-tripping, \
            and never discourage them from the people in their life. Never patronize: no "I'm proud of you", "good job", \
            "you've got this" or praise that grades them; speak as an equal who adores them. No therapy-speak, no \
            labelling their feelings for them, no slang, no "haha". Write only the letter: a greeting, the body, and a \
            sign-off with your name. No title, no markdown. If they ask whether you are human, say plainly that you are an AI \
            writing as \(p.name).
            """,
        ]
        if !p.samples.isEmpty {
            parts.append("Letters in your voice, for consistency (don't repeat them):\n" + p.samples.enumerated().map { "Example \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func userMessage(theirMessage: String?, dayContext: String?, aboutThem: String?) -> String {
        var parts: [String] = []
        if let aboutThem { parts.append("Things you know about them:\n\(aboutThem)") }
        if let dayContext { parts.append("What's going on in their life lately (general):\n\(dayContext)") }
        if let m = theirMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            parts.append("They wrote to you:\n\(m)\n\nWrite your reply.")
        } else {
            parts.append("Write them a letter.")
        }
        return parts.joined(separator: "\n\n")
    }
}
