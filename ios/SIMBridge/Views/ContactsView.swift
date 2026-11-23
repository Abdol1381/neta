import SwiftUI

struct ContactsView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var selected: Contact?
    @State private var composeTo: String?

    private var filtered: [Contact] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.contacts }
        return model.contacts.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.numbers.contains { $0.contains(q) } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.contacts.isEmpty {
                    EmptyState(
                        icon: "person.2",
                        title: model.conn.isReady ? "مخاطبی دریافت نشد" : "به گوشی اندروید وصل نیست",
                        subtitle: "مخاطبین گوشی اندروید (با دسترسی «مخاطبین») اینجا نمایش داده می‌شوند."
                    )
                } else {
                    List(filtered) { c in
                        Button { selected = c } label: {
                            HStack(spacing: 12) {
                                Avatar(name: c.name, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).foregroundStyle(.primary)
                                    if let n = c.numbers.first {
                                        Text(Phone.ltr(n)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("مخاطبین")
            .searchable(text: $search, prompt: "جستجوی نام یا شماره")
            .refreshable { model.loadContacts() }
            .confirmationDialog(selected?.name ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
                if let c = selected {
                    ForEach(c.numbers, id: \.self) { n in
                        Button("تماس با \(Phone.ltr(n))") { model.dial(n) }
                        Button("پیامک به \(Phone.ltr(n))") { composeTo = n }
                    }
                }
                Button("انصراف", role: .cancel) {}
            }
            .sheet(item: Binding(get: { composeTo.map { ComposeTarget(number: $0) } }, set: { composeTo = $0?.number })) { t in
                ComposeView(initialNumber: t.number).environmentObject(model)
            }
        }
    }
}

struct ComposeTarget: Identifiable {
    let number: String
    var id: String { number }
}
