import SwiftUI
import SmithCore

struct TodaySheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GlassSheet(title: "Today") {
            if let o = app.brain.context().overview {
                SectionLabel("Events")
                GlassCard {
                    if o.events.isEmpty { Text("Nothing on the calendar.").foregroundStyle(Theme.dim) }
                    ForEach(Array(o.events.enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .firstTextBaseline) {
                            Text(e.allDay ? "All day" : (e.time ?? "")).font(Theme.rounded(13, .regular)).foregroundStyle(Theme.dim).frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(Theme.rounded(15, .regular))
                                if let l = e.location { Text(l).font(Theme.rounded(12)).foregroundStyle(Theme.dim) }
                            }
                        }
                    }
                }
                SectionLabel("Tasks")
                GlassCard {
                    if o.tasksToday.isEmpty { Text("No tasks planned for today.").foregroundStyle(Theme.dim) }
                    ForEach(o.tasksToday) { t in taskRow(t) }
                }
                if !o.overdue.isEmpty {
                    SectionLabel("Overdue")
                    GlassCard { ForEach(o.overdue) { t in taskRow(t) } }
                }
                if !o.deadlinesSoon.isEmpty {
                    SectionLabel("Coming up")
                    GlassCard {
                        ForEach(o.deadlinesSoon) { t in
                            HStack { Text(t.title); Spacer(); Text(Day.relative(t.deadline ?? "", today: o.today)).foregroundStyle(Theme.dim) }
                                .font(Theme.rounded(14))
                        }
                    }
                }
                if !o.doses.isEmpty {
                    SectionLabel("Doses")
                    GlassCard {
                        ForEach(Array(o.doses.enumerated()), id: \.offset) { _, d in
                            HStack {
                                Text(d.time).foregroundStyle(Theme.dim).frame(width: 52, alignment: .leading)
                                Text("\(d.medication) \(d.dosage)")
                                Spacer()
                                Caps(d.status, size: 8.5, color: d.status == "taken" ? Theme.teal : Theme.dim)
                            }.font(Theme.rounded(14))
                        }
                    }
                }
                if !o.bills.isEmpty {
                    SectionLabel("Bills due")
                    GlassCard {
                        ForEach(Array(o.bills.enumerated()), id: \.offset) { _, b in
                            HStack {
                                Text(b.name)
                                Spacer()
                                Text(Day.relative(b.due, today: o.today)).foregroundStyle(Theme.dim)
                                Caps(b.paid ? "paid" : b.autopay ? "autopay" : "unpaid", size: 8.5, color: b.paid ? Theme.teal : Theme.dim)
                            }.font(Theme.rounded(14))
                        }
                    }
                }
                if !o.priorities.isEmpty {
                    SectionLabel("Priorities")
                    GlassCard { ForEach(o.priorities, id: \.self) { Text("· \($0)").font(Theme.rounded(14)) } }
                }
            } else {
                Text("Import your Chronicles export to see your day here.").foregroundStyle(Theme.dim).padding(.top, 20)
            }
        }
    }

    private func taskRow(_ t: PlanTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: t.status == .done ? "checkmark.circle.fill" : t.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                .foregroundStyle(t.status == .done ? Theme.teal : Theme.dim)
            Text(t.title).font(Theme.rounded(15, .regular)).strikethrough(t.status == .done, color: Theme.dim)
            Spacer()
            if let time = t.scheduledTime { Text(time).font(Theme.rounded(12)).foregroundStyle(Theme.dim) }
        }
    }
}

