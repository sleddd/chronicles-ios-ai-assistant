import SwiftUI
import UniformTypeIdentifiers
import SmithCore

/// One screen, almost nothing on it.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var confirmRemoveChronicles = false
    var compact = false

    var body: some View {
        let brain = app.brain
        ZStack {
            GlowBackground(mood: app.brain.pill == "DAILY REFLECTION")
            VStack(spacing: 0) {
                topBar
                if app.page != .home {
                    pageContent
                } else if app.showChat {
                    ChatView()
                } else {
                    Spacer(minLength: 12)
                    let listening = app.voice.state == .listening
                    VStack(spacing: 22) {
                        if listening {
                            HStack(spacing: 10) {
                                Circle().fill(Theme.teal).frame(width: 8, height: 8)
                                Text("LISTENING").font(Theme.rounded(12, .semibold)).tracking(2.4).foregroundStyle(Theme.text)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Color.black.opacity(0.45), in: Capsule())
                            .transition(.opacity)
                        }
                        Text(brain.headline)
                            .font(Theme.rounded(compact ? 24 : 38))
                            .frame(maxWidth: 900)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.text.opacity(listening ? 0.4 : 1))
                            .animation(.easeInOut(duration: 0.3), value: listening)
                            .padding(.horizontal, 28)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.6), value: brain.headline)
                        // Stats hidden: the greeting and the orb sit together in the middle
                        if app.store.settings.statsHidden { orbBlock.padding(.top, 18) }
                    }
                    Spacer(minLength: 12)
                }
                if app.page == .home {
                    if app.showChat || !app.store.settings.statsHidden { orbBlock }
                    inputArea
                }
            }
            if let msg = app.importMessage { banner(msg) }
        }
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, UTType(exportedAs: "com.fastandcurious.smith.smithdata")]) { result in
            if case .success(let url) = result { app.openURL(url) }
        }
        .alert("Older export", isPresented: Binding(get: { app.pendingOlderImport != nil }, set: { if !$0 { app.pendingOlderImport = nil } })) {
            Button("Import anyway") { if let u = app.pendingOlderImport { app.importFile(u, allowOlder: true) } }
            Button("Skip", role: .cancel) { app.pendingOlderImport = nil }
        } message: { Text("This export is older than the data Smith already has. Import it anyway?") }
        .alert("Delete the export file?", isPresented: Binding(get: { app.deleteSourceOffer != nil }, set: { if !$0 { app.deleteSourceOffer = nil } })) {
            Button("Delete", role: .destructive) { if let u = app.deleteSourceOffer { app.deleteSource(u) } }
            Button("Keep it", role: .cancel) { app.deleteSourceOffer = nil }
        } message: { Text("Smith has what it needs. The export is an unencrypted copy of your Chronicles data.") }
        .onReceive(NotificationCenter.default.publisher(for: .smithImport)) { _ in importing = true }
        .alert("Remove Chronicles data?", isPresented: $confirmRemoveChronicles) {
            Button("Remove", role: .destructive) { app.chronicles.removeChroniclesData(); app.brain.refreshHeadline() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Smith signs out of Chronicles and deletes your tasks, events, goals, habits, bill dates and journal summaries from this device. What Smith knows about you, conversation summaries, letters and settings stay. Connect or import again to bring Chronicles back.")
        }
        .background {
            // Esc: stop and start again
            Button("") { app.stopAll() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
    }

    /// Letters, Goals, Me, Today's details and Settings: full-width pages under the tabs.
    @ViewBuilder private var pageContent: some View {
        Group {
            switch app.page {
            case .letters: LettersView(compact: compact)
            case .today: TodaySheet()
            case .goals: GoalsSheet()
            case .me: AboutYouView()
            case .settings: SettingsView()
            case .home: EmptyView()
            }
        }
        .environment(\.pageClose, { app.page = .home })
        .frame(maxWidth: Self.contentWidth)
        .padding(.horizontal, sidePadding).padding(.top, compact ? 14 : 26).padding(.bottom, compact ? 12 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func send() {
        let t = app.draft
        app.draft = ""
        app.typed(t)
    }

    // MARK: top

    /// Content width, shared by the top row, the stats card and the typing box so their edges line up.
    static let contentWidth: CGFloat = 1040
    private var sidePadding: CGFloat { compact ? 18 : 40 }

    private var topBar: some View {
        VStack(spacing: compact ? 20 : 46) {
            HStack(spacing: 12) {
                tabs
                Spacer(minLength: 8)
                if app.showChat {
                    Button("Start over") { app.startOver() }.buttonStyle(.plain).font(Theme.rounded(13, .medium)).foregroundStyle(Theme.dim)
                        .help("Clear this chat. Nothing from it is kept.")
                    Button("Done") { app.endConversation() }.buttonStyle(.plain).font(Theme.rounded(13, .medium)).foregroundStyle(Theme.dim)
                        .padding(.trailing, 6)
                }
                chroniclesPill
                gearMenu
            }
            if app.page == .home && !app.showChat && !app.store.settings.statsHidden {
                // Tap the card for the whole day
                statsCard.contentShape(Rectangle()).onTapGesture { app.page = .today }
                    .help("Open today's details")
            }
        }
        .frame(maxWidth: Self.contentWidth)
        .padding(.horizontal, sidePadding).padding(.top, compact ? 12 : 22)
        .frame(maxWidth: .infinity)
    }

    /// Today is home; Goals, Me and Letters open over it.
    private var tabs: some View {
        HStack(spacing: compact ? 16 : 30) {
            tab("Today", selected: app.page == .home || app.page == .today) { app.page = .home }
            tab("Goals", selected: app.page == .goals) { app.page = .goals }
            tab("Me", selected: app.page == .me) { app.page = .me }
            tab("Letters", selected: app.page == .letters) { app.page = .letters }
            if app.page == .home && !app.showChat { statsMenu }
        }
    }

    /// One button: hide or show the stats card.
    private var statsMenu: some View {
        let hidden = app.store.settings.statsHidden
        return Button { app.store.updateLocalSettings { $0.statsHidden.toggle() } } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(hidden ? "SHOW STATS" : "HIDE STATS").font(Theme.rounded(compact ? 11 : 13, .medium)).tracking(2.2)
                    .foregroundStyle(Theme.dim)
                Capsule().fill(.clear).frame(height: 2.5)
            }
            .fixedSize()
            .padding(.top, 10)
        }
        .buttonStyle(.plain)
    }

    private func tab(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased()).font(Theme.rounded(compact ? 11 : 13, .medium)).tracking(2.2)
                    .foregroundStyle(selected ? Theme.text : Theme.dim)
                Capsule().fill(selected ? Theme.teal : .clear).frame(height: 2.5)
            }
            .fixedSize()
            .padding(.top, 10)
        }
        .buttonStyle(.plain)
    }

    private var chroniclesPill: some View {
        let connected = app.chronicles.isUnlocked
        return Button {
            if connected { app.sheet = .settings } else { app.chronicles.beginSetup() }
        } label: {
            // Just the book and a dot: teal when connected
            HStack(spacing: 8) {
                Image(systemName: "book.closed").foregroundStyle(Theme.teal)
                Circle().fill(connected ? Theme.teal : Theme.faint).frame(width: 7, height: 7)
            }
            .font(.system(size: compact ? 14 : 17))
            .padding(.horizontal, 14).frame(height: compact ? 36 : 44)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .help(connected ? "Chronicles connected" : "Connect to Chronicles")
        .accessibilityLabel(connected ? "Chronicles connected" : "Connect to Chronicles")
    }

    /// Settings, the data (import, sync) and the account (lock, sign out).
    private var gearMenu: some View {
        Menu {
            Button { app.sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
            Toggle(isOn: Binding(get: { app.store.settings.muted }, set: { on in
                app.store.updateSettings { $0.muted = on }
                if on { app.voice.stopSpeaking() }
            })) { Label("Mute Smith (text only)", systemImage: "speaker.slash") }
            Divider()
            Button { importing = true } label: { Label("Import now", systemImage: "square.and.arrow.down") }
            Button { Task { await app.chronicles.refresh() } } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button { app.chronicles.lock() } label: { Label("Lock", systemImage: "lock") }
            Button { app.chronicles.signOut() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
            Divider()
            Button(role: .destructive) { confirmRemoveChronicles = true } label: {
                Label("Remove Chronicles data…", systemImage: "trash")
            }
        } label: {
            Image(systemName: "gearshape").font(.system(size: compact ? 15 : 18)).foregroundStyle(Theme.soft)
                .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
                .background(Color.black.opacity(0.25), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.13)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Settings and account")
    }

    /// One glass card: the time with date and weather, events, tasks and priorities.
    private var statsCard: some View {
        let o = app.brain.overviewForDisplay()
        let nowHM = Date().formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)", timeZone: .current, calendar: .current))
        let remaining = o?.events.filter { $0.allDay || ($0.endTime ?? $0.time ?? "") >= nowHM } ?? []
        let next = remaining.first { !$0.allDay }
        let overdue = o?.overdue.count ?? 0
        let tasks = o.map { $0.openTasksToday + overdue }

        // The date ("Wed" over a small "Nov 25"), then the time with the weather under it
        let date = TimelineView(.everyMinute) { tl in
            stat(value: tl.date.formatted(.dateTime.weekday(.abbreviated)),
                 label: Text(tl.date.formatted(.dateTime.month(.abbreviated).day())))
        }
        let clock = TimelineView(.everyMinute) { tl in
            let full = tl.date.formatted(date: .omitted, time: .shortened)
            // "11:27 PM" (macOS puts a narrow no-break space before PM)
            let parts = full.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(parts.first ?? full).font(Theme.rounded(compact ? 18 : 21, .light))
                    if parts.count > 1 { Text(parts[1]).font(Theme.rounded(compact ? 9 : 11)).foregroundStyle(Theme.dim) }
                }
                .foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    if let w = app.weather.report {
                        Image(systemName: Self.weatherSymbol(w.description)).foregroundStyle(Theme.teal)
                        Text("\(w.chip) \(w.description)")
                    } else {
                        Text("Time")
                    }
                }
                .font(Theme.rounded(compact ? 11 : 13)).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        let allDay = remaining.first { $0.allDay }
        let eventLabel = next.map { "Next: \($0.time ?? "") \($0.title)" }
            ?? allDay.map { "All day: \($0.title)" }
            ?? ((o?.events.isEmpty ?? true) ? "No events today" : "No more events")
        let events = stat(value: "\(remaining.count)", label: Text(eventLabel))
        let taskStat = stat(value: tasks.map(String.init) ?? "—", tint: overdue > 0 ? Theme.amber : nil,
                            label: overdue > 0 ? Text("Tasks · ") + Text("\(overdue) overdue").foregroundColor(Theme.amber) : Text("Tasks today"))
        let priorities = stat(value: o.map { "\($0.priorities.count)" } ?? "—", label: Text("Priorities"))
        let divider = Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: compact ? 30 : 38)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                // The date and time take just the room they need; the counts share the rest
                date.fixedSize().padding(.trailing, 28)
                divider
                clock.fixedSize().padding(.horizontal, 28)
                divider
                events.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28).padding(.trailing, 10)
                divider
                taskStat.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28).padding(.trailing, 10)
                divider
                priorities.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28)
            }
            // Narrow (the floating panel, a small window): two by two
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 16) {
                date; clock; events; taskStat; priorities
            }
        }
        .padding(.horizontal, compact ? 18 : 32).padding(.vertical, compact ? 12 : 18)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.09)))
    }

    private func stat(value: String, tint: Color? = nil, label: Text) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(Theme.rounded(compact ? 18 : 21, .light)).foregroundStyle(tint ?? Theme.text)
            label.font(Theme.rounded(compact ? 11 : 13)).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.85)
        }
    }

    static func weatherSymbol(_ description: String) -> String {
        switch description.lowercased() {
        case "clear": "sun.max"
        case "mostly clear", "partly cloudy": "cloud.sun"
        case "foggy": "cloud.fog"
        case "drizzle", "rain", "showers": "cloud.rain"
        case "snow", "snow showers": "cloud.snow"
        case "thunderstorms": "cloud.bolt"
        default: "cloud"
        }
    }

    // MARK: orb and corners

    /// The orb, any notice, and the hint under it.
    private var orbBlock: some View {
        VStack(spacing: 6) {
            OrbView(mode: orbMode, level: app.voice.level, size: app.showChat ? (compact ? 56 : 72) : (compact ? 80 : 112))
                .contentShape(Circle())
                .onTapGesture { app.orbTapped() }
                .onLongPressGesture(minimumDuration: 0.5) { app.orbHeld() }
            if let notice = app.safety.notice {
                Text(notice).font(Theme.rounded(12)).foregroundStyle(Theme.amber).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Caps(hint, size: compact ? 9 : 11.5, color: Theme.dim).padding(.top, 8)
        }
    }

    /// The typing box at the bottom.
    private var inputArea: some View {
        VStack(spacing: 6) {
            InputBar(text: Bindable(app).draft, prompt: app.showChat ? "Talk or ask something…" : "Explain in detail", sidePadding: sidePadding) { send() }
                .padding(.top, 22)
            if app.showChat {
                Caps("Anything you type or say here is sent to Claude", size: 7.5, color: Theme.faint).padding(.top, 2)
            }
            Color.clear.frame(height: compact ? 12 : 22)
        }
    }

    private var hint: String {
        if app.voice.state == .listening { return "Tap to finish" }
        if app.brain.conversationMode { return "Conversation · say \"that's all\" to finish" }
        return "Tap to talk · hold for conversation"
    }

    private var orbMode: OrbView.Mode {
        switch app.voice.state {
        case .listening: .listening
        case .speaking: .speaking
        case .idle: app.brain.isThinking ? .thinking : .idle
        }
    }

    private func banner(_ msg: String) -> some View {
        VStack {
            Spacer()
            Text(msg).font(Theme.rounded(13, .regular)).padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 150)
                .onTapGesture { app.importMessage = nil }
                .task(id: msg) { try? await Task.sleep(for: .seconds(6)); if app.importMessage == msg { app.importMessage = nil } }
        }
    }
}

