import AppKit
import MateBridgeCore
import MateBridgeHost
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var server: SessionServer?
    private var approvalPanel: ApprovalPanel?
    private let logger = Logger(subsystem: "dev.matebridge.host", category: "session")

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

    /// The dialog always shows the latest request: a new one replaces the visible panel immediately.
    private func askApproval(_ request: ApprovalRequest) {
        approvalPanel?.dismiss()
        let panel = ApprovalPanel(requestID: request.id, deviceName: request.deviceName) { [weak self] approved in
            self?.approvalPanel = nil
            // Bound to this request's id; the server ignores the answer if it is no longer pending.
            self?.server?.resolveApproval(id: request.id, approved: approved)
        }
        approvalPanel = panel
        panel.show()
        log("approval_shown", "conn=\(request.id)")
    }

    private func cancelApproval(_ id: UInt64) {
        guard let panel = approvalPanel, panel.requestID == id else { return }
        panel.dismiss()
        approvalPanel = nil
        log("approval_dismissed", "conn=\(id)")
    }

    private func log(_ event: String, _ fields: String) {
        let line = LogFormat.line(monoMs: DispatchTime.now().uptimeNanoseconds / 1_000_000, level: .info,
                                  component: "session", sessionID: 0, generation: 0, event: event, fields: fields)
        logger.info("\(line, privacy: .public)")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
