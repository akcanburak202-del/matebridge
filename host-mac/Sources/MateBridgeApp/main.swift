import AppKit
import MateBridgeCore
import MateBridgeHost

DumpVideoCommand.runIfRequested()  // T-011: `--dump-video` CLI mode, exits before the menu bar app starts
EncodeBenchCommand.runIfRequested()  // T-047: `--encode-bench` (synthetic frames, no display/input/network)
SharpnessBench.runIfRequested()  // T-086: `--sharpness-bench` (synthetic text through the real encoder + decoder)
InjectTestCommand.runIfRequested()  // T-023: `--inject-test` CLI mode (posts real input events), same
FilesNetSelfTest.runIfRequested()  // T-268: `--files-net-selftest` (Wi-Fi file path on loopback, no GUI, no mount)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var server: SessionServer?
    private let coordinator = StreamCoordinator()
    private let input = InputController()
    /// System audio to the tablet (T-094): the Core Audio tap and the streamer that drives it.
    private let audioTap = SystemAudioTap()
    private lazy var audio = HostAudio.makeStreamer(tap: audioTap)
    private let videoLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Decision 0013 (T-106): sends `SETTINGS_OPEN`; shown only while the connected tablet supports the panel.
    private let tabletSettingsEntry = NSMenuItem(title: "Tablette ayarları aç", action: #selector(openTabletSettings),
                                                 keyEquivalent: "")
    /// Decision 0015 (T-136): mounts the tablet's WebDAV volume and opens it in Finder (USB sessions only).
    private let tabletFilesEntry = NSMenuItem(title: "Tablet dosyalarını aç", action: #selector(openTabletFiles),
                                              keyEquivalent: "")
    private let tabletFiles = TabletFilesBridge()
    private var tabletFilesEnabled = false
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
    /// Decision 0027 (T-189): "Yalnız USB" closes the LAN surface (loopback-only listeners, no Bonjour). Default off.
    private let usbOnlyEntry = NSMenuItem(title: "Yalnız USB (Wi-Fi kapalı)", action: #selector(toggleUsbOnly),
                                          keyEquivalent: "")
    /// Shown while "Yalnız USB" is in force or a switch waits for the live session to end.
    private let networkProfileLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// The profile the server's listeners run under (`networkProfileChanged`); differs from the stored choice while a
    /// switch waits for the live session. The `adb reverse` watcher follows both (`syncUsbMode`).
    private var appliedProfile: NetworkProfile = .all
    private let clipboardEntry = NSMenuItem(title: "Pano paylaşımı", action: #selector(toggleClipboard), keyEquivalent: "")
    private lazy var clipboard = ClipboardBridge(enabled: clipboardEnabled)
    private var signalSources: [DispatchSourceSignal] = []
    private var approvalPanel: ApprovalPanel?

    /// Pid of an older live copy with our bundle identifier once `SingleInstancePolicy` gave up waiting for it, else
    /// nil. Sleeps (main thread, before any UI) while an older copy is still quitting. A `swift run` binary has no
    /// bundle identifier and skips the check.
    private static func olderRunningCopyPID() -> Int32? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let own = NSRunningApplication.current
        var waitedMs = 0
        while true {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map {
                SingleInstancePolicy.Instance(pid: $0.processIdentifier, launchDate: $0.launchDate,
                                              isTerminated: $0.isTerminated)
            }
            switch SingleInstancePolicy.decide(ownPID: own.processIdentifier, ownLaunchDate: own.launchDate,
                                               others: others, waitedMs: waitedMs) {
            case .proceed: return nil
            case .exit(let pid): return pid
            case .wait(let ms):
                Thread.sleep(forTimeInterval: Double(ms) / 1000)
                waitedMs += ms
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // T-145: the first host.log line of every launch names the exact build (before `listening`).
        let build = BuildInfo(infoDictionary: Bundle.main.infoDictionary)
        HostLog.log(.info, component: "session", event: "app_start",
                    fields: build.logFields(os: ProcessInfo.processInfo.operatingSystemVersionString))
        // T-224: a second copy exits before it opens a listener, a menu bar item or a display.
        if let existing = Self.olderRunningCopyPID() {
            HostLog.log(.warning, component: "session", event: "second_instance",
                        fields: "action=exit existing_pid=\(existing)")
            exit(0)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarGlyph()
        item.button?.imagePosition = .imageOnly
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
        networkProfileLine.isEnabled = false
        networkProfileLine.isHidden = true
        menu.addItem(networkProfileLine)
        tabletSettingsEntry.target = self
        tabletSettingsEntry.isHidden = true
        menu.addItem(tabletSettingsEntry)
        tabletFilesEntry.target = self
        tabletFilesEntry.isHidden = true
        menu.addItem(tabletFilesEntry)
        // Input needs the Accessibility permission: shown (with a way to grant it) until it is granted.
        accessibilityLine.isEnabled = false
        accessibilityLine.isHidden = true
        menu.addItem(accessibilityLine)
        accessibilitySettingsItem.target = self
        accessibilitySettingsItem.isHidden = true
        menu.addItem(accessibilitySettingsItem)
        menu.addItem(.separator())
        for entry in [loginItemEntry, usbModeEntry, usbOnlyEntry, clipboardEntry] {
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
        let versionLine = NSMenuItem(title: build.menuTitle, action: nil, keyEquivalent: "")
        versionLine.isEnabled = false
        menu.addItem(versionLine)
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
        handlers.approvalKeychainBusy = { [weak self] request in
            Task { @MainActor in
                self?.askApproval(request)
                self?.approvalPanel?.setNotice("Anahtar Zinciri meşgul, tekrar dene.")
            }
        }
        handlers.approvalOrphaned = { [weak self] id in
            Task { @MainActor in self?.markApprovalDisconnected(id) }
        }
        // Video: session events drive the display/encoder/sender (T-014). Input (T-023): the same events drive the
        // injector, every input message goes to it, and every release-all trigger reaches `releaseInput`.
        let coordinator = self.coordinator
        let input = self.input
        let clipboard = self.clipboard
        let audio = self.audio
        let tabletFiles = self.tabletFiles
        tabletFiles.onMenuChange = { [weak self] state in
            // FIFO onto the main queue, like the settings item: states never land out of order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.showTabletFiles(state) } }
        }
        handlers.sessionStarted = { sid, cid, hello, transport in
            coordinator.sessionStarted(sessionID: sid, configID: cid, hello: hello, transport: transport)
            input.sessionStarted(sessionID: sid, configID: cid)
            clipboard.sessionStarted(sessionID: sid)
            audio.sessionStarted(sessionID: sid, clientSupportsAudio: hello.capabilities.contains(.audioPCM))
            tabletFiles.sessionStarted(sessionID: sid, transport: transport, capabilities: hello.capabilities)
        }
        handlers.sessionEnded = {
            audio.sessionEnded()  // first: the Mac's own sound comes back at once (no video grace period)
            coordinator.sessionEnded()
            input.sessionEnded()
            clipboard.sessionEnded()
            tabletFiles.sessionEnded()  // unmount the tablet volume, remove the forward
        }
        handlers.streamBitrate = { kbps in tabletFiles.streamBitrateChanged(kbps: kbps) }  // Wi-Fi file budget (T-268)
        handlers.audioPrefs = { sid, prefs in audio.prefs(sessionID: sid, enabled: prefs.enabled) }
        handlers.networkProfileChanged = { [weak self] applied, pending in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.showNetworkProfile(applied, pending) } }
        }
        handlers.settingsPanelAvailable = { [weak self] available in
            // FIFO onto the main queue: a quick true/false/true never lands out of order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.tabletSettingsEntry.isHidden = !available } }
        }
        handlers.videoAttached = { coordinator.videoAttached($0) }
        handlers.deliver = { message in
            coordinator.deliver(message)
            input.deliver(message)
            clipboard.deliver(message)
            tabletFiles.deliver(message)
        }
        handlers.releaseInput = { input.releaseInput($0) }
        // T-163: every record of the active session's control connection; pauses key repeat during a stall.
        handlers.controlActivity = { input.noteControlActivity(at: $0) }
        coordinator.onSummary = { [weak self] text in
            Task { @MainActor in self?.showVideo(text) }
        }
        coordinator.start()
        input.start { [weak self] status in
            Task { @MainActor in self?.showInput(status) }
        }
        // Ask for the permission under MateBridge's own identity, once per launch (a no-op when already granted).
        if !SystemAccessibility().isTrusted() { SystemAccessibility.requestPrompt() }
        appliedProfile = networkProfile
        let server = SessionServer(handlers: handlers, networkProfile: networkProfile,
                                   makeStreamConfig: { coordinator.streamConfig(for: $0) })
        self.server = server
        tabletFiles.attach(link: server)  // Wi-Fi files (T-268): peer address, file keys, FILES_NET
        coordinator.onOverflow = { [server] in server.endSessions() }
        // T-325: a stalled coordinator refuses new sessions; the last resort releases input first, then restarts.
        coordinator.onRefuseSessions = { [server] in server.setRefusingSessions($0) }
        coordinator.onStallRestart = { [input] in
            StallRestart.run(.init(
                releaseInput: { input.shutdown() },  // release-all + bounded drain of owed releases, idempotent
                scheduleRelaunch: {
                    // Starts the helper before the terminate; it opens a new instance only after this pid is gone.
                    let path = Bundle.main.bundlePath
                    guard path.hasSuffix(".app") else { return }
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/sh")
                    p.arguments = StallRestart.relaunchArguments(pid: getpid(), bundlePath: path)
                    p.standardInput = nil
                    p.standardOutput = nil
                    p.standardError = nil
                    try? p.run()
                },
                requestTerminate: {  // applicationWillTerminate runs the full orderly shutdown
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                },
                forceExit: { exit(75) },
                log: { HostLog.log(.error, component: "net", event: "stall_restart", fields: $0) }))
        }
        coordinator.onReconfigure = { [server] sid, config in server.reconfigureStream(sessionID: sid, config: config) }
        clipboard.send = { [server] sid, message in server.sendToSession(sessionID: sid, message) }
        audio.attach(sink: server)
        server.start()

        loginItem.registerOnFirstRun()
        // USB mode defaults to on and the choice persists. The guard keeps the `adb reverse` tunnels alive (T-039).
        usbWatcher.onStateChange = { [weak self, tabletFiles] state in
            tabletFiles.usbStateChanged(state)
            Task { @MainActor in self?.showUsb(state) }
        }
        syncUsbMode()
    }

    /// The `adb reverse` watcher and the "USB modu" item follow the stored choice, the applied and the requested
    /// profile together: tunnels are never removed under a session a deferred switch preserves (T-189).
    private func syncUsbMode() {
        let on = NetworkProfile.usbWatcherEnabled(stored: usbModeEnabled, applied: appliedProfile,
                                                  requested: networkProfile)
        usbModeEntry.state = on ? .on : .off
        usbWatcher.setEnabled(on)
    }

    private var usbModeToggleAllowed: Bool {
        NetworkProfile.usbModeToggleAllowed(applied: appliedProfile, requested: networkProfile)
    }

    /// The stored "USB modu" choice. "Yalnız USB" forces the watcher on without changing it (T-189).
    private var usbModeEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.usbModeKey) as? Bool ?? true
    }

    /// The stored "Yalnız USB" preference (missing or unknown: "USB + Wi-Fi").
    private var networkProfile: NetworkProfile {
        NetworkProfile(storedValue: UserDefaults.standard.object(forKey: NetworkProfile.defaultsKey))
    }

    private var clipboardEnabled: Bool {
        UserDefaults.standard.object(forKey: ClipboardBridge.defaultsKey) as? Bool ?? true
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()  // release input (releaseInput), BYE(SHUTTING_DOWN) to peers
        tabletFiles.shutdown()  // unmount the tablet volume and remove the forward (bounded wait)
        audio.shutdown()  // stop streaming; the tap teardown below gives the Mac its sound back
        audioTap.shutdown()
        input.shutdown()  // backstop: releases whatever is still held, even if no session was reported
        coordinator.shutdown()  // stop capture/encoder and remove the virtual display
    }

    func menuWillOpen(_ menu: NSMenu) {
        input.refreshStatus()  // permission may have changed in System Settings
        tabletFiles.menuWillOpen()  // retries a failed forward
        loginItem.refresh()  // read live: the user may have changed it in System Settings
        loginItemEntry.state = loginItem.status.isRequested ? .on : .off
        loginItemEntry.title = loginItem.status.menuTitle
        usbModeEntry.state = NetworkProfile.usbWatcherEnabled(stored: usbModeEnabled, applied: appliedProfile,
                                                              requested: networkProfile) ? .on : .off
        usbOnlyEntry.state = networkProfile == .usbOnly ? .on : .off
        clipboardEntry.state = clipboardEnabled ? .on : .off
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
        guard usbModeToggleAllowed else { return }  // locked on in "Yalnız USB"
        UserDefaults.standard.set(!usbModeEnabled, forKey: Self.usbModeKey)
        syncUsbMode()
    }

    /// "Yalnız USB" on/off: persisted, the `adb reverse` watcher follows at once (forced on in the mode), and the server
    /// switches its listeners now or after the live session (`networkProfileChanged` updates the menu line).
    @objc private func toggleUsbOnly() {
        let profile: NetworkProfile = networkProfile == .usbOnly ? .all : .usbOnly
        UserDefaults.standard.set(profile.storedValue, forKey: NetworkProfile.defaultsKey)
        usbOnlyEntry.state = profile == .usbOnly ? .on : .off
        syncUsbMode()  // on at once when entering; kept until the switch takes effect when leaving
        server?.setNetworkProfile(profile)
    }

    private func showNetworkProfile(_ applied: NetworkProfile, _ pending: NetworkProfile?) {
        appliedProfile = applied
        syncUsbMode()  // a deferred switch away from "Yalnız USB" releases the forced tunnels only now
        switch (applied, pending) {
        case (_, .usbOnly?): networkProfileLine.title = "Yalnız USB: oturum bitince uygulanacak"
        case (_, .all?): networkProfileLine.title = "USB + Wi-Fi: oturum bitince uygulanacak"
        case (.usbOnly, nil): networkProfileLine.title = "Ağ: yalnız USB (Wi-Fi ve Bonjour kapalı)"
        case (.all, nil): networkProfileLine.title = ""
        }
        networkProfileLine.isHidden = networkProfileLine.title.isEmpty
    }

    @objc private func toggleClipboard() {
        let on = !clipboardEnabled
        UserDefaults.standard.set(on, forKey: ClipboardBridge.defaultsKey)
        clipboardEntry.state = on ? .on : .off
        clipboard.setEnabled(on)
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

    /// The server re-checks the session and its capability before sending (the item may be stale by a moment).
    @objc private func openTabletSettings() {
        server?.openSettingsPanel()
    }

    /// The bridge re-checks its state (the item may be stale by a moment); already mounted only opens Finder.
    @objc private func openTabletFiles() {
        tabletFiles.open()
    }

    /// The menu auto-enables items that have an action, so the enabled state goes through `validateMenuItem`.
    private func showTabletFiles(_ state: TabletFilesMenu) {
        tabletFilesEntry.isHidden = state == .hidden
        tabletFilesEnabled = false
        switch state {
        case .hidden: break
        case .enableOnTablet: tabletFilesEntry.title = "Tablet dosyaları: tablette açın (Ayarlar → Tablet dosyaları)"
        case .usbOnly: tabletFilesEntry.title = "Tablet dosyalarını aç (yalnızca USB ile)"
        case .preparing: tabletFilesEntry.title = "Tablet dosyalarını aç (hazırlanıyor…)"
        case .mounting: tabletFilesEntry.title = "Tablet dosyaları bağlanıyor…"
        case .ready(let lastMountFailed):
            tabletFilesEntry.title = lastMountFailed ? "Tablet dosyalarını aç (bağlanamadı, tekrar dene)"
                                                     : "Tablet dosyalarını aç"
            tabletFilesEnabled = true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === tabletFilesEntry { return tabletFilesEnabled }
        if menuItem === usbModeEntry { return usbModeToggleAllowed }  // locked on in "Yalnız USB"
        return true
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
        let panel = ApprovalPanel(requestID: request.id, deviceName: request.deviceName, code: request.code,
                                  replaced: request.replaced,
                                  fingerprint: request.deviceFingerprint) { [weak self] approved in
            self?.approvalPanel = nil
            // Bound to this request's id; the server ignores the answer if it is no longer pending.
            self?.server?.resolveApproval(id: request.id, approved: approved)
        }
        approvalPanel = panel
        panel.show()
        log("approval_shown", "conn=\(request.id)")
    }

    private func markApprovalDisconnected(_ id: UInt64) {
        guard let panel = approvalPanel, panel.requestID == id else { return }
        panel.markDisconnected()
        log("approval_disconnected", "conn=\(id)")
    }

    private func cancelApproval(_ id: UInt64) {
        guard let panel = approvalPanel, panel.requestID == id else { return }
        panel.dismiss()
        approvalPanel = nil
        log("approval_dismissed", "conn=\(id)")
    }

    private func log(_ event: String, _ fields: String) {
        HostLog.log(.info, component: "session", event: event, fields: fields)
    }
}

/// Menu bar template glyph (T-130, concept C "M line"). Geometry from docs/design/icon-master.svg:
/// the same path in the full 100x100 box, stroke 10, end dot r 7.5, drawn in one colour as a template
/// so AppKit tints it for light and dark menu bars.
func menuBarGlyph() -> NSImage {
    let side: CGFloat = 18  // points; the 100-unit box maps onto it
    let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 16, y: 74))
        path.curve(to: NSPoint(x: 34, y: 30), controlPoint1: NSPoint(x: 20, y: 46), controlPoint2: NSPoint(x: 26, y: 30))
        path.curve(to: NSPoint(x: 50, y: 56), controlPoint1: NSPoint(x: 42, y: 30), controlPoint2: NSPoint(x: 44, y: 56))
        path.curve(to: NSPoint(x: 66, y: 30), controlPoint1: NSPoint(x: 56, y: 56), controlPoint2: NSPoint(x: 58, y: 30))
        path.curve(to: NSPoint(x: 84, y: 74), controlPoint1: NSPoint(x: 74, y: 30), controlPoint2: NSPoint(x: 80, y: 46))
        path.lineWidth = 10
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let dot = NSBezierPath(ovalIn: NSRect(x: 84 - 7.5, y: 74 - 7.5, width: 15, height: 15))
        let toBox = AffineTransform(scale: rect.width / 100)
        path.transform(using: toBox)
        dot.transform(using: toBox)
        path.lineWidth *= rect.width / 100
        NSColor.black.setStroke()
        NSColor.black.setFill()
        path.stroke()
        dot.fill()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "MateBridge"
    return image
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
