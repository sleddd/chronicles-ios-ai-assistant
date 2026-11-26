import SwiftUI
import SmithCore

#if os(macOS)
/// Mac start-up runs at launch, whether or not the main window is open
/// (Smith often lives in the menu bar with its window closed).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await SmithApp.macStartup() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        // Quitting locks: the key leaves with the process, and the session ends
        MainActor.assumeIsolated { AppModel.shared.chronicles.lock() }
    }
}
#endif

@main
struct SmithApp: App {
    @State private var app = AppModel.shared
    @Environment(\.scenePhase) private var phase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Smith", id: "main") {
            RootView().environment(app)
                .frame(minWidth: 520, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Chronicles Export…") { NotificationCenter.default.post(name: .smithImport, object: nil) }
                    .keyboardShortcut("i")
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(app)
        } label: {
            Image(systemName: "circle.circle")
        }
        .menuBarExtraStyle(.menu)
        #else
        WindowGroup {
            RootView().environment(app)
        }
        #endif
    }

    #if os(macOS)
    @MainActor static func macStartup() async {
        let app = AppModel.shared
        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif
        HotKey.shared.action = { PanelController.shared.toggle { PanelView().environment(AppModel.shared) } }
        HotKey.shared.register()
        WakeWatcher.shared.onFirstWakeOfDay = {
            let app = AppModel.shared
            // Locked: no panel and no Touch ID prompt on every wake; the briefing waits for an unlock
            guard app.chronicles.isUnlocked else { return false }
            guard app.store.settings.greetOnWake, app.store.settings.lastGreetingDay != Day.key() else { return false }
            // The small panel is for when Smith is tucked away in the menu bar. Already in
            // front (they just unlocked it in its window): the briefing shows there, once.
            if !NSApp.isActive { PanelController.shared.show { PanelView().environment(app) } }
            app.morningBriefing()
            return true
        }
        WakeWatcher.shared.start { AppModel.shared.store.settings.lastGreetingDay }
        WakeWordListener.shared.onWake = { after in
            let app = AppModel.shared
            PanelController.shared.show { PanelView().environment(app) }
            // Locked: the panel shows the unlock screen; what was said is not sent anywhere
            if app.chronicles.isUnlocked {
                if after.count > 3 { app.typedSpoken(after) } else { app.listenOnce() }
            }
            Task {
                try? await Task.sleep(for: .seconds(20))
                // Not while Smith is still listening to them: two taps on one microphone
                while app.voice.state == .listening { try? await Task.sleep(for: .seconds(1)) }
                if app.store.settings.macWakeWord { WakeWordListener.shared.start() }
            }
        }
        if app.store.settings.macWakeWord { WakeWordListener.shared.start() }
    }
    #endif
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if app.chronicles.isLocked { LockView() }
            else if app.safety.isChecking { CheckingView() }
            else if app.safety.needsConsent { ConsentView() }
            else { HomeView() }
        }
            .onOpenURL { app.openURL($0) }
            .onChange(of: phase) { _, p in
                if p == .active { Task { await app.becameActive() } }
                if p == .background { app.chronicles.checkAutoLock() }
            }
            #if os(iOS)
            // The app switcher keeps a picture of the screen: not of the day, the chat or a letter
            .overlay { if phase != .active { Theme.ink.ignoresSafeArea() } }
            #endif
            .onChange(of: app.chronicles.state) { _, _ in
                app.brain.refreshHeadline()
                #if os(macOS)
                // The day's greeting waited for this if Smith was locked when the Mac woke
                if app.chronicles.isUnlocked { WakeWatcher.shared.smithUnlocked() }
                #endif
                Task { await app.safety.refresh() }
            }
            .onChange(of: app.chronicles.lastSync) { _, _ in app.brain.refreshHeadline() }
            .task { await app.becameActive() }
            .onReceive(NotificationCenter.default.publisher(for: .smithTalk)) { _ in app.listenOnce() }
            .preferredColorScheme(.dark)
    }
}

#if os(macOS)
/// The floating panel: the same home screen, compact.
struct PanelView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Group {
            if app.chronicles.isLocked { LockView(compact: true) }
            else if app.safety.isChecking { CheckingView() }
            else if app.safety.needsConsent { ConsentView() }
            else { HomeView(compact: true) }
        }
            .frame(width: 420, height: 640)
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Talk to \(app.store.settings.name)  ⌥Space") {
            PanelController.shared.show { PanelView().environment(app) }
            app.listenOnce()
        }
        Button("Morning briefing") {
            PanelController.shared.show { PanelView().environment(app) }
            app.morningBriefing()
        }
        Button("Open window") { openWindow(id: "main"); NSApp.activate() }
        if app.chronicles.isUnlocked { Button("Lock \(app.store.settings.name) (sign out of Chronicles)") { app.chronicles.lock() } }
        if app.chronicles.state == .notSetUp {
            Button("Connect to Chronicles…") { openWindow(id: "main"); NSApp.activate(); app.chronicles.beginSetup() }
        }
        Divider()
        Button("Import Chronicles export…") { openWindow(id: "main"); NSApp.activate(); NotificationCenter.default.post(name: .smithImport, object: nil) }
        if app.chronicles.isUnlocked { Button("Sync with Chronicles") { Task { await app.chronicles.refresh() } } }
        if app.store.settings.macWakeWord {
            Button("Pause \"Hey Smith\" for 1 hour") { WakeWordListener.shared.pause() }
        }
        Divider()
        Button("Quit Smith") { NSApp.terminate(nil) }
    }
}
#endif

extension AppModel {
    /// Wake word with the request in the same breath: "Hey Smith, what's on today?"
    func typedSpoken(_ text: String) {
        guard chronicles.isUnlocked else { return }
        showChat = true
        Task { await brain.send(text, spoken: true) }
    }
}
