import Foundation
import Contacts

/// The iPhone's own address book, indexed by phone number so caller / sender names resolve in O(1).
/// Loaded off the main thread and rebuilt automatically when the user edits contacts.
final class IPhoneContacts {
    private let store = CNContactStore()
    private(set) var byKey: [String: String] = [:]   // Phone.key(number) -> display name
    private(set) var list: [Contact] = []
    private var loading = false
    private var reloadAgain = false
    var onChange: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    var authorized: Bool {
        let s = status
        if s == .authorized { return true }
        if #available(iOS 18.0, *), s == .limited { return true }
        return false
    }

    func requestAccess(_ done: ((Bool) -> Void)? = nil) {
        store.requestAccess(for: .contacts) { [weak self] ok, _ in
            DispatchQueue.main.async {
                if ok { self?.reload() }
                done?(ok)
            }
        }
    }

    func reload() {
        guard authorized else { return }
        if loading { reloadAgain = true; return }
        loading = true
        let store = self.store
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var map: [String: String] = [:]
            var items: [Contact] = []
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .userDefault
            request.unifyResults = true
            var next: Int64 = 0
            do {
                try store.enumerateContacts(with: request) { c, _ in
                    let numbers = c.phoneNumbers.map { $0.value.stringValue }.filter { !Phone.key($0).isEmpty }
                    guard !numbers.isEmpty else { return }
                    var name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
                    if name.trimmingCharacters(in: .whitespaces).isEmpty { name = c.organizationName }
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    next += 1
                    items.append(Contact(id: -next, name: name, numbers: numbers))
                    for n in numbers {
                        let k = Phone.key(n)
                        if map[k] == nil { map[k] = name }
                    }
                }
            } catch {
                dlog("contacts fetch \(error)")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.byKey = map
                self.list = items
                self.loading = false
                dlog("iPhone contacts indexed: \(items.count)")
                self.onChange?()
                if self.reloadAgain { self.reloadAgain = false; self.reload() }
            }
        }
    }

    func name(for number: String) -> String? {
        let k = Phone.key(number)
        return k.isEmpty ? nil : byKey[k]
    }
}
