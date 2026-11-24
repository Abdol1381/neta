import SwiftUI
import MessageUI

/// Sends from the iPhone's own Messages (iMessage, or SMS when the iPhone has a SIM) via the
/// system composer. iOS does not let apps read the Messages history, only send through this sheet.
struct MessageComposer: UIViewControllerRepresentable {
    var recipients: [String]
    var body: String
    var onFinish: (MessageComposeResult) -> Void

    static var available: Bool { MFMessageComposeViewController.canSendText() }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients.map(Phone.international)
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void
        init(onFinish: @escaping (MessageComposeResult) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            onFinish(result)
        }
    }
}

/// Where an outgoing message goes: a SIM on the Android phone, or the iPhone's iMessage.
enum SendRoute: Hashable {
    case sim(Int?)
    case iMessage
}
