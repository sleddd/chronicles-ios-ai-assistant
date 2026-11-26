import Foundation

/// At the end of a conversation: one short summary and up to three facts the
/// person clearly stated. The transcript is then discarded by the caller.
public struct WrapUpResult: Equatable, Sendable {
    public var summary: String
    public var facts: [(text: String, category: Fact.Category)]

    public init(summary: String, facts: [(text: String, category: Fact.Category)]) {
        self.summary = summary; self.facts = facts
    }

    public static func == (a: WrapUpResult, b: WrapUpResult) -> Bool {
        a.summary == b.summary && a.facts.map(\.text) == b.facts.map(\.text)
    }
}

public enum WrapUp {
    public static let instructions = """
        Summarize this conversation between a person and their assistant, Smith, for Smith's memory.
        summary: one or two plain sentences of what was talked about and anything decided, written about "they" \
        (e.g. "Talked through the launch plan; decided to block Thursday morning for it."). Leave out anything about \
        their journal, any money amounts, and health details. No quotes.
        facts: up to three things the person clearly stated about themselves that would help Smith know them \
        (likes, dislikes, routines, people in their life and who they are to them, how they like Smith to talk). \
        Only what they actually said, not guesses or hints. Never health, religion, sexuality, politics, money, or \
        anything from their journal. Short third-person lines, e.g. "Loves Sunday hikes". Use an empty list if none.
        """

    public static var schema: JSONValue {
        ["type": "object", "properties": [
            "summary": ["type": "string"],
            "facts": ["type": "array", "items": ["type": "object", "properties": [
                "text": ["type": "string"],
                "category": ["type": "string", "enum": ["aboutYou", "people", "likes", "dislikes", "routines", "style"]],
            ], "required": ["text", "category"], "additionalProperties": false]],
        ], "required": ["summary", "facts"], "additionalProperties": false]
    }

    /// The conversation as plain text (only the words said; no tool output, no thinking).
    public static func transcript(_ messages: [JSONValue], name: String = "Smith") -> String {
        messages.compactMap { m -> String? in
            let who = m["role"]?.string == "user" ? "Them" : name
            let text: String
            if let s = m["content"]?.string { text = s }
            else { text = (m["content"]?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: " ") }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : "\(who): \(t)"
        }.joined(separator: "\n")
    }

    public static func request(for messages: [JSONValue], model: ClaudeModel) -> ClaudeRequest {
        ClaudeRequest(model: model, maxTokens: 2000, effort: "low", system: [SystemBlock(instructions)],
                      messages: [["role": "user", "content": .string(transcript(messages))]], jsonSchema: schema)
    }

    public static func parse(_ text: String) -> WrapUpResult? {
        guard let v = try? JSONValue.parse(Data(text.utf8)), let summary = v["summary"]?.string else { return nil }
        let facts = (v["facts"]?.array ?? []).compactMap { f -> (String, Fact.Category)? in
            guard let t = f["text"]?.string, !t.isEmpty, let c = f["category"]?.string.flatMap(Fact.Category.init(rawValue:)) else { return nil }
            return (t, c)
        }
        return WrapUpResult(summary: summary, facts: facts)
    }
}
