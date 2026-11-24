import SwiftUI

struct ThreadsView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var showCompose = false
    @State private var path: [SmsThread] = []

    private var filtered: [SmsThread] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.threads }
        return model.threads.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.address.contains(q) || $0.snippet.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.threads.isEmpty {
                    EmptyState(
                        icon: model.conn.isReady ? "message" : "wifi.slash",
                        title: model.conn.isReady ? (model.loadingThreads ? "Loading…" : "No Messages") : "Not Connected",
                        subtitle: model.conn.isReady ? "Text messages on the Android phone's SIM appear here." : "Messages appear here once the Android phone is connected."
                    )
                } else {
                    List(filtered) { t in
                        NavigationLink(value: t) { ThreadRow(thread: t) }
                            .listRowInsets(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 14))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
                    }
                    .listStyle(.plain)
                    .minimizingTabBar()
                }
            }
            .navigationTitle("Messages")
            .navigationDestination(for: SmsThread.self) { t in ConversationView(thread: t) }
            .searchable(text: $search, prompt: "Search")
            .refreshable { await withCheckedContinuation { c in model.loadThreads { c.resume() } } }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
                        .disabled(!model.conn.isReady)
                }
            }
            .sheet(isPresented: $showCompose) { ComposeView().environmentObject(model) }
            .onChange(of: model.threads.count) { _ in openFirstForTest() }
            .onAppear { openFirstForTest() }
        }
    }
}

private extension ThreadsView {
    func openFirstForTest() {
        if TestHooks.openFirstThread, path.isEmpty, let first = model.threads.first { path = [first] }
    }
}

extension SmsThread: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(threadId) }
}

struct ThreadRow: View {
    var thread: SmsThread

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(thread.unread > 0 ? IOSColor.iMessageBlue : Color.clear)
                .frame(width: 10, height: 10)
            Avatar(name: thread.name.isEmpty ? thread.address : thread.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.name.isEmpty ? thread.address : thread.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.short(thread.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(thread.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    var thread: SmsThread
    @State private var text = ""
    @State private var subId: Int?
    @State private var useIMessage = false
    @State private var composer: ComposerTarget?
    @State private var loading = true
    @FocusState private var focused: Bool

    private var list: [SmsMessage] { model.messages[thread.threadId] ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if loading && list.isEmpty { ProgressView().padding(.top, 40) }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                        let prev = i > 0 ? list[i - 1] : nil
                        let next = i + 1 < list.count ? list[i + 1] : nil
                        if prev == nil || m.date - prev!.date > 3_600_000 {
                            Text(Fmt.stamp(m.date))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                        }
                        let groupedWithNext = next != nil && next!.out == m.out && next!.date - m.date < 60_000 * 3
                        Bubble(message: m, tail: !groupedWithNext, isLastOut: m.out && m.id == list.last(where: { $0.out })?.id)
                            .padding(.bottom, groupedWithNext ? 2 : 8)
                            .id(m.id)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { inputBar }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: list.count) { _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: focused) { f in
                if f { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } }
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Avatar(name: thread.name.isEmpty ? thread.address : thread.name, size: 34)
                    Text(thread.name.isEmpty ? Phone.ltr(thread.address) : thread.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.dial(thread.address, subId: subId) } label: { Image(systemName: "phone") }
                    .disabled(!model.conn.isReady)
            }
        }
        .onAppear {
            model.markThreadOpened(thread.threadId)
            model.loadMessages(threadId: thread.threadId) { loading = false }
            if subId == nil { subId = list.last(where: { ($0.subId ?? -1) >= 0 })?.subId }
        }
        .onDisappear { if model.openThreadId == thread.threadId { model.markThreadOpened(nil) } }
        .sheet(item: $composer) { t in
            MessageComposer(recipients: t.recipients, body: t.body) { result in
                if result != .sent { text = t.body } // keep the draft if the user cancelled
            }
            .ignoresSafeArea()
        }
    }

    private var routeName: String {
        if useIMessage { return "iMessage" }
        let sim = model.sims.first { $0.subId == subId } ?? model.sims.first { $0.smsSim }
        if model.sims.count > 1, let sim { return "Text Message · SIM \(sim.slot + 1)" }
        return "Text Message · SMS"
    }

