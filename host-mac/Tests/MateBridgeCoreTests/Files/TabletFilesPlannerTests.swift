import Foundation
import Testing
@testable import MateBridgeCore

private let token = "0123456789abcdef0123456789abcdef"
private let ready = FilesInfo(state: .ready, port: 47010, token: token)

private func installGen(_ actions: [TabletFilesAction]) -> UInt64? {
    for case .installForward(_, let gen) in actions { return gen }
    return nil
}

private func mountGen(_ actions: [TabletFilesAction]) -> UInt64? {
    for case .mount(_, _, let gen) in actions { return gen }
    return nil
}

/// A USB session with READY info and the forward installed on `local`.
private func forwarded(local: UInt16 = 47010, info: FilesInfo = ready) -> TabletFilesPlanner {
    var p = TabletFilesPlanner()
    _ = p.sessionStarted(transport: .usb, capable: true)
    let gen = installGen(p.filesInfo(info))!
    #expect(p.forwardFinished(generation: gen, localPort: local).isEmpty)
    return p
}

@Suite struct TabletFilesPlannerTests {
    // MARK: Forward

    @Test func readyOnUsbInstallsTheForwardAndEnablesTheItem() {
        var p = TabletFilesPlanner()
        #expect(p.menu == .hidden)
        #expect(p.sessionStarted(transport: .usb, capable: true).isEmpty)
        #expect(p.menu == .enableOnTablet)
        let actions = p.filesInfo(ready)
        #expect(actions == [.installForward(remotePort: 47010, generation: installGen(actions)!)])
        #expect(p.menu == .preparing)
        #expect(p.forwardFinished(generation: installGen(actions)!, localPort: 47011).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
        #expect(p.forwardedLocalPort == 47011)
    }

    @Test func readyOnWifiIsKeptButNeverForwarded() {
        var p = TabletFilesPlanner()
        _ = p.sessionStarted(transport: .network, capable: true)
        #expect(p.menu == .usbOnly)
        #expect(p.filesInfo(ready).isEmpty)
        #expect(p.menu == .usbOnly)
        #expect(p.openRequested().isEmpty)
        #expect(p.forwardedLocalPort == nil)
    }

    @Test func incapableClientIsHiddenUntilItSendsFilesInfo() {
        var p = TabletFilesPlanner()
        _ = p.sessionStarted(transport: .usb, capable: false)
        #expect(p.menu == .hidden)
        _ = p.filesInfo(.off)
        #expect(p.menu == .enableOnTablet)
    }

    @Test func filesInfoWithoutASessionIsIgnored() {
        var p = TabletFilesPlanner()
        #expect(p.filesInfo(ready).isEmpty)
        #expect(p.menu == .hidden)
    }

    @Test func repeatedIdenticalReadyDoesNothing() {
        var p = forwarded()
        #expect(p.filesInfo(ready).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
    }

    @Test func unknownStateCountsAsOff() {
        var p = forwarded()
        let odd = FilesInfo(state: FilesState(rawValue: 9), port: 47010, token: token)
        #expect(p.filesInfo(odd) == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
        #expect(p.menu == .enableOnTablet)
    }

    @Test func failedForwardIsRetriedWhenTheMenuOpens() {
        var p = TabletFilesPlanner()
        _ = p.sessionStarted(transport: .usb, capable: true)
        let gen = installGen(p.filesInfo(ready))!
        #expect(p.forwardFinished(generation: gen, localPort: nil).isEmpty)
        #expect(p.menu == .preparing)
        let retry = p.retry()
        #expect(retry == [.installForward(remotePort: 47010, generation: installGen(retry)!)])
        #expect(installGen(retry)! != gen)
        #expect(p.retry().isEmpty)  // already installing
    }

