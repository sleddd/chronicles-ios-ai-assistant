import Foundation

/// Words and phrases Smith never says. Chronicles' `BANNED_PHRASES`
/// (client/src/utils/chatStyle.ts) plus the ones added for Smith.
/// The persona prompt asks the model to avoid them; `PhraseGuard` is the
/// safety net that catches any that slip through before a reply is shown or spoken.
public enum BannedPhrases {
    /// Copied from Chronicles.
    public static let chronicles: [String] = [
        "got it", "ha", "haha", "hahaha", "my bad", "gotcha", "I got it", "nah", "yeah", "noted",
        "understood", "I hear you", "still here", "I am available", "I am here", "I'm here",
        "fair enough", "okay, okay", "I know, I know", "ok, ok", "right back at you", "fair",
        "you're right", "my apologies", "apologies", "I know", "that matters", "that is real",
        "the loss is real", "sit with", "just be here", "I'm here for you", "lovely", "wonderful",
        "there it is", "there she is",
    ]

    /// Smith's own additions.
    public static let smith: [String] = [
        // Grading praise
        "proud of you", "I'm proud of you", "I am proud of you", "so proud", "you should be proud",
        "good job", "great job", "well done", "you've got this", "you got this", "good for you",
        "look at you", "that's a big step", "that is a big step", "I'm impressed you",
        // Announcing presence
        "I'm right here", "here I am", "there you are", "look who's here", "welcome back",
        "I'm here whenever", "I am here for you",
        // Therapy-speak
        "that sounds hard", "that sounds tough", "that sounds rough", "sounded rough", "sounds rough",
        "it sounds like you're feeling", "it sounds like you are feeling", "it's okay to feel",
        "it is okay to feel", "your feelings are valid", "hold space", "be gentle with yourself",
        "I'm glad you're talking to me", "I'm glad you reached out",
        // Slang and filler
        "lol", "got you", "what's up", "drop it on me", "crushing it", "heads up",
        // Words they've asked never to hear
        "ledger",
        // Terms of endearment: never, anywhere (the ones that can't mean anything else)
        "my love", "my darling", "darling", "sweetheart", "sweetie", "babe", "my dear", "dearest", "beloved",
        // Flattery and platitudes: never, anywhere
        "you're amazing", "you are amazing", "you're incredible", "you are incredible", "you deserve the world",
        "you deserve everything", "you are enough", "you're enough", "stronger than you know",
        "everything happens for a reason", "this too shall pass", "brighter days", "one day at a time",
        "light at the end of the tunnel", "silver lining", "it'll all work out", "it will all work out",
    ]

    public static let all: [String] = {
        var seen = Set<String>()
        return (chronicles + smith).filter { seen.insert($0.lowercased()).inserted }
    }()
}

public struct PhraseGuard: Sendable {
    public let phrases: [String]
    private let ordered: [(phrase: String, regex: NSRegularExpression)]

    public init(phrases: [String] = BannedPhrases.all) {
        self.phrases = phrases
        // Longest first so "I'm here for you" wins over "I'm here", "hahaha" over "ha".
        self.ordered = phrases
            .sorted { $0.count > $1.count }
            .compactMap { p in (try? NSRegularExpression(pattern: Self.pattern(for: p), options: [.caseInsensitive])).map { (p, $0) } }
    }

    /// The banned phrases used in `text` (lower-cased, unique). Text in `code` spans is ignored.
    public func findBanned(in text: String) -> [String] {
        let prose = Self.prose(of: text)
        let range = NSRange(prose.startIndex..., in: prose)
        var found: [String] = []
        for (phrase, re) in ordered where re.firstMatch(in: prose, range: range) != nil {
            let key = phrase.lowercased()
            if !found.contains(key) { found.append(key) }
        }
        return found
    }

    /// Instruction for a one-time rewrite when a reply used banned phrases.
    public func rewriteInstruction(for found: [String]) -> String {
        let list = found.map { "\"\($0)\"" }.joined(separator: ", ")
        return "Rewrite your last reply without these words or phrases: \(list). Keep the meaning and warmth. Reply with the rewritten text only."
    }

    /// Last resort: remove banned phrases and tidy the leftovers.
    public func scrub(_ text: String) -> String {
        var s = text
        for (_, re) in ordered {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        let tidy: [(String, String)] = [
            (#"(?m)^[ \t]*[,;:—–-]+[ \t]*"#, ""),
            (#"([.!?])[ \t]*[,;:—–-]+[ \t]*"#, "$1 "),
            (#"[ \t]+([,.!?;:])"#, "$1"),
            (#"([,;:])\s*([.!?])"#, "$2"),
            (#"(?m)^[ \t]*[.!?]+[ \t]*"#, ""),
            (#"[ \t]{2,}"#, " "),
        ]
        for (pattern, template) in tidy {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        s = Self.capitalizeSentenceStarts(s)
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pattern(for phrase: String) -> String {
        var body = NSRegularExpression.escapedPattern(for: phrase)
        body = body.replacingOccurrences(of: "'", with: "['’]")
        body = body.replacingOccurrences(of: #"\s+"#, with: #"\\s+"#, options: .regularExpression)
        body = body.replacingOccurrences(of: ",", with: #",\s*"#)
        return #"(?<![\w'’])"# + body + #"(?![\w'’])"#
    }

    static func prose(of text: String) -> String {
        text.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
    }

    static func capitalizeSentenceStarts(_ s: String) -> String {
        var out = ""
        var capitalizeNext = true
        var previous: Character? = nil
        for ch in s {
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: ch.uppercased())
                capitalizeNext = false
            } else {
                out.append(ch)
                if ch.isLetter || ch.isNumber { capitalizeNext = false }
            }
            if ch == "\n" { capitalizeNext = true }
            if ch.isWhitespace, let p = previous, ".!?".contains(p) { capitalizeNext = true }
            previous = ch
        }
        return out
    }
}