struct GoalsSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GlassSheet(title: "Goals") {
            if let s = app.store.snapshot {
                if let v = s.vision.overall {
                    SectionLabel("Vision")
                    Text(v).font(Theme.rounded(20)).padding(.bottom, 4)
                }
                ForEach(s.goals.filter { $0.status != "completed" }) { g in
                    let tasks = s.tasks.filter { $0.goalID == g.id }
                    let done = tasks.filter { !$0.isOpen }.count
                    GlassCard {
                        HStack {
                            Text(g.title).font(Theme.rounded(16, .regular))
                            Spacer()
                            Caps(g.status.replacingOccurrences(of: "_", with: " "), size: 8.5)
                        }
                        if !tasks.isEmpty {
                            ProgressView(value: Double(done), total: Double(tasks.count)).tint(Theme.violet)
                            Text("\(done) of \(tasks.count) tasks done").font(Theme.rounded(12)).foregroundStyle(Theme.dim)
                        }
                        ForEach(s.milestones.filter { $0.goalID == g.id }) { m in
                            HStack {
                                Image(systemName: m.status == "completed" ? "checkmark.seal.fill" : "flag").foregroundStyle(Theme.dim)
                                Text(m.title).font(Theme.rounded(13))
                                Spacer()
                                if let t = m.targetDate { Text(Day.short(t)).font(Theme.rounded(12)).foregroundStyle(Theme.dim) }
                            }
                        }
                        if let t = g.targetDate { Caps("Target \(Day.short(t))", size: 8.5, color: Theme.faint) }
                    }
                    .padding(.bottom, 8)
                }
                let areas = s.vision.areas.filter { $0.vision != nil }
                if !areas.isEmpty {
                    SectionLabel("Areas")
                    ForEach(areas, id: \.name) { a in
                        GlassCard { Caps(a.name, size: 9); Text(a.vision ?? "").font(Theme.rounded(14)) }.padding(.bottom, 6)
                    }
                }
            } else {
                Text("Import your Chronicles export to see your goals.").foregroundStyle(Theme.dim).padding(.top, 20)
            }
        }
    }
}

