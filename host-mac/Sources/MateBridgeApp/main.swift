import AppKit
import MateBridgeCore
import MateBridgeHost
import os

DumpVideoCommand.runIfRequested()  // T-011: `--dump-video` CLI mode, exits before the menu bar app starts
InjectTestCommand.runIfRequested()  // T-023: `--inject-test` CLI mode (posts real input events), same

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var server: SessionServer?
    private let coordinator = StreamCoordinator()
    private let input = InputController()
    private let videoLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityLine = NSMenuItem(title: "Erişilebilirlik izni gerekli", action: nil, keyEquivalent: "")
    private let accessibilitySettingsItem = NSMenuItem(title: "Sistem Ayarları'nı aç…",
                                                       action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let loginItem = LoginItem()
    private let loginItemEntry = NSMenuItem(title: "Oturum açılışında başlat", action: #selector(toggleLoginItem),
                                            keyEquivalent: "")
    private let loginProblemLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let usbModeEntry = NSMenuItem(title: "USB modu", action: #selector(toggleUsbMode), keyEquivalent: "")
    private let usbLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let usbWatcher = UsbTunnelWatcher()
    private static let usbModeKey = "usbModeEnabled"
    private var signalSources: [DispatchSourceSignal] = []
    private var approvalPanel: ApprovalPanel?
    private let logger = Logger(subsystem: "dev.matebridge.host", category: "session")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "MateBridge"
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "MateBridge", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        statusLine.isEnabled = false
        statusLine.title = "Başlatılıyor…"
        menu.addItem(statusLine)
        videoLine.isEnabled = false
        videoLine.isHidden = true
        menu.addItem(videoLine)
        // Input needs the Accessibility permission: shown (with a way to grant it) until it is granted.
        accessibilityLine.isEnabled = false
        accessibilityLine.isHidden = true
        menu.addItem(accessibilityLine)
        accessibilitySettingsItem.target = self
        accessibilitySettingsItem.isHidden = true
        menu.addItem(accessibilitySettingsItem)
        menu.addItem(.separator())
        for entry in [loginItemEntry, usbModeEntry] {
            entry.target = self
            menu.addItem(entry)
        }
        loginProblemLine.isEnabled = false
        loginProblemLine.isHidden = true
        menu.addItem(loginProblemLine)
        usbLine.isEnabled = false
        usbLine.isHidden = true
        menu.addItem(usbLine)
        let logsEntry = NSMenuItem(title: "Logları aç", action: #selector(openLogs), keyEquivalent: "")
        logsEntry.target = self
        menu.addItem(logsEntry)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Onaylı cihazları unut", action: #selector(forgetDevices), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for entry in menu.items where entry.action == #selector(forgetDevices) { entry.target = self }
        item.menu = menu
        statusItem = item

        // A kill or Ctrl-C is an app shutdown too: go through terminate so applicationWillTerminate releases input.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }

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
        // Video: session events drive the display/encoder/sender (T-014). Input (T-023): the same events drive the
        // injector, every input message goes to it, and every release-all trigger reaches `releaseInput`.
        let coordinator = self.coordinator
        let input = self.input
        handlers.sessionStarted = { sid, cid, hello in
            coordinator.sessionStarted(sessionID: sid, configID: cid, hello: hello)
            input.sessionStarted(sessionID: sid, configID: cid)
        }
        handlers.sessionEnded = {
            coordinator.sessionEnded()
            input.sessionEnded()
        }
        handlers.videoAttached = { coordinator.videoAttached($0) }
        handlers.deliver = { message in
            coordinator.deliver(message)
            input.deliver(message)
        }
        handlers.releaseInput = { input.releaseInput($0) }
        coordinator.onSummary = { [weak self] text in
            Task { @MainActor in self?.showVideo(text) }
        }
        coordinator.start()
        input.start { [weak self] status in
            Task { @MainActor in self?.showInput(status) }
        }
        // Ask for the permission under MateBridge's own identity, once per launch (a no-op when already granted).
        if !SystemAccessibility().isTrusted() { SystemAccessibility.requestPrompt() }
        let server = SessionServer(handlers: handlers, makeStreamConfig: { coordinator.streamConfig(for: $0) })
        self.server = server
        coordinator.onOverflow = { [server] in server.endSessions() }
        server.start()

        loginItem.registerOnFirstRun()
        // USB mode defaults to on and the choice persists. The guard keeps the `adb reverse` tunnels alive (T-039).
        usbWatcher.onStateChange = { [weak self] state in
            Task { @MainActor in self?.showUsb(state) }
        }
        usbWatcher.setEnabled(usbModeEnabled)
    }

    private var usbModeEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.usbModeKey) as? Bool ?? true
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()  // release input (releaseInput), BYE(SHUTTING_DOWN) to peers
        input.shutdown()  // backstop: releases whatever is still held, even if no session was reported
        coordinator.shutdown()  // stop capture/encoder and remove the virtual display
    }

    func menuWillOpen(_ menu: NSMenu) {
        input.refreshStatus()  // permission may have changed in System Settings
        loginItem.refresh()  // read live: the user may have changed it in System Settings
        loginItemEntry.state = loginItem.status.isRequested ? .on : .off
        loginItemEntry.title = loginItem.status.menuTitle
        usbModeEntry.state = usbModeEnabled ? .on : .off
        showLoginProblem()
    }

    @objc private func toggleLoginItem() {
        loginItem.toggle()
        showLoginProblem()
    }

    private func showLoginProblem() {
        loginProblemLine.title = loginItem.problem ?? ""
        loginProblemLine.isHidden = loginItem.problem == nil
    }

    @objc private func toggleUsbMode() {
        let on = !usbModeEnabled
        UserDefaults.standard.set(on, forKey: Self.usbModeKey)
        usbModeEntry.state = on ? .on : .off
        usbWatcher.setEnabled(on)
    }

    @objc private func openLogs() {
        let dir = RotatingLogFile.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func showUsb(_ state: UsbTunnelState?) {
        guard let state else {
            usbLine.isHidden = true
            return
        }
        switch state {
        case .up: usbLine.title = "USB: tüneller hazır"
        case .down: usbLine.title = "USB: tüneller kuruluyor…"
        case .noDevice: usbLine.title = "USB: tablet bağlı değil"
        case .noAdb: usbLine.title = "USB: adb bulunamadı"
        }
        usbLine.isHidden = false
    }

    @objc private func forgetDevices() {
        server?.forgetApprovedDevices()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showInput(_ status: InputController.Status) {
        accessibilityLine.isHidden = status.accessibilityTrusted
        accessibilitySettingsItem.isHidden = status.accessibilityTrusted
    }

    private func showVideo(_ text: String) {
        videoLine.title = text
        videoLine.isHidden = text.isEmpty
    }

    private func show(_ state: SessionServerState) {
        switch state {
        case .stopped: statusLine.title = "Durduruldu"
        case .starting: statusLine.title = "Başlatılıyor…"
        case .listening: statusLine.title = "Bekleniyor"
        case .awaitingApproval: statusLine.title = "Onay bekleniyor"
        case .connected(let name, let transport):
            statusLine.title = "Bağlı: \(name) (\(transport == .usb ? "USB" : "Ağ"))"
        case .failed(let what): statusLine.title = "Hata: \(what)"
        }
    }

    /// The dialog always shows the latest request: a new one replaces the visible panel immediately.
    private func askApproval(_ request: ApprovalRequest) {
        approvalPanel?.dismiss()
        let panel = ApprovalPanel(requestID: request.id, deviceName: request.deviceName, code: request.code) { [weak self] approved in
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
