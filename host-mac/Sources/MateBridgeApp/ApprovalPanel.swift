import AppKit

/// Non-modal approval window. Unlike `NSAlert.runModal`, it can be closed or replaced at any time
/// from ordinary main-actor code, so a stale dialog can never swallow the click meant for a newer request.
@MainActor
final class ApprovalPanel: NSObject {
    let requestID: UInt64
    private let panel: NSPanel
    private var onAnswer: ((Bool) -> Void)?

    init(requestID: UInt64, deviceName: String, onAnswer: @escaping (Bool) -> Void) {
        self.requestID = requestID
        self.onAnswer = onAnswer
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "MateBridge"
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "\(deviceName) bağlanmak istiyor")
        title.font = .boldSystemFont(ofSize: 14)
        let body = NSTextField(wrappingLabelWithString:
            "İzin verirsen bu cihaz ekranını görebilir ve bu Mac'i kontrol edebilir.")
        let allow = NSButton(title: "İzin ver", target: self, action: #selector(allow))
        allow.keyEquivalent = "\r"
        let reject = NSButton(title: "Reddet", target: self, action: #selector(reject))
        let buttons = NSStackView(views: [reject, allow])
        buttons.spacing = 12
        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes without answering (request cancelled or replaced).
    func dismiss() {
        onAnswer = nil
        panel.orderOut(nil)
    }

    @objc private func allow() { answer(true) }
    @objc private func reject() { answer(false) }

    private func answer(_ approved: Bool) {
        let handler = onAnswer
        dismiss()
        handler?(approved)
    }
}
