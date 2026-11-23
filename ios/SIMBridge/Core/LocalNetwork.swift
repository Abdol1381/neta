import Foundation
import Network

/// Browsing Bonjour once makes iOS show the "Local Network" permission prompt early (on the
/// welcome screen) instead of in the middle of pairing.
enum LocalNetwork {
    private static var browser: NWBrowser?

    static func requestPermission() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_simbridge._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { _, _ in }
        b.start(queue: .main)
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            browser?.cancel()
            browser = nil
        }
    }
}
