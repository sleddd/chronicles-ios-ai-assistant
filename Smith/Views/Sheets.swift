import SwiftUI
import SmithCore

/// Today: the schedule, the tasks to do, and the priorities. Checkboxes only
/// while Smith is connected to Chronicles, where ticking one saves it there.
struct TodaySheet: View {
    @Environment(AppModel.self) private var app
    /// Ticked here and not yet back from Chronicles: shown at once, put back if the save fails.
    @State private var taskTicks: [String: Bool] = [:]
    @State private var priorityTicks: [String: Bool] = [:]
    @State private var newPriority = ""
    @State private var shoppingTicks: [String: Bool] = [:]
    @State private var doseTicks: [String: Bool] = [:]
    @State private var habitCounts: [String: Int] = [:]
    @State private var exerciseTicks: [String: Bool] = [:]
    /// The shopping list picked here (its entry id); remembered on this device only.
    @AppStorage("todayShoppingList") private var chosenList = ""
    @State private var newWin = ""
    @State private var newItem = ""

    var body: some View {
        GlassSheet(title: "") {
            if let o = app.brain.overviewForDisplay() {
                let canTick = app.chronicles.isUnlocked
                // The first heading sits at the top (no title row above it)
                Caps("Schedule", size: 11).padding(.bottom, 4)
                GlassCard {
                    if o.events.isEmpty { Text("Nothing on the calendar.").foregroundStyle(Theme.dim) }
                    ForEach(Array(o.events.enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .firstTextBaseline) {
                            Text(e.allDay ? "All day" : [e.time, e.endTime].compactMap { $0 }.joined(separator: "–"))
                                .font(Theme.rounded(13, .regular)).foregroundStyle(Theme.dim).frame(width: 96, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(Theme.rounded(15, .regular))
                                if let l = e.location { Text(l).font(Theme.rounded(12)).foregroundStyle(Theme.dim) }
                            }
                        }
                    }
                }
                SectionLabel("Tasks")
                GlassCard {
                    let tasks = o.tasksToday + o.overdue
                    if tasks.isEmpty { Text("No tasks for today.").foregroundStyle(Theme.dim) }
                    ForEach(tasks) { t in taskRow(t, o, canTick: canTick) }
                }
                if !o.doses.isEmpty {
                    SectionLabel("Medications")
                    GlassCard {
                        ForEach(Array(o.doses.enumerated()), id: \.offset) { _, d in
                            let key = "\(d.medicationID)|\(d.time)"
                            let taken = doseTicks[key] ?? (d.status == "taken")
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                if canTick { checkbox(taken) { tickDose(d, key: key, !taken) } } else { Text("·").foregroundStyle(Theme.dim) }
                                Text(d.time).font(Theme.rounded(13, .regular)).foregroundStyle(Theme.dim).frame(width: 46, alignment: .leading)
                                Text([d.medication, d.dosage].filter { !$0.isEmpty }.joined(separator: " "))
                                    .font(Theme.rounded(15, .regular)).strikethrough(taken, color: Theme.dim)
                                    .foregroundStyle(taken ? Theme.dim : Theme.text)
                                Spacer()
                                if d.status == "skipped" && doseTicks[key] == nil { Caps("skipped", size: 8.5) }
                            }
                        }
                    }
                }
                if !o.habits.isEmpty {
                    SectionLabel("Habits")
                    GlassCard {
                        ForEach(o.habits, id: \.id) { h in
                            let count = habitCounts[h.id] ?? h.count
                            let done = count >= h.target
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                if canTick { checkbox(done) { tickHabit(h, count: count) } } else { Text("·").foregroundStyle(Theme.dim) }
                                Text(h.name).font(Theme.rounded(15, .regular)).strikethrough(done, color: Theme.dim)
                                    .foregroundStyle(done ? Theme.dim : Theme.text)
                                Spacer()
                                if h.target > 1 { Text("\(min(count, h.target)) of \(h.target)").font(Theme.rounded(12)).foregroundStyle(Theme.dim) }
                            }
                        }
                    }
                }
                if !o.exercise.isEmpty {
                    SectionLabel("Exercise")
                    GlassCard {
                        ForEach(o.exercise, id: \.key) { slot in
                            let done = exerciseTicks[slot.key] ?? slot.done
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                if canTick { checkbox(done) { tickExercise(slot, !done) } } else { Text("·").foregroundStyle(Theme.dim) }
                                Text(slot.time).font(Theme.rounded(13, .regular)).foregroundStyle(Theme.dim).frame(width: 46, alignment: .leading)
                                Text(slot.routine.name).font(Theme.rounded(15, .regular)).strikethrough(done, color: Theme.dim)
                                    .foregroundStyle(done ? Theme.dim : Theme.text)
                                Spacer()
                                if slot.routine.minutes > 0 { Text("\(slot.routine.minutes) min").font(Theme.rounded(12)).foregroundStyle(Theme.dim) }
                            }
                        }
                    }
                }
                if !o.priorityItems.isEmpty || canTick {
                    SectionLabel("Priorities")
                    GlassCard {
                        ForEach(o.priorityItems, id: \.key) { p in
                            let done = priorityTicks[p.key] ?? p.done
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                if canTick {
                                    checkbox(done) { tickPriority(p, !done) }
                                } else {
                                    Text("·").foregroundStyle(Theme.dim)
                                }
                                Text(p.text).font(Theme.rounded(15, .regular)).strikethrough(done, color: Theme.dim)
                                    .foregroundStyle(done ? Theme.dim : Theme.text)
                            }
                        }
                        if canTick {
                            HStack(spacing: 10) {
                                Image(systemName: "plus").foregroundStyle(Theme.dim).frame(width: 20)
                                TextField("", text: $newPriority, prompt: Text("Add a priority").foregroundStyle(Theme.faint))
                                    .textFieldStyle(.plain).font(Theme.rounded(15, .regular))
                                    .onSubmit(addPriority)
                            }
                        }
                    }
                }
                if !o.wins.isEmpty || canTick {
                    SectionLabel("Wins")
                    GlassCard {
                        if o.wins.isEmpty { Text("No wins yet.").foregroundStyle(Theme.dim) }
                        ForEach(o.wins, id: \.id) { w in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Theme.amber).frame(width: 20)
                                Text(w.text).font(Theme.rounded(15, .regular))
                            }
                        }
                        if canTick { addBox("Add a win", text: $newWin, onSubmit: addWin) }
                    }
                }
                if let list = o.shoppingLists.first(where: { $0.entryID == chosenList }) ?? o.shoppingLists.first {
                    shoppingHeader(o.shoppingLists, showing: list)
                    GlassCard {
                        if list.items.isEmpty { Text("Nothing on the list.").foregroundStyle(Theme.dim) }
                        ForEach(list.items, id: \.id) { item in
                            let got = shoppingTicks[item.id] ?? item.checked
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                if canTick {
                                    checkbox(got) { tickShopping(item.id, on: list.entryID, !got) }
                                } else {
                                    Text("·").foregroundStyle(Theme.dim)
                                }
                                Text(item.name).font(Theme.rounded(15, .regular)).strikethrough(got, color: Theme.dim)
                                    .foregroundStyle(got ? Theme.dim : Theme.text)
                            }
                        }
                        if canTick { addBox("Add an item", text: $newItem) { addItem(to: list.entryID) } }
                    }
                }
            } else {
                Text("Connect to Chronicles, or import an export, to see your day here.").foregroundStyle(Theme.dim).padding(.top, 20)
            }
        }
        // Fresh from Chronicles: what it says now wins over what was ticked here
        .onChange(of: app.store.snapshot?.exportedAt) {
            taskTicks = [:]; priorityTicks = [:]; shoppingTicks = [:]; doseTicks = [:]; habitCounts = [:]; exerciseTicks = [:]
        }
    }

    private func checkbox(_ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17)).foregroundStyle(on ? Theme.teal : Theme.dim).frame(width: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Done" : "Not done")
    }

    private func taskRow(_ t: PlanTask, _ o: DayOverview, canTick: Bool) -> some View {
        let done = taskTicks[t.id] ?? (t.status == .done)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if canTick {
                    checkbox(done) { tickTask(t.id, !done) }
                } else {
                    Text("·").foregroundStyle(Theme.dim)
                }
                Text(t.title).font(Theme.rounded(15, .regular)).strikethrough(done, color: Theme.dim)
                    .foregroundStyle(done ? Theme.dim : Theme.text)
                Spacer()
                if let time = t.scheduledTime { Text(time).font(Theme.rounded(12)).foregroundStyle(Theme.dim) }
            }
            if !done, let b = o.blockedBy[t.id], !b.isEmpty {
                Text("Blocked by " + b.joined(separator: " · ")).font(Theme.rounded(12)).foregroundStyle(Theme.amber)
                    .padding(.leading, 30)
            }
        }
    }

    private func tickTask(_ id: String, _ done: Bool) {
        taskTicks[id] = done
        Task { if !(await app.chronicles.setTask(id, done: done)) { taskTicks[id] = nil } }
    }

    private func addBox(_ prompt: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").foregroundStyle(Theme.dim).frame(width: 20)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.faint))
                .textFieldStyle(.plain).font(Theme.rounded(15, .regular))
                .onSubmit(onSubmit)
        }
    }

    private func addWin() {
        let text = newWin
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        newWin = ""
        Task { if !(await app.chronicles.addWin(text)) { newWin = text } }
    }

    private func addItem(to listID: String) {
        let text = newItem
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        newItem = ""
        Task { if !(await app.chronicles.addShoppingItem(text, toList: listID)) { newItem = text } }
    }

    /// The list's name; with more than one active list, a menu of them all to switch between.
    @ViewBuilder private func shoppingHeader(_ lists: [ShoppingList], showing list: ShoppingList) -> some View {
        if lists.count > 1 {
            Menu {
                ForEach(lists, id: \.entryID) { l in
                    Button {
                        chosenList = l.entryID
                    } label: {
                        if l.entryID == list.entryID { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Caps(list.title, size: 11)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                    Text("\(lists.count) lists").font(Theme.rounded(11)).foregroundStyle(Theme.faint)
                }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .padding(.top, 34).padding(.bottom, 4)
            .help("Switch shopping lists")
        } else {
            SectionLabel(list.title)
        }
    }

    private func tickDose(_ d: DayOverview.Dose, key: String, _ taken: Bool) {
        doseTicks[key] = taken
        Task {
            if !(await app.chronicles.setDose(medicationID: d.medicationID, time: d.time, taken: taken)) { doseTicks[key] = nil }
        }
    }

    /// Not done yet: one more check-in. Done: one fewer (so a tick can be taken back).
    private func tickHabit(_ h: DayOverview.HabitToday, count: Int) {
        let add = count < h.target
        habitCounts[h.id] = max(0, count + (add ? 1 : -1))
        Task { if !(await app.chronicles.setHabit(h.id, add: add)) { habitCounts[h.id] = nil } }
    }

    private func tickExercise(_ slot: DayOverview.ExerciseSlot, _ done: Bool) {
        exerciseTicks[slot.key] = done
        Task { if !(await app.chronicles.setExercise(slot, done: done)) { exerciseTicks[slot.key] = nil } }
    }

    private func tickShopping(_ id: String, on listID: String, _ got: Bool) {
        shoppingTicks[id] = got
        Task { if !(await app.chronicles.setShoppingItem(id, onList: listID, got: got)) { shoppingTicks[id] = nil } }
    }

    private func tickPriority(_ item: PriorityList.Item, _ done: Bool) {
        priorityTicks[item.key] = done
        Task { if !(await app.chronicles.setPriority(item, done: done)) { priorityTicks[item.key] = nil } }
    }

    private func addPriority() {
        let text = newPriority
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        newPriority = ""
        Task { if !(await app.chronicles.addPriority(text)) { newPriority = text } }
    }
}

struct GoalsSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GlassSheet(title: "Goals") {
            if let s = app.store.snapshot {
                if let v = s.vision.overall {
                    SectionLabel("Vision")
                    Text(v).font(Theme.rounded(17)).lineSpacing(8)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 24)
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
                    VStack(spacing: 24) { ForEach(facts) { f in factRow(f) } }
                }
            }
            if store.aboutYou.facts.isEmpty {
                Text("Nothing yet. \(store.settings.name) learns what you tell him, and you can add things yourself.")
                    .foregroundStyle(Theme.dim).font(Theme.rounded(14)).padding(.top, 16)
            }

            SectionLabel("Conversations")
            if store.conversations.isEmpty { Text("No conversation summaries yet.").foregroundStyle(Theme.dim).font(Theme.rounded(13)) }
            VStack(spacing: 24) {
            ForEach(store.conversations.reversed()) { c in
                GlassCard {
                    HStack { Caps(Day.short(c.day), size: 8.5); Spacer()
                        Button("Edit") { editingSummary = c }.buttonStyle(.plain).foregroundStyle(Theme.violet)
                        Button { store.deleteConversation(c.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                    }.font(Theme.rounded(12, .medium))
                    Text(c.text).font(Theme.rounded(14))
                }
            }
            }

            if !store.aboutYou.dontLearn.isEmpty {
                SectionLabel("Won't learn again")
                // Each can be removed: these words go along with every request, so they're yours to clear
                ForEach(store.aboutYou.dontLearn) { d in
                    HStack {
                        Text(d.marker).font(Theme.rounded(12)).foregroundStyle(Theme.dim)
                        Spacer()
                        Button { store.aboutYou.removeDontLearn(d.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.dim)
                            .accessibilityLabel("Remove \(d.marker)")
                    }
                }
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
