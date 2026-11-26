import SwiftUI
import UniformTypeIdentifiers
import SmithCore

/// One screen, almost nothing on it.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    var compact = false

    var body: some View {
        let brain = app.brain
        ZStack {
            GlowBackground(mood: app.brain.pill == "DAILY REFLECTION")
            VStack(spacing: 0) {
                topBar
                if app.showChat {
                    ChatView()
                } else {
                    Spacer(minLength: 12)
                    VStack(spacing: 18) {
                        Caps(brain.pill, size: 10, color: Theme.text.opacity(0.75))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        Text(brain.headline)
                            .font(Theme.rounded(compact ? 26 : 38))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 28)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.6), value: brain.headline)
                    }
                    Spacer(minLength: 12)
                }
                orbArea
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
        .background {
            // Esc: stop and start again
            Button("") { app.stopAll() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
    }

    private func send() {
        let t = app.draft
        app.draft = ""
        app.typed(t)
    }

    // MARK: top

    private var topBar: some View {
        VStack(spacing: 14) {
            HStack {
                Text(Self.dateLine()).font(Theme.rounded(13)).foregroundStyle(Theme.dim)
                Spacer()
                if app.showChat {
                    Button("Start over") { app.startOver() }.buttonStyle(.plain).font(Theme.rounded(13, .medium)).foregroundStyle(Theme.dim)
                        .help("Clear this chat. Nothing from it is kept.")
                    Button("Done") { app.endConversation() }.buttonStyle(.plain).font(Theme.rounded(13, .medium)).foregroundStyle(Theme.dim)
                }
                if app.chronicles.isUnlocked {
                    Button { app.chronicles.lock() } label: { Image(systemName: "lock").foregroundStyle(Theme.dim) }
                        .buttonStyle(.plain).help("Lock")
                }
                Button { app.sheet = .settings } label: { Image(systemName: "gearshape").foregroundStyle(Theme.dim) }.buttonStyle(.plain)
            }
            if !app.showChat { chips }
        }
        .padding(.horizontal, 22).padding(.top, compact ? 14 : 24)
    }

    static func dateLine() -> String {
        let f = DateFormatter(); f.dateFormat = "d MMMM, EEEE"; f.locale = Locale(identifier: "en_GB")
        return f.string(from: Date())
    }

    private var chips: some View {
        let o = app.brain.context().overview
        // The next event still to come today (earlier ones have passed).
        let nowHM = Date().formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)", timeZone: .current, calendar: .current))
        let next = o?.events.first { !$0.allDay && ($0.endTime ?? $0.time ?? "") >= nowHM }
        let behind = app.store.snapshot.flatMap { Freshness.daysBehind(exportedAt: $0.exportedAt, today: Day.key()) }
        let row = HStack(spacing: 10) {
                GlassChip(value: next.map { $0.time ?? "All day" } ?? "—", label: next.map { String($0.title.prefix(14)) } ?? ((o?.events.isEmpty ?? true) ? "No events" : "No more events"))
                GlassChip(value: o.map { "\($0.openTasksToday)" } ?? "—", label: "Tasks today")
                GlassChip(value: app.weather.report?.chip ?? "—", label: app.weather.report?.description ?? "Weather")
                TimelineView(.everyMinute) { tl in
                    GlassChip(value: tl.date.formatted(date: .omitted, time: .shortened), label: "Time")
                }
                if let snap = app.store.snapshot {
                    Menu {
                        Button("Import now") { importing = true }
                        Button("Sync now") { Task { await app.sync.syncNow() } }
                        Button("Not today") { app.store.updateLocalSettings { $0.freshness.snoozedDay = Day.key() } }
                    } label: {
                        GlassChip(value: snap.exportedAt.formatted(.dateTime.month(.abbreviated).day()),
                                  label: "Data as of", tint: behind == nil ? nil : Theme.amber)
                    }
                    .menuStyle(.button).buttonStyle(.plain)
                } else {
                    Button { importing = true } label: { GlassChip(value: "Import", label: "Chronicles", tint: Theme.amber) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        // Centred when it fits; scrolls sideways on narrow screens.
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: orb and corners

    private var orbArea: some View {
        VStack(spacing: 6) {
            OrbView(mode: orbMode, level: app.voice.level, size: app.showChat ? (compact ? 56 : 72) : (compact ? 84 : 112))
                .contentShape(Circle())
                .onTapGesture { app.orbTapped() }
                .onLongPressGesture(minimumDuration: 0.5) { app.orbHeld() }
            // Stop: listening (nothing is sent), speaking, or an answer on its way (Esc does the same)
            if app.isBusy {
                Button { app.stopAll() } label: {
                    Label("Stop", systemImage: "stop.circle").font(Theme.rounded(12, .medium))
                        .padding(.horizontal, 12).padding(.vertical, 5).background(Color.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.soft).help("Stop (Esc)")
            }
            Caps(hint, size: 8.5, color: Theme.faint)
            InputBar(text: Bindable(app).draft, prompt: app.showChat ? "Talk or ask something…" : "Explain in detail") { send() }
                .padding(.top, 10)
            if app.showChat {
                Caps("Anything you type or say here is sent to Claude", size: 7.5, color: Theme.faint).padding(.top, 2)
            }
            HStack {
                corner("Today", .today)
                corner("Goals", .goals)
                Spacer()
                corner("Me", .me)
                corner("Letters", .letters)
            }
            .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, compact ? 10 : 18)
        }
    }

    private var hint: String {
        if app.voice.state == .listening { return "Listening · tap when you're done · Esc to cancel" }
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

    private func corner(_ title: String, _ sheet: AppModel.Sheet) -> some View {
        Button { app.sheet = sheet } label: { Caps(title, size: 10, color: Theme.dim).padding(.horizontal, 8).padding(.vertical, 6) }
            .buttonStyle(.plain)
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

    var body: some View {
        let brain = app.brain
        VStack(spacing: 0) {
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
            }
        }
        .sheet(item: $editing) { f in FactEditor(fact: f) }
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
            HStack {
                emoteText(line.text, emote: Theme.dim)
                    .font(Theme.rounded(16)).foregroundStyle(Theme.soft).lineSpacing(7).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16 + ChatBubble.tail).padding(.trailing, 16).padding(.vertical, 13)
                    .background(ChatBubble(tailOnRight: false).fill(Color.white.opacity(0.07)))
                    .overlay(ChatBubble(tailOnRight: false).stroke(.white.opacity(0.05)))
                Spacer(minLength: 40)
            }
        case .note:
            Caps(line.text, size: 9, color: Theme.faint)
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
    let onSend: () -> Void

    var body: some View {
        let listening = app.voice.state == .listening
        HStack(alignment: .bottom, spacing: 10) {
            if listening {
                // What you're saying appears right here as you speak, growing to fit
                heard
            } else {
                TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.faint), axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.rounded(15)).foregroundStyle(Theme.soft)
                    .lineSpacing(4).lineLimit(1...16)
                    .onSubmit(onSend)
            }
            if !text.isEmpty && !listening {
                Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.violet) }
                    .buttonStyle(.plain)
            }
            Button { app.store.updateSettings { $0.muted.toggle() } } label: {
                Image(systemName: app.store.settings.muted ? "speaker.slash" : "speaker.wave.2").foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain).help(app.store.settings.muted ? "Text only (tap to hear replies)" : "Replies are spoken (tap for text only)")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(listening ? Theme.violet.opacity(0.45) : .white.opacity(0.07)))
        .frame(maxWidth: 680)
        .padding(.horizontal, 18)
        .animation(.easeOut(duration: 0.2), value: listening)
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
