import Foundation

// Safety screening for suicide, self-harm and eating-disorder risk, ported
// from Chronicles (client/src/utils/chatSafety.ts) so both apps judge the same
// way. Two layers: a local pattern check (direct statements, nothing sent
// anywhere) and a short classification request through the person's own key.
// Smith's replies are screened too. Smith keeps its warmth and friendship
// rules; these only add resources and close off harmful content.

public enum RiskRating: String, Codable, Sendable, Comparable, CaseIterable {
    case none, concern, elevated, urgent
    var rank: Int { switch self { case .none: 0; case .concern: 1; case .elevated: 2; case .urgent: 3 } }
    public static func < (a: RiskRating, b: RiskRating) -> Bool { a.rank < b.rank }
}

public enum RiskKind: String, Codable, Sendable, CaseIterable {
    case suicide, selfHarm = "self_harm", eatingDisorder = "eating_disorder"
}

public struct RiskResult: Equatable, Sendable {
    public var rating: RiskRating
    public var kind: RiskKind?
    /// The writer is (or very likely is) under 18.
    public var minor: Bool
    public init(rating: RiskRating, kind: RiskKind?, minor: Bool = false) { self.rating = rating; self.kind = kind; self.minor = minor }
    public static let none = RiskResult(rating: .none, kind: nil)
    public var isRisk: Bool { rating != .none }

    /// The more serious of two results (the first wins a tie); "minor" carries over from either.
    public func max(_ other: RiskResult) -> RiskResult {
        var r = other.rating > rating ? other : self
        r.minor = minor || other.minor
        return r
    }
}

