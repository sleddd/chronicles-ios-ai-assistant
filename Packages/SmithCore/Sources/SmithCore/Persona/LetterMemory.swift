import Foundation

/// What earlier letters have already said, so a new letter never says it again.
///
/// Letters kept circling the same few details (the chocolate bars, the glasses):
/// every request carried the same list of facts, and earlier letters were shown
/// only in part. This works out, on the device, which specific details the
/// letters have already used, so that:
///  - facts already written about are left out of the next request,
///  - those details are named to the model as off limits, and
///  - a new letter that brings one back anyway is caught and written again.
public enum LetterMemory {
    /// The specific words of a text ("chocolate", "glass", "garden"), reduced to a
    /// simple stem and keyed to the first form seen, so it can be named back as written.
    public static func details(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
            let word = raw.replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "'", with: "")
            guard word.count >= 4, !generic.contains(word) else { continue }
            let s = stem(word)
            guard s.count >= 3, !generic.contains(s) else { continue }
            if out[s] == nil { out[s] = word }
        }
        return out
    }

    static func stem(_ w: String) -> String {
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("sses") { return String(w.dropLast(2)) }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is"), w.count > 4 { return String(w.dropLast()) }
        return w
    }

    public struct Review: Equatable, Sendable {
        /// Facts (by index in the list given) that earlier letters have already written about.
        public var usedFacts: Set<Int> = []
        /// Details never to bring up again, as they were written (most telling first).
        public var offLimits: [String] = []
        /// The same, as stems, for checking a new letter.
        public var offLimitStems: Set<String> = []
    }

    /// Reads every earlier letter.
    /// - A fact counts as written about when a letter used one of its longer words
    ///   ("chocolate", "glasses") or two of its words.
    /// - Off limits: every detail of what Smith knows about them (facts, the day's
    ///   summary) that a letter has used, and any other detail that has come up in
    ///   two letters or more (a motif the letters invented and kept returning to).
    /// - What they wrote today is never off limits: a reply should answer it.
    public static func review(letters: [String], facts: [String], context: String?, theirMessage: String?) -> Review {
        let perLetter = letters.map(details(in:))
        var seen: [String: Int] = [:]          // stem → how many letters used it
        var surface: [String: String] = [:]
        for d in perLetter {
            for (s, w) in d { seen[s, default: 0] += 1; if surface[s] == nil { surface[s] = w } }
        }
        let allowed = Set(details(in: theirMessage ?? "").keys)

        var review = Review()
        var fromContext = Set<String>()
        for (i, fact) in facts.enumerated() {
            let words = details(in: fact)
            fromContext.formUnion(words.keys)
            let hits = words.keys.filter { seen[$0] != nil }
            if hits.contains(where: { $0.count >= 5 }) || hits.count >= 2 { review.usedFacts.insert(i) }
        }
        fromContext.formUnion(details(in: context ?? "").keys)

        let used = seen.keys.filter { fromContext.contains($0) || seen[$0, default: 0] >= 2 }
        let ranked = used.filter { !allowed.contains($0) }
            .sorted { (fromContext.contains($0) ? 1 : 0, seen[$0, default: 0], $1) > (fromContext.contains($1) ? 1 : 0, seen[$1, default: 0], $0) }
            .prefix(maxOffLimits)
        review.offLimitStems = Set(ranked)
        review.offLimits = ranked.map { surface[$0] ?? $0 }
        return review
    }

    /// Off-limits details a new letter brought back anyway, as written in it.
    public static func repeats(in letter: String, review: Review) -> [String] {
        details(in: letter).filter { review.offLimitStems.contains($0.key) }.map(\.value).sorted()
    }

    /// What a letter must never have, each with the reason given to the model when a draft
    /// has it: a term of endearment, or "dear". (Their name and a greeting are checked in
    /// `faults(in:theirName:)`. The rules about what a letter may be "about" are gone: the
    /// letter's instructions are the ones from the night of Nov 25.)
    static let faults: [(reason: String, regex: NSRegularExpression)] = [
        ("used the word dear, or opened with a greeting", #"\bdear(est|ly)?\b"#),
        ("used a term of endearment", #"\bmy (love|darling|heart|sweet|angel|beloved|dear|dearest|sweetheart|baby|babe|honey|girl|boy|queen|king|treasure|sunshine|one and only)\b|\b(darling|sweetheart|sweetie|sweet pea|babe|baby|beloved|honey|sugar|angel|gorgeous|beautiful|handsome|love)[,.!?]|\b(darling|sweetheart|sweetie|babe|beloved)\b"#),
        ("flattered them", #"\byou('re| are)( (so|such|truly|simply|just|really|absolutely))? (an? )?(amazing|incredible|beautiful|gorgeous|stunning|perfect|wonderful|extraordinary|remarkable|brilliant|special|magnificent|radiant|enough|everything)\b"#),
        ("flattered them", #"\byou deserve (the world|everything|the best|all the|so much)\b|\b(smartest|kindest|most beautiful|most amazing|most incredible|most wonderful) (person|woman|man|soul)\b"#),
        ("used a platitude", #"\b(everything happens for a reason|this too shall pass|brighter days|better days|one day at a time|light at the end of the tunnel|silver lining|it('ll| will) all (work out|be okay|be fine|be alright)|everything will (be|work out)( okay| fine| alright)?|stronger than you know|meant to be|you('ve)? got this|(something|good things?|great things?|the best) (is|are) (coming|ahead|yet to come)|when one door closes)\b"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }

    /// The faults in a draft, plus their name if it appears. Each reason once.
    public static func faults(in letter: String, theirName: String?) -> [String] {
        let range = NSRange(letter.startIndex..., in: letter)
        var out: [String] = []
        for (reason, re) in faults where re.firstMatch(in: letter, range: range) != nil && !out.contains(reason) { out.append(reason) }
        // A letter, not an interview
        if letter.filter({ $0 == "?" }).count > 1 { out.append("asked more than one question") }
        if greeting(in: letter) != nil && !out.contains("used the word dear, or opened with a greeting") {
            out.append("opened with a greeting")
        }
        for part in nameParts(theirName) where letter.range(of: "\\b\(NSRegularExpression.escapedPattern(for: part))\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            out.append("used their name")
            break
        }
        return out
    }

    /// Their name taken out, whatever else: dropped where it is an aside ("…, Name." or
    /// "Name, …"), otherwise "you". Never a term of endearment in its place.
    public static func withoutName(_ letter: String, theirName: String?) -> String {
        var s = letter
        for part in nameParts(theirName) {
            let name = NSRegularExpression.escapedPattern(for: part)
            s = s.replacingOccurrences(of: ",[ \\t]*\\b\(name)\\b(?=[,.!?;:]|\\s*$)", with: "", options: [.regularExpression, .caseInsensitive])
            // "Name, …" opening a sentence or a line
            s = s.replacingOccurrences(of: "(^|(?<=[.!?]\\s)|(?<=\\n))\(name)\\b,[ \\t]*", with: "", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "\\b\(name)\\b", with: "you", options: [.regularExpression, .caseInsensitive])
        }
        return s
    }

    /// A greeting at the top of a letter: a short opening line of its own ending in a
    /// comma, colon or dash ("My love,", "Darling —"), or "Dear …," / "Dearest …," run
    /// into the first sentence. Letters have none: they start with their first sentence.
    static let greetingLine = try! NSRegularExpression(
        pattern: #"\A\s*(?:[^\s.!?,:;—–-]+[ \t]+){0,5}[^\s.!?,:;—–-]+[ \t]*[,:—–-]+[ \t]*\n\s*"#)
    static let greetingInline = try! NSRegularExpression(
        pattern: #"\A\s*(?:my[ \t]+)?(?:dear(?:est)?|darling|beloved|sweetheart)\b[^,.!?\n]{0,40},[ \t]*"#, options: [.caseInsensitive])

    static func greeting(in letter: String) -> NSRange? {
        let range = NSRange(letter.startIndex..., in: letter)
        for re in [greetingLine, greetingInline] {
            if let m = re.firstMatch(in: letter, range: range) { return m.range }
        }
        return nil
    }

    /// The greeting taken off, whatever else: the letter starts with its first sentence.
    public static func withoutGreeting(_ letter: String) -> String {
        guard let found = greeting(in: letter), let range = Range(found, in: letter) else { return letter }
        let rest = String(letter[range.upperBound...])
        guard let first = rest.first, !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return letter }
        return first.uppercased() + rest.dropFirst()
    }

    static func nameParts(_ name: String?) -> [String] {
        (name ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 2 }
    }

    /// Allergens from what they wrote ("Allergic to eggs and coffee" → egg, coffee), with the
    /// foods made from them (eggs → mayonnaise, omelette, custard…; Chronicles' own table).
    public static func allergenWords(_ written: [String]) -> [String] {
        var out: [String] = []
        for line in written {
            let words = line.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
                .filter { !allergyFiller.contains($0) }
            for w in words {
                // "eggs" → "egg" (short words too, which `stem` leaves alone)
                let s = w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") && !w.hasSuffix("us") ? String(w.dropLast()) : w
                out.append(s)
                if let key = allergenAlias[s] ?? allergenAlias[w] { out += allergenFoods[key] ?? [] }
            }
        }
        var seen = Set<String>()
        return out.filter { $0.count >= 3 && seen.insert($0).inserted }
    }

    /// Foods from the list in a letter, as written.
    public static func allergens(in letter: String, words: [String]) -> [String] {
        words.filter { w in
            letter.range(of: "\\b\(NSRegularExpression.escapedPattern(for: w))(s|es)?\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static let allergyFiller: Set<String> = [
        "allergic", "allergy", "allergies", "allergen", "intolerant", "intolerance", "sensitive", "sensitivity", "to", "and",
        "or", "is", "am", "im", "i", "she", "he", "they", "are", "severe", "severely", "mild", "very", "has", "have", "an",
        "a", "the", "of", "can", "cant", "can't", "eat", "drink", "no", "any", "all", "with", "reaction", "anaphylaxis",
    ]
    static let allergenAlias: [String: String] = [
        "dairy": "milk", "lactose": "milk", "milk": "milk", "egg": "egg", "gluten": "wheat", "wheat": "wheat",
        "peanut": "peanut", "nut": "tree nut", "shellfish": "shellfish", "seafood": "shellfish", "crustacean": "shellfish",
        "fish": "fish", "soy": "soy", "soya": "soy", "sesame": "sesame",
    ]
    static let allergenFoods: [String: [String]] = [
        "milk": ["milk", "dairy", "cheese", "butter", "cream", "yogurt", "yoghurt", "latte", "cappuccino", "ice cream", "custard", "whey"],
        "egg": ["egg", "mayonnaise", "mayo", "meringue", "aioli", "omelette", "omelet", "frittata", "quiche", "custard", "hollandaise", "souffle", "soufflé"],
        "wheat": ["bread", "pasta", "flour", "toast", "croissant", "bagel", "pancake", "waffle", "pastry", "noodle", "cake"],
        "peanut": ["peanut", "groundnut"],
        "tree nut": ["almond", "cashew", "walnut", "pecan", "pistachio", "hazelnut", "macadamia", "praline", "marzipan", "nutella"],
        "shellfish": ["shrimp", "prawn", "crab", "lobster", "scallop", "clam", "mussel", "oyster", "squid", "calamari"],
        "fish": ["salmon", "tuna", "cod", "anchovy", "trout", "sardine", "mackerel", "halibut"],
        "soy": ["soy", "tofu", "tempeh", "edamame", "miso", "tamari"],
        "sesame": ["sesame", "tahini", "hummus"],
    ]

    /// Kept to a size that reads as a list, not a wall.
    static let maxOffLimits = 40

    /// Words every letter is made of, which say nothing particular about anyone.
    /// Only words of four letters or more reach this list (shorter ones are skipped anyway).
    static let generic = Set<String>(genericWords)
    static let genericWords: [String] = [
        // function words
        "that", "this", "these", "those", "with", "from", "into", "onto", "upon", "about", "above", "after", "again",
        "against", "along", "among", "around", "because", "been", "before", "being", "below", "between", "both", "could",
        "does", "doing", "down", "during", "each", "even", "ever", "every", "have", "having", "here", "how", "just",
        "like", "more", "most", "much", "must", "never", "only", "other", "ours", "over", "same", "should", "since",
        "some", "such", "than", "their", "theirs", "them", "then", "there", "they", "thing", "things", "though",
        "through", "till", "today", "tonight", "tomorrow", "until", "very", "want", "wanted", "were", "what", "when",
        "where", "which", "while", "will", "with", "within", "without", "would", "your", "yours", "yourself",
        "mine", "myself", "still", "also", "already", "almost", "always", "anything", "everything", "nothing",
        "something", "someone", "anyone", "everyone", "somehow", "somewhere", "maybe", "perhaps", "really", "quite",
        "rather", "enough", "another", "whatever", "whenever", "wherever", "once", "twice", "well", "away", "back",
        "else", "less", "least", "many", "next", "last", "first", "long", "little", "small", "big", "great", "good",
        "best", "better", "kind", "sort", "part", "whole", "half", "way", "ways", "time", "times", "moment", "moments",
        "make", "makes", "made", "making", "take", "takes", "took", "taken", "give", "gives", "gave", "given", "keep",
        "keeps", "kept", "come", "comes", "came", "coming", "goes", "going", "gone", "went", "know", "knows", "knew",
        "known", "think", "thinks", "thought", "thoughts", "thinking", "feel", "feels", "felt", "feeling", "feelings",
        "find", "found", "look", "looks", "looked", "looking", "seem", "seems", "seemed", "tell", "tells", "told",
        "said", "says", "saying", "hear", "heard", "hope", "hoped", "hopes", "wish", "wished", "wishes", "need",
        "needs", "needed", "mean", "means", "meant", "let's", "lets", "can't", "don't", "won't", "isn't", "it's",
        "i'm", "i've", "i'd", "i'll", "you're", "you've", "you'd", "you'll", "that's", "there's", "here's", "what's",
        "dont", "cant", "wont", "isnt", "youre", "youve", "youd", "youll", "thats", "theres", "heres", "whats",
        "ive", "ill", "id", "im",
        // what any letter is made of
        "love", "loved", "loves", "loving", "lovely", "dear", "dearest", "darling", "sweet", "sweetheart", "honey",
        "heart", "hearts", "soul", "yours", "always", "forever", "truly", "deeply", "letter", "letters", "write",
        "writing", "wrote", "written", "words", "word", "smile", "smiles", "smiling", "laugh", "laughs", "laughter",
        "eyes", "hand", "hands", "voice", "face", "arms", "life", "lives", "world", "days", "night", "nights",
        "morning", "mornings", "evening", "evenings", "afternoon", "week", "weeks", "year", "years", "home",
        "light", "together", "remember", "wonder", "wondering", "beautiful", "warm", "warmth", "quiet", "gentle",
        "soft", "close", "near", "nearer", "miss", "missing", "missed", "glad", "happy", "happiness", "joy", "sure",
        "real", "simple", "ordinary", "small", "tiny", "endless", "everyday", "favourite", "favorite", "special",
        "precious", "wonderful", "perfect", "lucky", "grateful", "thank", "thanks", "adore", "cherish", "treasure",
        "together", "with", "always", "yours", "thing", "person", "people", "kiss", "kisses", "hold", "holding",
    ]
}
