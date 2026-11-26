import AppIntents
import SwiftUI
import SmithCore

/// "Good morning, Smith" — the morning briefing, spoken by Siri.
struct GoodMorningIntent: AppIntent {
    static let title: LocalizedStringResource = "Morning briefing"
    static let description = IntentDescription("Smith greets you and tells you about your day.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        await app.weather.refresh(fahrenheit: app.store.settings.fahrenheit)
        let goal = app.store.settings.goalMentionInBriefing ? ", plus a plain mention of a goal in progress" : ""
        let text = await app.brain.oneShot("""
            [Morning briefing, read aloud by Siri] Greet them warmly, then the time, the weather, today's events and \
            planned tasks, deadlines, bills due soon, medication doses and their top priority\(goal). Keep it short.
            """)
        app.store.updateLocalSettings { $0.lastGreetingDay = Day.key() }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// "Ask Smith …"
struct AskSmithIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Smith"
    static let description = IntentDescription("Ask Smith anything.")

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await AppModel.shared.brain.oneShot(question)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// "What's on my day?"
struct WhatsOnMyDayIntent: AppIntent {
    static let title: LocalizedStringResource = "What's on my day"
    static let description = IntentDescription("Smith tells you what's planned today.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await AppModel.shared.brain.oneShot("What's on my day today? Keep it brief, it will be read aloud.")
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Opens Smith listening, in conversation mode. Link this to the "Hey Smith" Vocal Shortcut.
struct TalkToSmithIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Smith"
    static let description = IntentDescription("Opens Smith, already listening.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = AppModel.shared
        app.brain.conversationMode = true
        #if os(macOS)
        PanelController.shared.show { PanelView().environment(app) }
        #endif
        // Give the window a moment, then start listening.
        try? await Task.sleep(for: .milliseconds(400))
        app.listenOnce()
        return .result()
    }
}

/// "A letter" (signed with whatever name you chose for your letters)
struct LetterFromHenryIntent: AppIntent {
    static let title: LocalizedStringResource = "A letter"
    static let description = IntentDescription("Writes you a letter.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await HenryWriter.write(store: AppModel.shared.store, message: nil)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct SmithShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GoodMorningIntent(), phrases: ["Good morning, \(.applicationName)", "\(.applicationName) morning briefing"],
                    shortTitle: "Morning briefing", systemImageName: "sun.max")
        AppShortcut(intent: AskSmithIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    shortTitle: "Ask Smith", systemImageName: "bubble.left")
        AppShortcut(intent: WhatsOnMyDayIntent(), phrases: ["What's on my day in \(.applicationName)", "\(.applicationName), what's on my day"],
                    shortTitle: "What's on my day", systemImageName: "calendar")
        AppShortcut(intent: TalkToSmithIntent(), phrases: ["Talk to \(.applicationName)", "Hey \(.applicationName)"],
                    shortTitle: "Talk to Smith", systemImageName: "waveform")
        AppShortcut(intent: LetterFromHenryIntent(), phrases: ["A letter from \(.applicationName)", "\(.applicationName), write me a letter"],
                    shortTitle: "A letter", systemImageName: "envelope.open")
    }
}