    @Test func portChangeReForwards() {
        var p = forwarded()
        let moved = FilesInfo(state: .ready, port: 47020, token: "ffff")
        let actions = p.filesInfo(moved)
        #expect(actions == [.unmount(localPort: 47010), .removeForward(localPort: 47010),
                            .installForward(remotePort: 47020, generation: installGen(actions)!)])
    }

    @Test func tokenChangeOnTheSamePortDetachesTheVolumeButKeepsTheForward() {
        var p = forwarded()
        let restarted = FilesInfo(state: .ready, port: 47010, token: "fedcba9876543210fedcba9876543210")
        #expect(p.filesInfo(restarted) == [.unmount(localPort: 47010)])
        #expect(p.forwardedLocalPort == 47010)
        // The next mount uses the new token.
        guard case .mount(_, let secret, _)? = p.openRequested().first else {
            Issue.record("no mount")
            return
        }
        #expect(secret.value == restarted.token)
    }

    // MARK: Teardown

    @Test func offSessionEndUsbLossAndShutdownTearDownInOrder() {
        let teardown: [TabletFilesAction] = [.unmount(localPort: 47010), .removeForward(localPort: 47010)]
        var off = forwarded()
        #expect(off.filesInfo(.off) == teardown)
        #expect(off.menu == .enableOnTablet)

        var ended = forwarded()
        #expect(ended.sessionEnded() == teardown)
        #expect(ended.menu == .hidden)

        var unplugged = forwarded()
        #expect(unplugged.usbDevice(present: false) == teardown)
        #expect(unplugged.menu == .preparing)
        #expect(unplugged.usbDevice(present: false).isEmpty)

        var quitting = forwarded()
        #expect(quitting.shutdown() == teardown)
        #expect(quitting.menu == .hidden)
        #expect(quitting.sessionStarted(transport: .usb, capable: true).isEmpty)
        #expect(quitting.filesInfo(ready).isEmpty)
        #expect(quitting.menu == .hidden)
    }

    @Test func newSessionTearsDownALeftoverForward() {
        var p = forwarded()
        #expect(p.sessionStarted(transport: .usb, capable: true)
            == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
        #expect(p.menu == .enableOnTablet)
    }

    @Test func usbReturningReinstallsTheForwardForTheKeptReadyInfo() {
        var p = forwarded()
        _ = p.usbDevice(present: false)
        let back = p.usbDevice(present: true)
        #expect(back == [.installForward(remotePort: 47010, generation: installGen(back)!)])
        #expect(p.usbDevice(present: true).isEmpty)
    }

    @Test func readyWhileUsbDeviceIsLostWaitsForTheDevice() {
        var p = TabletFilesPlanner()
        _ = p.sessionStarted(transport: .usb, capable: true)
        _ = p.usbDevice(present: false)
        #expect(p.filesInfo(ready).isEmpty)
        #expect(p.menu == .preparing)
        #expect(installGen(p.usbDevice(present: true)) != nil)
    }

    @Test func usbSessionStartClearsAStaleDeviceLostFlag() {
        var p = TabletFilesPlanner()
        _ = p.usbDevice(present: false)
        _ = p.sessionStarted(transport: .usb, capable: true)
        #expect(installGen(p.filesInfo(ready)) != nil)
    }

    @Test func staleForwardResultIsUndone() {
        var p = TabletFilesPlanner()
        _ = p.sessionStarted(transport: .usb, capable: true)
        let gen = installGen(p.filesInfo(ready))!
        #expect(p.sessionEnded().isEmpty)  // still installing: nothing to tear down yet
        #expect(p.forwardFinished(generation: gen, localPort: 47010) == [.removeForward(localPort: 47010)])
        #expect(p.forwardFinished(generation: gen, localPort: nil).isEmpty)
        #expect(p.menu == .hidden)
    }

    @Test func staleForwardResultSharingTheCurrentLocalPortIsKept() {
        var p = TabletFilesPlanner()
        _ = p.sessionStarted(transport: .usb, capable: true)
        let old = installGen(p.filesInfo(ready))!
        _ = p.sessionStarted(transport: .usb, capable: true)
        let new = installGen(p.filesInfo(ready))!
        #expect(p.forwardFinished(generation: new, localPort: 47010).isEmpty)
        #expect(p.forwardFinished(generation: old, localPort: 47010).isEmpty)
        #expect(p.forwardedLocalPort == 47010)
    }

    // MARK: Mount

    @Test func openMountsWithTheTokenThenReveals() {
        var p = forwarded(local: 47011)
        let actions = p.openRequested()
        let gen = mountGen(actions)!
        #expect(actions == [.mount(localPort: 47011, secret: FilesSecret(token), generation: gen)])
        #expect(p.menu == .mounting)
        #expect(p.openRequested().isEmpty)  // one mount at a time
        #expect(p.mountFinished(generation: gen, localPort: 47011, path: "/Volumes/MatePad")
            == [.reveal(path: "/Volumes/MatePad")])
        #expect(p.menu == .ready(lastMountFailed: false))
        // Already mounted: opening again goes through `mount`, which only reveals an existing volume.
        #expect(mountGen(p.openRequested()) != nil)
    }

    @Test func failedMountIsShownAndCanBeRetried() {
        var p = forwarded()
        let gen = mountGen(p.openRequested())!
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: nil).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: true))
        #expect(mountGen(p.openRequested()) != nil)
        #expect(p.menu == .mounting)
    }

    @Test func openWithoutAForwardDoesNothing() {
        var p = TabletFilesPlanner()
        #expect(p.openRequested().isEmpty)
        _ = p.sessionStarted(transport: .usb, capable: true)
        _ = p.filesInfo(ready)
        #expect(p.openRequested().isEmpty)  // forward still installing
    }

    @Test func mountThatFinishesAfterTheSessionEndedIsDetached() {
        var p = forwarded()
        let gen = mountGen(p.openRequested())!
        #expect(p.sessionEnded() == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad")
            == [.unmount(localPort: 47010)])
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: nil).isEmpty)
    }

    @Test func mountWithAnOldTokenIsDetachedWhenItFinishes() {
        var p = forwarded()
        let gen = mountGen(p.openRequested())!
        _ = p.filesInfo(FilesInfo(state: .ready, port: 47010, token: "new"))
        #expect(p.menu == .ready(lastMountFailed: false))
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad")
            == [.unmount(localPort: 47010)])
    }

    @Test func secretNeverAppearsInActionDescriptions() {
        var p = forwarded()
        let actions = p.openRequested()
        #expect(!String(describing: actions).contains(token))
        #expect(!String(reflecting: actions).contains(token))
    }
}