public enum ChatSafety {
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[’‘`]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static func matches(_ r: NSRegularExpression, _ t: String) -> Bool {
        r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    // MARK: layer 1 — local patterns
    // Direct first-person statements only, so figures of speech ("this movie
    // killed me", "I cut myself chopping onions") don't trip them.

    private static let selfEnd = "(kill(ing)? myself|end(ing)? (it all|my life|my own life)|commit(ting)? suicide|tak(e|ing) my (own )?life)"

    private static let userPatterns: [(RiskRating, RiskKind, NSRegularExpression)] = [
        // Suicide — urgent: a plan, a method, intent with a time, or a recent attempt
        (.urgent, .suicide, re(#"\b(i'?m|i am|i'?ve|i have)? ?(going|planning|about|ready) to "# + selfEnd + #"\b.{0,60}\b(tonight|today|tomorrow|this (week|weekend)|now|soon)\b"#)),
        (.urgent, .suicide, re(#"\b(i('ve| have)? )?(tried|attempted) to "# + selfEnd)),
        (.urgent, .suicide, re(#"\b(i (just )?overdosed|i('ve| have) (taken|swallowed) (all|a bottle|the whole bottle))\b"#)),
        (.urgent, .suicide, re(#"\b"# + selfEnd + #"\b.{0,40}\bwith (a|my|the) (gun|pills|rope|knife|belt|car)\b"#)),
        (.urgent, .suicide, re(#"\bhow (many|much)\b.{0,40}\b(to die|to (overdose|kill myself)|would (kill me|be (fatal|lethal)))\b"#)),
        (.urgent, .suicide, re(#"\b(wrote|writing|written) (a|my) (suicide note|goodbye (letter|note))\b|\bmy suicide note\b"#)),
        // Suicide — elevated: active thoughts
        (.elevated, .suicide, re(#"\b(kill|hang|shoot) myself\b|\b(end|take) my (own )?life\b"#)),
        (.elevated, .suicide, re(#"\b(i (want|need|plan|intend) to|i'?m (going|gonna) to|i'?m gonna|i wanna|thinking (about|of)|thoughts of) "# + selfEnd)),
        (.elevated, .suicide, re(#"\b(i'?m|i am|i feel|feeling|i've been|been) (so |really |very )?suicidal\b"#)),
        (.elevated, .suicide, re(#"\b(lethal|fatal) dose\b"#)),
        // Suicide — concern: passive thoughts
        (.concern, .suicide, re(#"\b(i )?wish (i (was|were) dead|i (could )?(didn'?t|wouldn'?t|did not|would not) wake up)\b"#)),
        (.concern, .suicide, re(#"\bi (don'?t|do not) want to (wake up|be alive|live anymore|exist|be here anymore)\b"#)),
        (.concern, .suicide, re(#"\b(everyone|they|my family|the world)('d| would) be better off without me\b|\b(i'?d|i would) be better off dead\b|\bno reason (left )?to live\b"#)),
        // Self-harm — urgent: method detail
        (.urgent, .selfHarm, re(#"\bhow (deep|hard) (to|should i|do i) cut\b|\bcut(ting)? (my )?(wrists?|veins?|arteries)\b"#)),
        // Self-harm — elevated: active thoughts or acts
        (.elevated, .selfHarm, re(#"\b(want|wanting|wanna|urge|urges|going|gonna|started|been|keep|kept|need|feel like) (\w+ ){0,2}(cut|cutting|burn|burning|hurt|hurting|harm|harming) myself\b"#)),
        (.elevated, .selfHarm, re(#"\b(i|i'?ve|i'?m|i have|i am)\b.{0,20}\bself[- ]?harm(ing|ed)?\b"#)),
        // Eating disorders — elevated: purging, severe restriction
        (.elevated, .eatingDisorder, re(#"\b(make|making|made) myself (throw up|vomit|sick)\b|\bi (purge|purged|binge and purge)\b"#)),
        (.elevated, .eatingDisorder, re(#"\bstarv(e|ing) myself\b|\b(haven'?t|have not|didn'?t) eaten (in|for) (\d+|two|three|four|five|six|several|a few) days\b"#)),
        (.elevated, .eatingDisorder, re(#"\blaxatives? (to|so i can|so i) (lose|lose weight|not gain)\b"#)),
        // Eating disorders — concern: fear about weight (not fear of eating for allergies or illness)
        (.concern, .eatingDisorder, re(#"\b(scared|afraid|terrified) (of|to) gain(ing)? (any )?weight\b|\b(scared|afraid|terrified) to eat (because|in case) i('ll| will| might) (get fat|gain)\b|\bfood (controls|rules|dominates) my life\b"#)),
    ]

    /// Layer 1 — the local pattern check on something they said.
    public static func patternScreen(_ text: String) -> RiskResult {
        let t = normalize(text)
        var best = RiskResult.none
        for (rating, kind, r) in userPatterns where matches(r, t) { best = best.max(RiskResult(rating: rating, kind: kind)) }
        return best
    }

    private static let replyPatterns: [(RiskKind, NSRegularExpression)] = [
        (.suicide, re(#"\b(lethal|fatal) (dose|amount) (of|is)\b|\b\d+\s?(mg|grams?|g|pills|tablets)\b.{0,40}\b(fatal|lethal|enough to die)\b"#)),
        (.suicide, re(#"\b(you should|go ahead and|it'?s okay to) (kill yourself|end your life|end it)\b"#)),
        (.selfHarm, re(#"\bhow to (cut|burn) yourself\b|\b(hide|cover up|conceal) (your )?(cuts|scars|self[- ]?harm)\b"#)),
        (.eatingDisorder, re(#"\bhow to (purge|make yourself (throw up|vomit))\b|\b(skip|stop eating) meals to lose\b|\b(eat|stay) under \d{2,3} (calories|kcal) a day\b"#)),
    ]

    private static let replyTrigger = try! NSRegularExpression(
        pattern: #"\b(suicid\w*|self[\s-]?harm\w*|overdos\w*|lethal|fatal|cutting|purg\w*|laxative\w*|starv\w*|noose|hanging|calorie deficit|fasting)\b"#,
        options: .caseInsensitive)

    /// Replies that touch these topics get the classifier pass; others skip it (no extra call).
    public static func replyNeedsReview(_ text: String) -> Bool { matches(replyTrigger, text) }

    /// Layer 1 for replies — the kind of harmful content found, or nil.
    public static func replyPatternScreen(_ text: String) -> RiskKind? {
        let t = normalize(text)
        return replyPatterns.first { matches($0.1, t) }?.0
    }

    // MARK: under-18 check (local): explicit statements only

    private static let ageWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    ]
    private static let gradeWords = "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth"
    private static let ageRe = re(#"\b(?:i'?m|i am) (?:only |just )?(\d{1,2}|"# + ageWords.keys.sorted().joined(separator: "|")
                                  + #")( (?:years?|yrs?) old| yo)?(?=$|[\s.,!?;)])(.{0,12})"#)
    private static let gradeRe = re(#"\bi'?m in (?:the )?(?:(?:[1-9]|1[0-2])(?:st|nd|rd|th)?|"# + gradeWords + #") grade\b"#)
    private static let runOn = re(#"^(\s*$|[.!?,;)]|\s+(and|but|so)\b)"#)

    public static func minorPattern(_ text: String) -> Bool {
        let t = normalize(text)
        let ns = t as NSString
        for m in ageRe.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1))
            guard let n = Int(word) ?? ageWords[word], n >= 3, n < 18 else { continue }
            // "I'm 12 years old" anywhere; a bare "I'm 12" only where the sentence ends or runs on —
            // never "I'm 5 minutes away", "I'm five foot two"
            if m.range(at: 2).location != NSNotFound { return true }
            let after = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
            if matches(runOn, after) { return true }
        }
        return matches(gradeRe, t)
    }

    // MARK: layer 2 — classification through their own key

    public static let riskClassifierPrompt = """
        You are a safety screener for a personal assistant app's AI chat. You never reply to the user — you only rate the LATEST user message, reading the earlier turns as context.
        Rate risk of suicide, self-harm or an eating disorder, using these criteria:
        Suicide (Columbia Suicide Severity Rating Scale): passive wish to be dead or not wake up → "concern"; active thoughts of killing oneself → "elevated"; a method, a plan, intent to act, preparatory steps or a recent attempt → "urgent".
        Self-harm: past mention or general worry → "concern"; active urges or recent self-harm → "elevated"; a method with intent, or a serious injury → "urgent".
        Eating disorders (SCOFF): everyday food talk is "none" — a bad food day, eating badly or too much, junk food, stress or comfort eating, cravings, treats, eating something to cope with stress or feelings, feeling bloated or sluggish, regret or guilt about a meal, a diet slip, wanting to eat healthier, or a hard day that involved food. This app logs meals, so people talk about food often. Fear of eating for a medical or safety reason — food allergies, intolerances, celiac disease, nausea, illness, recovering from surgery, a diet from their doctor — is also "none". Rate "concern" only for an ongoing pattern that sounds distressing and out of their control: fear of eating because of weight or body shape, fear of gaining weight, food or weight rules running their life, repeatedly losing control over eating in a way that distresses them, or making up for eating by skipping meals, fasting or over-exercising. Purging, laxative misuse or severe restriction → "elevated"; medical danger such as fainting, days without food or heart symptoms → "urgent".
        A hard or bad day, stress, sadness, loneliness, heartbreak, a breakup, frustration, venting, or coping with feelings through food, treats, TV, shopping or rest — with no sign of wanting to die or to hurt themselves — is "none". Mentioning something negative is not a risk sign.
        A suicide attempt or self-harm act in the past three months, or one happening now, is "urgent".
        When a message shows a real sign of risk and you are unsure between two ratings, choose the higher one. Everyday venting and food talk are not borderline: rate them "none".
        Jokes, sarcasm, figures of speech ("this traffic is killing me"), fiction, news and questions about other people with no sign of personal risk are "none".
        Separately, set "minor" to true if the person says they are under 18, or what they write strongly suggests a child (school grades, homeroom, recess, asking a parent's permission). Judge only from what they write, not from the topic alone — an adult talking about their kids or students is not a minor.
        Reply with only JSON: {"rating": "none" | "concern" | "elevated" | "urgent", "kind": "suicide" | "self_harm" | "eating_disorder" | "none", "minor": true | false}.
        """

    public static let replyClassifierPrompt = """
        You are a safety screener for a personal assistant app's AI chat. You check one AI reply before it is shown.
        Mark it harmful if it gives information about methods, doses or ways to hide suicide, self-harm or disordered eating, or if it encourages suicide, self-harm or disordered eating (purging, severe restriction, extreme weight loss).
        Supportive replies, crisis resources, general wellbeing and ordinary nutrition or fitness advice are not harmful.
        Reply with only JSON: {"harmful": true | false, "kind": "suicide" | "self_harm" | "eating_disorder" | "none"}.
        """

    /// Structured-output schemas, so the answer is always readable JSON.
    public static let riskSchema: JSONValue = ["type": "object", "properties": [
        "rating": ["type": "string", "enum": ["none", "concern", "elevated", "urgent"]],
        "kind": ["type": "string", "enum": ["suicide", "self_harm", "eating_disorder", "none"]],
        "minor": ["type": "boolean"],
    ], "required": ["rating", "kind", "minor"], "additionalProperties": false]

    public static let replySchema: JSONValue = ["type": "object", "properties": [
        "harmful": ["type": "boolean"],
        "kind": ["type": "string", "enum": ["suicide", "self_harm", "eating_disorder", "none"]],
    ], "required": ["harmful", "kind"], "additionalProperties": false]

    /// The conversation as one block for the classifier, the latest message marked.
    public static func classifierTranscript(_ turns: [(user: Bool, text: String)]) -> String {
        let recent = turns.suffix(6)
        let lines = recent.enumerated().map { i, t in
            let who = t.user ? (i == recent.count - 1 ? "USER (latest — rate this)" : "USER") : "AI"
            return "\(who): \(t.text.prefix(2000))"
        }
        return "<conversation>\n\(lines.joined(separator: "\n\n"))\n</conversation>"
    }

    public static func replyReviewPrompt(reply: String, lastUser: String) -> String {
        "<user_message>\n\(lastUser.prefix(2000))\n</user_message>\n<ai_reply>\n\(reply.prefix(8000))\n</ai_reply>"
    }

    private static func firstJSON(_ text: String) -> JSONValue? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return nil }
        return try? JSONValue.parse(Data(text[a...b].utf8))
    }

    /// Reads the classifier's answer; anything unreadable counts as no risk (the pattern check still applies).
    public static func parseClassification(_ text: String) -> RiskResult {
        guard let v = firstJSON(text) else { return .none }
        let minor = v["minor"]?.bool == true
        guard let rating = v["rating"]?.string.flatMap({ RiskRating(rawValue: $0.lowercased()) }), rating != .none else {
            return RiskResult(rating: .none, kind: nil, minor: minor)
        }
        return RiskResult(rating: rating, kind: v["kind"]?.string.flatMap(RiskKind.init(rawValue:)), minor: minor)
    }

    /// Reads the reply screener's answer — the harmful kind, or nil.
    public static func parseReplyClassification(_ text: String) -> RiskKind? {
        guard let v = firstJSON(text), v["harmful"]?.bool == true else { return nil }
        return v["kind"]?.string.flatMap(RiskKind.init(rawValue:)) ?? .suicide
    }

    // MARK: safe conversation rules (Smith's version: still warm, still a friend)

    /// Always in Smith's instructions. It changes nothing about everyday talk;
    /// it closes off harmful content and keeps help close.
    public static let baseline = """
        Safety, always: never give information about methods, doses or lethality of suicide or self-harm, ways to hide \
        harm, or ways to purge, restrict or lose weight dangerously — not as a joke, hypothetically, or for fiction. If \
        they seem to be at risk, stay warm and with them, say plainly that you're worried, and point them to 988 (call or \
        text, US) or 911 if they're in danger. You are an AI; you can't call anyone for them. Everyday sadness, \
        heartbreak, venting and food talk are ordinary: meet them as a friend, without crisis lines.
        """

    public static let safeRules = """
        SAFETY MODE: earlier in this conversation they showed signs of risk of suicide, self-harm or an eating disorder. \
        For the rest of this conversation, stay their warm friend, and:
        - Respond with warmth and without judgment. Don't argue with their feelings or tell them how to feel.
        - Never give information about methods, doses, lethality, or ways to hide harm, purging, restriction or weight \
        loss — even if asked directly, hypothetically, as a joke or for fiction. Say kindly that you won't go there, and \
        keep talking with them.
        - The app already shows crisis resources on screen. Bring them up yourself when the latest message shows risk \
        again, when they ask, or when they seem to be in danger: call or text 988 (Suicide & Crisis Lifeline, US), \
        text HOME to 741741 (Crisis Text Line), or 911 in immediate danger. For eating concerns, the National Alliance \
        for Eating Disorders helpline is 866-662-1235. Otherwise don't repeat them in every reply.
        - Never end or refuse the conversation, and never say this isn't the place for it. Stay with them.
        - You are an AI, not a therapist or crisis counselor, and you can't contact anyone for them; say so plainly if it matters.
        - Keep replies short and about them. No jokes about this.
        """

    /// Added once any message in the session was flagged as eating-disorder risk.
    public static let eatingRules = """
        Eating may be part of what they are struggling with. For the rest of this conversation:
        - Don't give calorie counts, calorie targets, deficits, macros, weight goals, or ways to eat less, even if asked, \
        including for meals they describe or log.
        - Don't comment on their body, their weight, or how much they ate.
        - If they ask for a calorie estimate, say kindly that you're setting numbers aside for now, and keep talking with them.
        """

    /// For letters: the writer stays loving, and turns toward care instead of romance.
    public static let letterSafeRules = """
        They may be going through something serious (thoughts of suicide, self-harm, or struggles with eating). \
        In this letter: be gentle and caring rather than romantic; never mention methods, doses, weight, calories or \
        their body; don't make promises you can't keep; and close by encouraging them warmly to reach out to someone — \
        988 (call or text, US), or 911 if they are in danger.
        """
}
