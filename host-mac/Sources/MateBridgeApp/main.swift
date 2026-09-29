import AppKit
import MateBridgeCore
import MateBridgeHost

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var server: SessionServer?
    private var approvalRunning = false

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
        handlers.approvalCancelled = { [weak self] in
            Task { @MainActor in self?.dismissApproval() }
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

    private func askApproval(_ request: ApprovalRequest) {
        guard !approvalRunning else { return }
        approvalRunning = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(request.deviceName) bağlanmak istiyor"
        alert.informativeText = "İzin verirsen bu cihaz ekranını görebilir ve bu Mac'i kontrol edebilir."
        alert.addButton(withTitle: "İzin ver")
        alert.addButton(withTitle: "Reddet")
        let response = alert.runModal()
        approvalRunning = false
        switch response {
        case .alertFirstButtonReturn: server?.resolveApproval(approved: true)
        case .alertSecondButtonReturn: server?.resolveApproval(approved: false)
        default: break  // aborted: the connection went away, nothing to answer
        }
    }

    private func dismissApproval() {
        if approvalRunning { NSApp.abortModal() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
