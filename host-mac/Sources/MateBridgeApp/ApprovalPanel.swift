import AppKit
import MateBridgeCore

/// Non-modal approval window. Unlike `NSAlert.runModal`, it can be closed or replaced at any time
/// from ordinary main-actor code, so a stale dialog can never swallow the click meant for a newer request.
@MainActor
final class ApprovalPanel: NSObject {
    let requestID: UInt64
    private let panel: NSPanel
    private var onAnswer: ((Bool) -> Void)?
    private let notice = NSTextField(wrappingLabelWithString: "")

    /// `replaced` and `fingerprint` (T-155): a request that replaced an open window says so, so a returning user does
    /// not click "İzin ver" out of habit for a different device.
    init(requestID: UInt64, deviceName: String, code: String, replaced: ApprovalReplacement, fingerprint: String,
         onAnswer: @escaping (Bool) -> Void) {
        self.requestID = requestID
        self.onAnswer = onAnswer
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "MateBridge"
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "\(deviceName) bağlanmak istiyor")
        title.font = .boldSystemFont(ofSize: 14)
        // The pairing code is shown here and on the tablet; the user compares them (PROTOCOL.md 9).
        let codeLabel = NSTextField(labelWithString: code)
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .bold)
        let compare = NSTextField(wrappingLabelWithString: "Tabletteki kodla aynı mı?")
        compare.font = .systemFont(ofSize: 13, weight: .medium)
        let body = NSTextField(wrappingLabelWithString:
            "Kodlar aynıysa izin ver: bu cihaz ekranını görebilir ve bu Mac'i kontrol edebilir. Farklıysa reddet.")
        let allow = NSButton(title: "İzin ver", target: self, action: #selector(allow))
        allow.keyEquivalent = "\r"
        let reject = NSButton(title: "Reddet", target: self, action: #selector(reject))
        notice.font = .systemFont(ofSize: 13, weight: .semibold)
        notice.textColor = .systemOrange
        notice.isHidden = true
        let buttons = NSStackView(views: [reject, allow])
        buttons.spacing = 12
        // Separate from `notice`, so a later "tablet left" / Keychain notice never hides the replacement warning.
        var views: [NSView] = [title, codeLabel, compare]
        switch replaced {
        case .none:
            break
        case .otherDevice:
            let warning = NSTextField(wrappingLabelWithString:
                "Bu, önceki istekten FARKLI bir cihaz.\nCihaz parmak izi: \(fingerprint)")
            warning.font = .systemFont(ofSize: 13, weight: .bold)
            warning.textColor = .systemRed
            views.append(warning)
        case .sameDevice:
            let info = NSTextField(wrappingLabelWithString: "Kod değişti — tabletteki kodla yeniden karşılaştır.")
            info.font = .systemFont(ofSize: 13)
            info.textColor = .secondaryLabelColor
            views.append(info)
        }
        views += [notice, body, buttons]
        let stack = NSStackView(views: views)
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

    /// The tablet left while this request was open (e.g. the user switched to another app). The window stays; "İzin ver"
    /// now lets the tablet pair the next time it connects.
    func markDisconnected() {
        setNotice("Tablet ayrıldı. İzin verirsen tablet yeniden bağlandığında eşleşir.")
    }

    func setNotice(_ text: String) {
        notice.stringValue = text
        notice.isHidden = false
        if let stack = panel.contentView as? NSStackView { panel.setContentSize(stack.fittingSize) }
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
