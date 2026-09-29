import AppKit
import MateBridgeCore
import MateBridgeHost

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var server: SessionServer?
    /// Approval flow state. Everything runs on the main actor, so these are serialized.
    private var approvalRunning = false
    private var shownApprovalID: UInt64?
    private var latestRequest: ApprovalRequest?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "MateBridge"
        let menu = NSMenu()
        let title = NSMenuItem(title: "MateBridge", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        statusLine.isEnabled = false
        statusLine.title = "Başlatılıyor…"
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Onaylı cihazları unut", action: #selector(forgetDevices), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for entry in menu.items where entry.action == #selector(forgetDevices) { entry.target = self }
        item.menu = menu
        statusItem = item

        var handlers = SessionServer.Handlers()
        handlers.stateChanged = { [weak self] state in
            Task { @MainActor in self?.show(state) }
        }
        handlers.approvalRequested = { [weak self] request in
            Task { @MainActor in self?.askApproval(request) }
        }
        handlers.approvalCancelled = { [weak self] id in
            Task { @MainActor in self?.cancelApproval(id) }
        }
        // Input injection, video and the log file arrive with later tasks; releaseInput is a no-op until then.
        let server = SessionServer(handlers: handlers)
        self.server = server
        server.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()  // release input, BYE(SHUTTING_DOWN) to peers
    }

    @objc private func forgetDevices() {
        server?.forgetApprovedDevices()
    }

    private func show(_ state: SessionServerState) {
        switch state {
        case .stopped: statusLine.title = "Durduruldu"
        case .starting: statusLine.title = "Başlatılıyor…"
        case .listening: statusLine.title = "Dinliyor"
        case .awaitingApproval: statusLine.title = "Onay bekleniyor"
        case .connected(let name): statusLine.title = "Bağlı: \(name)"
        case .failed(let what): statusLine.title = "Hata: \(what)"
        }
    }

    /// A new request replaces any queued one and aborts the dialog still showing an older request.
    /// The next alert is only shown after `runModal` has returned, so a takeover never loses its dialog.
    private func askApproval(_ request: ApprovalRequest) {
        latestRequest = request
        if approvalRunning {
            NSApp.abortModal()
        } else {
            Task { @MainActor in self.pumpApprovals() }
        }
    }

    private func cancelApproval(_ id: UInt64) {
        if latestRequest?.id == id { latestRequest = nil }
        if approvalRunning, shownApprovalID == id { NSApp.abortModal() }
    }

    private func pumpApprovals() {
        guard !approvalRunning else { return }
        while let request = latestRequest {
            latestRequest = nil
            approvalRunning = true
            shownApprovalID = request.id
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "\(request.deviceName) bağlanmak istiyor"
            alert.informativeText = "İzin verirsen bu cihaz ekranını görebilir ve bu Mac'i kontrol edebilir."
            alert.addButton(withTitle: "İzin ver")
            alert.addButton(withTitle: "Reddet")
            let response = alert.runModal()
            approvalRunning = false
            shownApprovalID = nil
            // The answer is bound to this request's id; the server ignores it if that request is no longer pending.
            switch response {
            case .alertFirstButtonReturn: server?.resolveApproval(id: request.id, approved: true)
            case .alertSecondButtonReturn: server?.resolveApproval(id: request.id, approved: false)
            default: break  // aborted: cancelled or replaced by a newer request
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
