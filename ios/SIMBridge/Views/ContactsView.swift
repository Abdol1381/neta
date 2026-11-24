import SwiftUI

/// Contacts in the style of the iPhone's Contacts app: alphabetical sections, then a contact card.
struct ContactsView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""

    private var filtered: [Contact] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.contacts }
        return model.contacts.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.numbers.contains { $0.contains(q) } }
    }

    /// Sections by first letter (Persian and Latin), "#" for the rest.
    private var sections: [(String, [Contact])] {
        var groups: [String: [Contact]] = [:]
        for c in filtered {
            let first = c.name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
            let key = first.unicodeScalars.first.map { CharacterSet.letters.contains($0) } == true ? first : "#"
            groups[key, default: []].append(c)
        }
        return groups.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { ($0, groups[$0]!) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.contacts.isEmpty {
                    EmptyState(
                        icon: "person.2",
                        title: model.conn.isReady ? "No Contacts" : "Not Connected",
                        subtitle: "Contacts from this iPhone and the Android phone appear here."
                    )
                } else {
                    List {
                        ForEach(sections, id: \.0) { letter, items in
                            Section(letter) {
                                ForEach(items) { c in
                                    NavigationLink(value: c) {
                                        Text(c.name).font(.body)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .minimizingTabBar()
                }
            }
            .navigationTitle("Contacts")
            .navigationDestination(for: Contact.self) { ContactDetailView(contact: $0) }
            .searchable(text: $search, prompt: "Search")
            .refreshable { model.loadContacts() }
        }
    }
}

extension Contact: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Contact card like iOS: large monogram, name, glass action buttons, numbers.
struct ContactDetailView: View {
    @EnvironmentObject var model: AppModel
    var contact: Contact
    @State private var composeTo: String?

    private var primary: String? { contact.numbers.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Avatar(name: contact.name, size: 110)
                    .padding(.top, 12)
                Text(contact.name)
                    .font(.system(size: 28, weight: .semibold))
                    .multilineTextAlignment(.center)

                GlassGroup {
                    HStack(spacing: 10) {
                        action("message", "message.fill") { composeTo = primary }
                        action("call", "phone.fill") { if let n = primary { model.dial(n) } }
                        if model.sipState == "ok" {
                            action("internet", "phone.connection.fill") { if let n = primary { model.dialVoip(n) } }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .disabled(primary == nil)

                VStack(spacing: 0) {
                    ForEach(Array(contact.numbers.enumerated()), id: \.offset) { i, n in
                        if i > 0 { Divider().padding(.leading, 16) }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("mobile").font(.subheadline).foregroundStyle(.secondary)
                                Text(n).font(.body).foregroundStyle(IOSColor.iMessageBlue)
                            }
                            Spacer()
                            Button { composeTo = n } label: { Image(systemName: "message").font(.title3) }
                                .buttonStyle(.borderless)
                            Button { model.dial(n) } label: { Image(systemName: "phone").font(.title3) }
                                .buttonStyle(.borderless)
                                .padding(.leading, 14)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 30)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { composeTo.map { ComposeTarget(number: $0) } }, set: { composeTo = $0?.number })) { t in
            ComposeView(initialNumber: t.number).environmentObject(model)
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(IOSColor.iMessageBlue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

struct ComposeTarget: Identifiable {
    let number: String
    var id: String { number }
}