    private var sendColor: Color { useIMessage ? IOSColor.iMessageBlue : IOSColor.smsGreen }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if model.sims.count > 1 || MessageComposer.available {
                SimPicker(subId: $subId, iMessage: $useIMessage)
            }
            HStack(alignment: .bottom, spacing: 4) {
                TextField(routeName, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.leading, 14)
                    .padding(.vertical, 9)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, canSend ? sendColor : Color.gray.opacity(0.5))
                    }
                    .disabled(!canSend)
                    .padding(.trailing, 3)
                    .padding(.bottom, 3)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(minHeight: 38)
            .glass(in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: text.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func send() {
        let body = text
        text = ""
        if useIMessage {
            composer = ComposerTarget(recipients: [thread.address], body: body)
        } else {
            model.sendSms(to: thread.address, body: body, subId: subId, threadId: thread.threadId)
        }
    }

    private var canSend: Bool {
        (useIMessage || model.conn.isReady) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Message bubble in the style of iOS Messages: green for SMS sent from the SIM, gray for received.
struct Bubble: View {
    var message: SmsMessage
    var tail: Bool = true
    var isLastOut: Bool = false

    var body: some View {
        VStack(alignment: message.out ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 0) {
                if message.out { Spacer(minLength: 60) }
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(message.out ? Color.white : Color.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(message.out ? IOSColor.smsGreen : IOSColor.incoming,
                                in: BubbleShape(outgoing: message.out, tail: tail))
                    .contextMenu {
                        Button { UIPasteboard.general.string = message.body } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Text(Fmt.stamp(message.date))
                    }
                if !message.out { Spacer(minLength: 60) }
            }
            if message.out && (isLastOut || message.status == "failed" || message.status == "sending") {
                statusLine
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.out ? .trailing : .leading)
    }

    @ViewBuilder private var statusLine: some View {
        switch message.status {
        case "sending": Text("Sending…").foregroundStyle(.secondary)
        case "failed": Label("Not Delivered", systemImage: "exclamationmark.circle.fill").foregroundStyle(IOSColor.callRed)
        case "delivered": Text("Delivered").foregroundStyle(.secondary)
        default: Text("Sent").foregroundStyle(.secondary)
        }
    }
}

/// Rounded bubble with the small iOS tail on the bottom corner (outgoing right, incoming left).
struct BubbleShape: Shape {
    var outgoing: Bool
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 18
        var p = Path(roundedRect: rect, cornerRadius: r, style: .continuous)
        guard tail else { return p }
        let right = outgoing
        let x = right ? rect.maxX : rect.minX
        let dir: CGFloat = right ? 1 : -1
        var t = Path()
        t.move(to: CGPoint(x: x - dir * 10, y: rect.maxY - 12))
        t.addQuadCurve(to: CGPoint(x: x + dir * 5, y: rect.maxY), control: CGPoint(x: x - dir * 2, y: rect.maxY - 1))
        t.addQuadCurve(to: CGPoint(x: x - dir * 14, y: rect.maxY - 2), control: CGPoint(x: x - dir * 6, y: rect.maxY + 1))
        t.closeSubpath()
        p.addPath(t)
        return p
    }
}

struct SimPicker: View {
    @EnvironmentObject var model: AppModel
    @Binding var subId: Int?
    /// When given, the menu also offers sending through the iPhone's own iMessage.
    var iMessage: Binding<Bool>? = nil
    /// When given (and the internet line is connected), the menu also offers calling through it.
    var voip: Binding<Bool>? = nil

    private var usingIMessage: Bool { iMessage?.wrappedValue == true }
    private var usingVoip: Bool { voip?.wrappedValue == true }

    var body: some View {
        Menu {
            ForEach(model.sims) { s in
                Button {
                    subId = s.subId
                    iMessage?.wrappedValue = false
                    voip?.wrappedValue = false
                } label: {
                    Label("SIM \(s.slot + 1) — \(s.title)",
                          systemImage: !usingIMessage && !usingVoip && subId == s.subId ? "checkmark" : "simcard")
                }
            }
            if let voip, model.sipState == "ok" {
                Divider()
                Button {
                    voip.wrappedValue = true
                } label: {
                    Label("Internet Line (talk on iPhone)", systemImage: usingVoip ? "checkmark" : "phone.connection")
                }
            }
            if let iMessage, MessageComposer.available {
                Divider()
                Button {
                    iMessage.wrappedValue = true
                } label: {
                    Label("iMessage", systemImage: usingIMessage ? "checkmark" : "message.fill")
                }
            }
        } label: {
            Group {
                if usingVoip {
                    HStack(spacing: 4) {
                        Image(systemName: "phone.connection")
                        Text("VoIP").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Theme.good)
                } else if usingIMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "message.fill")
                        Text("iMessage").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Color.blue)
                } else {
                    let current = model.sims.first { $0.subId == subId } ?? model.sims.first { $0.smsSim } ?? model.sims.first
                    HStack(spacing: 3) {
                        Image(systemName: "simcard.fill")
                        Text(Fmt.persianDigits(String((current?.slot ?? 0) + 1))).font(.caption.weight(.bold))
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .glassCapsule(interactive: true)
        }
        .onAppear {
            if subId == nil { subId = (model.sims.first { $0.smsSim } ?? model.sims.first)?.subId }
        }
    }
}

/// Recipients + text handed to the system Messages composer.
struct ComposerTarget: Identifiable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var initialNumber: String = ""
    @State private var to = ""
    @State private var text = ""
    @State private var subId: Int?
    @State private var sending = false
    @State private var useIMessage = false
    @State private var composer: ComposerTarget?

    private struct Suggestion: Identifiable {
        let name: String
        let number: String
        var id: String { number }
    }

    private var suggestions: [Suggestion] {
        let q = to.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [Suggestion] = []
        for c in model.contacts where c.name.localizedCaseInsensitiveContains(q) || c.numbers.contains(where: { $0.contains(q) }) {
            for n in c.numbers where !out.contains(where: { $0.number == n }) { out.append(Suggestion(name: c.name, number: n)) }
            if out.count > 8 { break }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("To:", text: $to)
                        .keyboardType(.default)
                        .textContentType(.telephoneNumber)
                    if !suggestions.isEmpty && !to.allSatisfy({ $0.isNumber || $0 == "+" }) {
                        ForEach(suggestions) { s in
                            Button {
                                to = s.number
                            } label: {
                                HStack {
                                    Text(s.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text(Phone.ltr(s.number)).foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("Text Message", text: $text, axis: .vertical).lineLimit(4...10)
                    if MessageComposer.available {
                        Toggle("Send as iMessage", isOn: $useIMessage)
                    }
                    if model.sims.count > 1 && !useIMessage {
                        Picker("SIM", selection: Binding(get: { subId ?? defaultSub }, set: { subId = $0 })) {
                            ForEach(model.sims) { s in Text("SIM \(s.slot + 1) — \(s.title)").tag(Optional(s.subId)) }
                        }
                    }
                } footer: {
                    Text(useIMessage
                         ? "Sent from this iPhone's iMessage (your Apple ID). The recipient needs iMessage too."
                         : "Sent as SMS from the Android phone's SIM, charged at that SIM's rates.")
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else {
                        Button("Send") { send() }.disabled(!canSend)
                    }
                }
            }
            .onAppear { if to.isEmpty { to = initialNumber } }
            .sheet(item: $composer) { t in
                MessageComposer(recipients: t.recipients, body: t.body) { result in
                    if result == .sent { dismiss() }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var defaultSub: Int? { (model.sims.first { $0.smsSim } ?? model.sims.first)?.subId }

    private var canSend: Bool {
        (useIMessage || model.conn.isReady) && to.contains(where: { $0.isNumber }) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        if useIMessage {
            composer = ComposerTarget(recipients: [to], body: text)
            return
        }
        sending = true
        let tid = model.threads.first { Phone.same($0.address, to) }?.threadId
        model.sendSms(to: to, body: text, subId: subId ?? defaultSub, threadId: tid) { ok in
            sending = false
            if ok { dismiss() }
        }
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