/// Same background; your messages are white pills on the right, Smith's are plain text with a thin accent bar.
struct ChatView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: Fact?
    /// The reply being heard again.
    @State private var replayingID: UUID?

    var body: some View {
        let brain = app.brain
        VStack(spacing: 0) {
            // An urgent sign: help stays pinned at the top while the chat goes on
            if app.safety.pinned {
                ResourcesCard(kind: app.safety.lastKind, urgent: true, compact: true).padding(.top, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(brain.lines) { line in row(line).id(line.id) }
                        if let w = brain.workingOn { Caps(w, size: 9).padding(.leading, 14) }
                        else if brain.isThinking { ProgressView().controlSize(.small).padding(.leading, 14) }
                        ForEach(brain.noted) { f in notedPill(f) }
                        UndoChips()
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                }
                .onChange(of: brain.lines) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .sheet(item: $editing) { f in FactEditor(fact: f).environment(\.pageClose, nil) }
    }

    @ViewBuilder private func row(_ line: ChatLine) -> some View {
        switch line.who {
        case .you:
            let isLast = line.id == app.brain.lastTurnLineID
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Spacer(minLength: 50)
                    Text(line.text).font(Theme.rounded(15, .regular)).foregroundStyle(Theme.soft)
                        .lineSpacing(5).textSelection(.enabled)
                        .padding(.leading, 16).padding(.trailing, 16 + ChatBubble.tail).padding(.vertical, 11)
                        .background(ChatBubble(tailOnRight: true).fill(Color.black.opacity(0.78)))
                        .overlay(ChatBubble(tailOnRight: true).stroke(.white.opacity(0.06)))
                }
                if isLast {
                    // The latest message can be taken back: to fix and send again, or gone
                    HStack(spacing: 14) {
                        Button { app.editLast() } label: { Label("Edit", systemImage: "pencil") }
                        Button { app.deleteLast() } label: { Label("Delete", systemImage: "trash") }
                    }
                    .buttonStyle(.plain).font(Theme.rounded(11, .medium)).foregroundStyle(Theme.faint)
                }
            }
            .contextMenu {
                if isLast {
                    Button("Edit and send again") { app.editLast() }
                    Button("Delete", role: .destructive) { app.deleteLast() }
                }
                Button("Start over") { app.startOver() }
            }
        case .smith:
            // A light, faded bubble with its point on the left; emotes in soft italics
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    emoteText(line.text, emote: Theme.dim)
                        .font(Theme.rounded(16)).foregroundStyle(Theme.soft).lineSpacing(7).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 16 + ChatBubble.tail).padding(.trailing, 16).padding(.vertical, 13)
                        .background(ChatBubble(tailOnRight: false).fill(Color.white.opacity(0.07)))
                        .overlay(ChatBubble(tailOnRight: false).stroke(.white.opacity(0.05)))
                    Spacer(minLength: 40)
                }
                // Hear it again (loading while the voice is made, Stop while it plays)
                let mine = replayingID == line.id
                let controls = HStack(spacing: 18) {
                    HearButton(busy: mine && app.voice.state == .speaking, loading: mine && app.voice.preparing, compact: true) {
                        replayingID = line.id
                        app.voice.preview(app.smithSpeaker, text: line.text)
                    } stop: { app.voice.stopSpeaking() }
                    .font(.system(size: 13))
                    .foregroundStyle(mine && app.voice.state == .speaking ? Theme.teal : Theme.faint)
                    .help("Hear it again")
                    if line.id == app.brain.lines.last?.id && app.brain.canRegenerate {
                        Button { Task { await app.brain.regenerate() } } label: {
                            HStack(spacing: 5) { Image(systemName: "arrow.clockwise"); Text("Regenerate") }
                                .font(Theme.rounded(12, .medium)).fixedSize()
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.faint)
                        .help("Answer again, differently")
                    }
                }
                // One row: hear it, regenerate, then "What was sent" to their right (its details open below)
                if let sent = line.sent {
                    SentDisclosure(info: sent) { controls }.padding(.leading, 14 + ChatBubble.tail)
                } else {
                    controls.padding(.leading, 14 + ChatBubble.tail)
                }
            }
        case .note:
            Caps(line.text, size: 9, color: Theme.faint)
        case .resources:
            ResourcesCard(kind: line.kind, urgent: app.safety.pinned)
        }
    }

    private func notedPill(_ f: Fact) -> some View {
        HStack(spacing: 10) {
            Text("\(app.store.settings.name) noted: \(f.text)").font(Theme.rounded(13, .regular)).foregroundStyle(Theme.soft)
            Button("Edit") { editing = f }.buttonStyle(.plain).font(Theme.rounded(12, .medium)).foregroundStyle(Theme.violet)
            Button("Undo") { app.store.aboutYou.delete(f.id, marker: nil); app.brain.dismissNoted(f.id) }
                .buttonStyle(.plain).font(Theme.rounded(12, .medium)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.black.opacity(0.6), in: Capsule())
    }
}