/// ME: everything Smith knows about you, to view, edit, confirm, add or delete.
struct AboutYouView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var editing: Fact?
    @State private var adding = false
    @State private var undo: Fact?
    @State private var confirmClear = false
    @State private var editingSummary: ConversationSummary?

    var body: some View {
        @Bindable var store = app.store
        GlassSheet(title: "About you") {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("", text: $search, prompt: Text("Search what Smith knows").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).focusEffectDisabled()
            }
            .font(Theme.rounded(14))
            .padding(.horizontal, 16).frame(height: 40)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.09)))
            HStack {
                Button { adding = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").foregroundStyle(Theme.teal)
                        Text("Add something about me").foregroundStyle(Theme.text)
                    }
                    .font(Theme.rounded(14, .medium)).padding(.horizontal, 16).frame(height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.13)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Toggle("Learning", isOn: Binding(get: { !store.aboutYou.paused }, set: { store.aboutYou.paused = !$0 }))
                    .toggleStyle(.switch).font(Theme.rounded(12)).fixedSize()
            }
            .padding(.top, 10)

            ForEach(Fact.Category.allCases, id: \.self) { c in
                let facts = store.aboutYou.facts.filter { $0.category == c && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) }
                if !facts.isEmpty {
                    SectionLabel(c.label)
                    VStack(spacing: 14) { ForEach(facts) { f in factRow(f) } }
                }
            }
            if store.aboutYou.facts.isEmpty {
                Text("Nothing yet. \(store.settings.name) learns what you tell him, and you can add things yourself.")
                    .foregroundStyle(Theme.dim).font(Theme.rounded(14)).padding(.top, 16)
            }

            SectionLabel("Conversations")
            if store.conversations.isEmpty { Text("No conversation summaries yet.").foregroundStyle(Theme.dim).font(Theme.rounded(13)) }
            ForEach(store.conversations.reversed()) { c in
                GlassCard {
                    HStack { Caps(Day.short(c.day), size: 8.5); Spacer()
                        Button("Edit") { editingSummary = c }.buttonStyle(.plain).foregroundStyle(Theme.violet)
                        Button { store.deleteConversation(c.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                    }.font(Theme.rounded(12, .medium))
                    Text(c.text).font(Theme.rounded(14))
                }
            }

            if !store.aboutYou.dontLearn.isEmpty {
                SectionLabel("Won't learn again")
                Text(store.aboutYou.dontLearn.map(\.marker).joined(separator: " · ")).font(Theme.rounded(12)).foregroundStyle(Theme.dim)
            }

            Button("Clear everything") { confirmClear = true }.buttonStyle(.plain).foregroundStyle(Theme.rose).font(Theme.rounded(13, .medium)).padding(.top, 24)
        }
        .overlay(alignment: .bottom) {
            if let u = undo {
                HStack { Text("Deleted"); Button("Undo") { store.aboutYou.undoDelete(u); undo = nil }.foregroundStyle(Theme.violet) }
                    .font(Theme.rounded(13, .medium)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 20)
                    .task(id: u.id) { try? await Task.sleep(for: .seconds(5)); if undo?.id == u.id { undo = nil } }
            }
        }
        .sheet(item: $editing) { FactEditor(fact: $0).environment(\.pageClose, nil) }
        .sheet(isPresented: $adding) { FactEditor(fact: nil).environment(\.pageClose, nil) }
        .sheet(item: $editingSummary) { s in SummaryEditor(summary: s).environment(\.pageClose, nil) }
        .alert("Clear everything Smith knows about you?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { store.aboutYou.clearAll(); store.clearConversations() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes every fact and conversation summary on this device and, after the next sync, on the other.") }
    }

    private func factRow(_ f: Fact) -> some View {
        @Bindable var store = app.store
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(f.text).font(Theme.rounded(14, .regular)).lineSpacing(3)
                Caps("\(f.sourceLabel), \(f.updatedAt.formatted(.dateTime.day().month(.abbreviated)))", size: 8, color: Theme.faint)
                if !f.confirmed {
                    HStack(spacing: 14) {
                        Button("Keep") { store.aboutYou.confirm(f.id) }.foregroundStyle(Theme.violet)
                        Button("Not right") { store.aboutYou.delete(f.id) }.foregroundStyle(Theme.dim)
                    }.buttonStyle(.plain).font(Theme.rounded(12, .medium))
                }
            }
            Spacer()
            Button { editing = f } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
            Button { undo = store.aboutYou.delete(f.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(.white.opacity(f.confirmed ? 0.09 : 0.3), style: StrokeStyle(lineWidth: 1, dash: f.confirmed ? [] : [4, 4])))
    }
}

struct FactEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let fact: Fact?
    @State private var text = ""
    @State private var category: Fact.Category = .aboutYou

    var body: some View {
        GlassSheet(title: fact == nil ? "Add something about me" : "Edit") {
            TextField("", text: $text, prompt: Text("e.g. Likes short hikes on Sunday mornings").foregroundStyle(Theme.faint), axis: .vertical)
                .textFieldStyle(.plain).font(Theme.rounded(17)).padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            Picker("Category", selection: $category) { ForEach(Fact.Category.allCases, id: \.self) { Text($0.label).tag($0) } }
                .padding(.top, 10)
            Button("Save") {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                if let fact { app.store.aboutYou.edit(fact.id, text: t, category: category) }
                else { app.store.aboutYou.add(t, category: category) }
                dismiss()
            }
            .buttonStyle(.borderedProminent).tint(Theme.violet).padding(.top, 16)
        }
        .onAppear { text = fact?.text ?? ""; category = fact?.category ?? .aboutYou }
    }
}

struct SummaryEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let summary: ConversationSummary
    @State private var text = ""
    var body: some View {
        GlassSheet(title: "Edit summary") {
            TextField("", text: $text, axis: .vertical).textFieldStyle(.plain).font(Theme.rounded(16))
                .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            Button("Save") { app.store.editConversation(summary.id, text: text); dismiss() }
                .buttonStyle(.borderedProminent).tint(Theme.violet).padding(.top, 16)
        }
        .onAppear { text = summary.text }
    }
}
