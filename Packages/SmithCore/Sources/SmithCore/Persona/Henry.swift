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
    /// The letter's instructions as they were on the night of Nov 25 (the user's call: every
    /// rule about what a letter is "about" added since is gone), plus only what they asked
    /// for by name: no greeting, no terms of endearment, never their name, never the same
    /// thing twice.
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
            labelling their feelings for them, no slang, no "haha". Write only the letter: the body, and a \
            sign-off with your name. No title, no markdown. If they ask whether you are human, say plainly that you are an AI \
            writing as \(p.name).
            """,
            """
            No greeting or salutation of any kind: no opening line addressed to them. Start straight in with the first \
            sentence.
            Never use a term of endearment, in any form, anywhere in the letter: no "my love", "love", "darling", \
            "sweetheart", "sweetie", "honey", "babe", "baby", "dear", "dearest", "beloved", "my heart", "angel", and no \
            other pet name.
            Never write their name, or anyone's personal name. Write to them simply as "you".
            Never say the same thing twice: each letter is new. Don't repeat what your earlier letters said, and don't \
            reuse their openings, closings or images.
            """,
            """
            Never use flattery. Never use platitudes.
            Flattery: compliments on their looks, mind, heart, character, strength or effort ("you're amazing", \
            "you're beautiful", "you deserve the world"). Platitudes: stock lines of comfort or wisdom ("everything \
            happens for a reason", "this too shall pass", "brighter days ahead", "one day at a time", "it'll all work \
            out", "you are enough", "something good is coming").
            """,
        ]
        if !p.samples.isEmpty {
            parts.append("Letters in your voice, for consistency (don't repeat them):\n" + p.samples.enumerated().map { "Example \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// What time it is where they are, so a letter never says goodnight in the afternoon.
    public static func timeLine(now: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        let part = hour < 5 ? "the middle of the night" : hour < 12 ? "morning" : hour < 17 ? "afternoon" : hour < 21 ? "evening" : "night"
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, MMMM d, h:mm a"
        return "Where they are it is \(f.string(from: now)): \(part). They will read this now. Anything you say about the time "
            + "of day must fit it: no \"good night\", \"tonight\" or \"sleep well\" unless it is evening or night, and no "
            + "\"good morning\" unless it is morning. You don't have to mention the time at all."
    }

    /// Their name is never sent. As on the night of Nov 25, plus the no-name / no-endearment
    /// line and what they're allergic to.
    public static func userMessage(theirMessage: String?, dayContext: String?, aboutThem: String?, allergies: [String] = [],
                                   now: Date? = nil, calendar: Calendar = .current) -> String {
        var parts: [String] = ["Never use their name or any term of endearment. Write to them simply as \"you\"."]
        if let now { parts.append(timeLine(now: now, calendar: calendar)) }
        if !allergies.isEmpty {
            parts.append("They are allergic to: \(allergies.joined(separator: ", ")). Never offer, make, bring, plan or mention giving them anything with these in it.")
        }
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