/// The typing box: a dark pill under the orb, with the text-only toggle.
struct InputBar: View {
    @Environment(AppModel.self) private var app
    @Binding var text: String
    let prompt: String
    var sidePadding: CGFloat = 40
    let onSend: () -> Void

    var body: some View {
        let listening = app.voice.state == .listening
        HStack(alignment: .bottom, spacing: 10) {
            if listening {
                // What you're saying appears right here as you speak, growing to fit
                heard
            } else {
                TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.faint), axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.rounded(17)).foregroundStyle(Theme.soft)
                    .lineSpacing(4).lineLimit(1...16)
                    .focusEffectDisabled()
                    .onSubmit(onSend)
            }
            if !text.isEmpty && !listening {
                Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.violet) }
                    .buttonStyle(.plain)
            }
            // Stop: listening, speaking or an answer on its way (Esc does the same)
            if app.isBusy {
                Button { app.stopAll() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 19)).foregroundStyle(Theme.rose)
                }
                .buttonStyle(.plain).help("Stop (Esc)").transition(.opacity)
            }
            // Dictate into the box: what you say lands here to edit or add to before sending
            // (while the orb is listening, this stops and moves your words here instead of sending)
            Button { app.dictateToBox() } label: {
                Image(systemName: listening ? "mic.fill" : "mic").font(.system(size: 17))
                    .foregroundStyle(listening ? Theme.teal : Theme.dim)
            }
            .buttonStyle(.plain).help(listening ? "Stop and edit in the box" : "Dictate into the box")
            Button {
                app.store.updateSettings { $0.muted.toggle() }
                if app.store.settings.muted { app.voice.stopSpeaking() }
            } label: {
                Image(systemName: app.store.settings.muted ? "speaker.slash" : "speaker.wave.2")
                    .foregroundStyle(app.store.settings.muted ? Theme.amber : Theme.dim)
            }
            .buttonStyle(.plain).help(app.store.settings.muted ? "Text only (tap to hear replies)" : "Replies are spoken (tap for text only)")
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(listening ? Theme.teal.opacity(0.45) : .white.opacity(0.1)))
        .frame(maxWidth: HomeView.contentWidth)
        .padding(.horizontal, sidePadding)
        .animation(.easeOut(duration: 0.2), value: listening)
        .animation(.easeOut(duration: 0.2), value: app.isBusy)
    }

    /// The live transcript in the box: one line to start, growing with what
    /// you say. Past about fourteen lines the oldest words slide off the top.
    private var heard: some View {
        let words = app.voice.partialTranscript
        let shown = words.count > 1400 ? "…" + words.suffix(1400) : words
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 13)).foregroundStyle(Theme.violet)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(words.isEmpty ? "Listening…" : shown)
                .font(Theme.rounded(15)).lineSpacing(4)
                .foregroundStyle(words.isEmpty ? Theme.faint : Theme.soft)
                .lineLimit(14).truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension Notification.Name {
    static let smithImport = Notification.Name("smith.import")
    static let smithTalk = Notification.Name("smith.talk")
}

/// Under each of Smith's replies: what was sent to Claude to write it. Collapsed;
/// each part opens on its own.
struct SentDisclosure<Leading: View>: View {
    let info: SentInfo
    /// What sits to the left of the "What was sent" switch, on the same row.
    @ViewBuilder var leading: Leading
    @State private var open = false
    @State private var openParts: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
            leading
            // The controls stay on the left; "Sent to Claude" sits at the far right of the row
            Spacer(minLength: 12)
            Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("Sent to Claude").font(Theme.rounded(11, .medium))
                }
                .foregroundStyle(Theme.faint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("See exactly what went to Claude for this reply")
            }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(info.parts) { part in
                        let partOpen = openParts.contains(part.id)
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                if partOpen { openParts.remove(part.id) } else { openParts.insert(part.id) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: partOpen ? "minus" : "plus").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.teal)
                                    Text(part.title).font(Theme.rounded(12, .medium)).foregroundStyle(Theme.dim)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if partOpen {
                                Text(part.text)
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim).lineSpacing(3)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: 640, alignment: .leading)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.07)))
            }
        }
    }
}