@Suite struct WebDavMountTests {
    @Test func urlHasNoCredentials() {
        let url = WebDavMount.url(localPort: 47010)
        #expect(url.absoluteString == "http://127.0.0.1:47010/MatePad/")
        #expect(url.host == "127.0.0.1")
        #expect(url.lastPathComponent == "MatePad")
        #expect(url.user == nil && url.password == nil)
    }

    @Test func recognisesOurVolumeOnly() {
        #expect(WebDavMount.isOurs(fsType: "webdav", mountedFrom: "http://127.0.0.1:47010/MatePad/", localPort: 47010))
        #expect(WebDavMount.isOurs(fsType: "webdav", mountedFrom: "http://127.0.0.1:47010/MatePad", localPort: 47010))
        #expect(WebDavMount.isOurs(fsType: "webdav", mountedFrom: "http://127.0.0.1:47010/", localPort: 47010))
        #expect(WebDavMount.isOurs(fsType: "webdav",
                                   mountedFrom: WebDavMount.url(localPort: 47012).absoluteString, localPort: 47012))
        #expect(!WebDavMount.isOurs(fsType: "webdav", mountedFrom: "http://localhost:47010/MatePad/", localPort: 47010))
        #expect(!WebDavMount.isOurs(fsType: "webdav", mountedFrom: "http://127.0.0.1:47011/MatePad/", localPort: 47010))
        #expect(!WebDavMount.isOurs(fsType: "webdav", mountedFrom: "http://example.com:47010/MatePad/", localPort: 47010))
        #expect(!WebDavMount.isOurs(fsType: "webdav", mountedFrom: "https://127.0.0.1:47010/MatePad/", localPort: 47010))
        #expect(!WebDavMount.isOurs(fsType: "smbfs", mountedFrom: "http://127.0.0.1:47010/MatePad/", localPort: 47010))
        #expect(!WebDavMount.isOurs(fsType: "webdav", mountedFrom: "", localPort: 47010))
    }
}
