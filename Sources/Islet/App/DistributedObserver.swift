import Foundation

/// Observes a distributed notification with `.deliverImmediately`. NSApplication suspends
/// distributed notifications while an app is inactive — which Islet, a background
/// accessory app, almost always is — and block-based observers can then miss them.
@MainActor
final class DistributedObserver: NSObject {
    private let handler: (Notification) -> Void

    init(_ name: String, handler: @escaping (Notification) -> Void) {
        self.handler = handler
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: .init(name),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func received(_ note: Notification) {
        handler(note)
    }

    func cancel() {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
