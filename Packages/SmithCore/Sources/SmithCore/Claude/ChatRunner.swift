import Foundation

/// A tool Smith runs on the device (tasks, bills, weather…).
public protocol LocalTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    func run(_ input: JSONValue) async throws -> String
}

extension LocalTool {
    public var definition: JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "input_schema": inputSchema,
            "eager_input_streaming": true,
        ]
    }
}

/// Anthropic's server-side web search.
public let webSearchTool: JSONValue = ["type": "web_search_20260209", "name": "web_search", "max_uses": 5]

public enum ChatEvent: Sendable, Equatable {
    /// A complete sentence, already checked against the banned phrases.
    case sentence(String)
    /// Smith is using a tool ("web_search", "find_tasks"…).
    case working(String)
    /// A tool's answer, which went to Claude (for "what was sent"). For web search, the query.
    case lookedUp(tool: String, result: String)
}

public struct ChatTurnResult: Sendable {
    /// The whole reply as shown (phrase-checked).
    public var text: String
    /// The conversation including this turn, ready for the next request.
    public var messages: [JSONValue]
}

/// Runs one user turn: streams the reply, runs local tools, continues paused
/// turns, and hands back sentences as they complete so speech can start early.
public struct ChatRunner: Sendable {
    public let transport: ClaudeTransport
    public let tools: [LocalTool]
    public let phraseGuard: PhraseGuard
    /// Stop a runaway tool loop.
    public var maxRounds = 8

    public init(transport: ClaudeTransport, tools: [LocalTool], phraseGuard: PhraseGuard = PhraseGuard()) {
        self.transport = transport; self.tools = tools; self.phraseGuard = phraseGuard
    }

    public func toolDefinitions(webSearch: Bool) -> [JSONValue] {
        // Sorted by name so the tool list is byte-identical each request (cache prefix).
        tools.sorted { $0.name < $1.name }.map(\.definition) + (webSearch ? [webSearchTool] : [])
    }

    public func run(_ base: ClaudeRequest, onEvent: @Sendable (ChatEvent) -> Void) async throws -> ChatTurnResult {
        var request = base
        var shown: [String] = []
        var splitter = SentenceSplitter()

        func emit(_ raw: String) {
            let clean = phraseGuard.findBanned(in: raw).isEmpty ? raw : phraseGuard.scrub(raw)
            guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            shown.append(clean)
            onEvent(.sentence(clean))
        }

        for _ in 0..<maxRounds {
            var acc = StreamAccumulator()
            for try await e in transport.stream(request) {
                switch try acc.consume(e) {
                case .text(let t): splitter.feed(t).forEach(emit)
                case .blockStarted(let type, let name) where type == "tool_use" || type == "server_tool_use":
                    onEvent(.working(name ?? type))
                default: break
                }
            }
            splitter.flush().forEach(emit)
            request.messages.append(["role": "assistant", "content": .array(acc.contentForEcho)])

            // Web searches: what was searched for (the results go to Claude from the search itself)
            for block in acc.content where block["type"]?.string == "server_tool_use" {
                if let q = block["input"]?["query"]?.string { onEvent(.lookedUp(tool: block["name"]?.string ?? "web_search", result: q)) }
            }
            switch acc.stopReason {
            case "tool_use":
                var results: [JSONValue] = []
                for block in acc.content where block["type"]?.string == "tool_use" {
                    let id = block["id"]?.string ?? ""
                    let name = block["name"]?.string ?? ""
                    if acc.invalidToolIDs.contains(id) {
                        results.append(toolResult(id, "The tool input was incomplete or not valid JSON. Try again.", error: true))
                    } else if let tool = tools.first(where: { $0.name == name }) {
                        do {
                            let out = try await tool.run(block["input"] ?? [:])
                            onEvent(.lookedUp(tool: name, result: out))
                            results.append(toolResult(id, out, error: false))
                        } catch { results.append(toolResult(id, "Tool failed: \(error.localizedDescription)", error: true)) }
                    } else {
                        results.append(toolResult(id, "No tool named \(name).", error: true))
                    }
                }
                // All results go back together in one user message.
                request.messages.append(["role": "user", "content": .array(results)])
            case "pause_turn":
                continue // a long server-side search paused; resend so it carries on
            case "refusal":
                if shown.isEmpty { emit("I can't help with that one.") }
                return ChatTurnResult(text: shown.joined(separator: " "), messages: request.messages)
            default: // end_turn, max_tokens, stop_sequence
                // Cut off (the length limit) while asking for a tool: that request was never
                // answered, and the API refuses any later message while it sits in the history
                if let last = request.messages.indices.last, let content = request.messages[last]["content"]?.array,
                   content.contains(where: { $0["type"]?.string == "tool_use" }) {
                    let kept = content.filter { $0["type"]?.string == "text" && !($0["text"]?.string ?? "").isEmpty }
                    request.messages[last] = ["role": "assistant", "content": .array(kept.isEmpty ? [["type": "text", "text": "(My answer was cut short.)"]] : kept)]
                }
                return ChatTurnResult(text: shown.joined(separator: " "), messages: request.messages)
            }
        }
        return ChatTurnResult(text: shown.joined(separator: " "), messages: request.messages)
    }

    private func toolResult(_ id: String, _ content: String, error: Bool) -> JSONValue {
        var o: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id), "content": .string(content)]
        if error { o["is_error"] = true }
        return .object(o)
    }

    /// One short request with no tools, e.g. a summary. Returns the text.
    public func complete(_ request: ClaudeRequest) async throws -> String {
        var acc = StreamAccumulator()
        for try await e in transport.stream(request) { _ = try acc.consume(e) }
        if acc.stopReason == "refusal" { throw ClaudeError.refused }
        return acc.text
    }
}

/// Splits streamed text into sentences so each can be checked and spoken as soon as it's complete.
public struct SentenceSplitter: Sendable {
    private var buffer = ""
    public init() {}

    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        while let end = Self.boundary(in: buffer) {
            let sentence = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    public mutating func flush() -> [String] {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? [] : [rest]
    }

    /// End of the first complete sentence: . ! ? (plus closing quotes/brackets) followed by whitespace, or a newline.
    static func boundary(in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\n" { return s.index(after: i) }
            if ".!?…".contains(c) {
                var j = s.index(after: i)
                while j < s.endIndex, "\"'”’)]".contains(s[j]) { j = s.index(after: j) }
                if j < s.endIndex, s[j].isWhitespace {
                    // Don't split "e.g. " / "Dr. " / "10.30": need a lowercase-free word before or a real stop.
                    if c == ".", Self.isAbbreviation(before: i, in: s) { i = s.index(after: i); continue }
                    return j
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    static let abbreviations: Set<String> = ["e.g", "i.e", "dr", "mr", "mrs", "ms", "st", "vs", "etc", "approx", "no"]

    static func isAbbreviation(before dot: String.Index, in s: String) -> Bool {
        var start = dot
        while start > s.startIndex {
            let p = s.index(before: start)
            if s[p].isWhitespace { break }
            start = p
        }
        return abbreviations.contains(String(s[start..<dot]).lowercased())
    }
}
