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
    for case .mount(_, _, let gen, _) in actions { return gen }
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

private let newToken = "fedcba9876543210fedcba9876543210"
private let restarted = FilesInfo(state: .ready, port: 47010, token: newToken)
private let volume = "/Volumes/MatePad"
/// The mount table identity of the volume `mounted()` creates (T-209).
private let ourVolume = VolumeIdentity(fsid: 0x0000_002a_0000_0031, fsType: "webdav",
                                       mountedFrom: "http://127.0.0.1:47010/MatePad/")

/// `forwarded()` plus a user mount that succeeded at `/Volumes/MatePad`.
private func mounted(local: UInt16 = 47010) -> TabletFilesPlanner {
    var p = forwarded(local: local)
    let gen = mountGen(p.openRequested())!
    #expect(p.mountFinished(generation: gen, localPort: local, path: "/Volumes/MatePad", identity: ourVolume)
        == [.reveal(path: "/Volumes/MatePad")])
    #expect(p.remountsAfterRestart)
    return p
}

/// The device case of T-209 after a failed first force: a volume busy at session end, a new session with a new token
/// on the same forward port, the leftover still there and dead.
private func deadLeftoverWithForward() -> TabletFilesPlanner {
    var p = mounted()
    _ = p.sessionEnded()
    _ = p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
    _ = p.sessionStarted(transport: .usb, capable: true)
    let install = p.filesInfo(restarted)
    _ = p.forceUnmountFinished(path: volume, localPort: 47010, gone: false)
    _ = p.forwardFinished(generation: installGen(install)!, localPort: 47010)
    #expect(p.leftoverPaths == [volume])
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
        guard case .mount(_, let secret, _, _)? = p.openRequested().first else {
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
        #expect(actions == [.mount(localPort: 47011, secret: FilesSecret(token), generation: gen, knownPath: nil)])
        #expect(p.menu == .mounting)
        #expect(p.openRequested().isEmpty)  // one mount at a time
        #expect(p.mountFinished(generation: gen, localPort: 47011, path: "/Volumes/MatePad")
            == [.reveal(path: "/Volumes/MatePad")])
        #expect(p.menu == .ready(lastMountFailed: false))
        // Already mounted: opening again passes the owned path, which the host only reveals if still mounted.
        guard case .mount(_, _, _, let known)? = p.openRequested().first else {
            Issue.record("no mount")
            return
        }
        #expect(known == "/Volumes/MatePad")
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
        #expect(p.sessionEnded() == [.cancelMount(generation: gen), .unmount(localPort: 47010),
                                     .removeForward(localPort: 47010)])
        // If NetFS still reports it (the cancel raced the completion), only that volume is detached.
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad")
            == [.unmountPath(path: "/Volumes/MatePad", localPort: 47010)])
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: nil).isEmpty)
    }

    @Test func mountWithAnOldTokenIsDetachedWhenItFinishes() {
        var p = forwarded()
        let gen = mountGen(p.openRequested())!
        let actions = p.filesInfo(FilesInfo(state: .ready, port: 47010, token: "new"))
        // T-206: the user asked for the volume, so the restart remounts it with the new token.
        #expect(actions == [.cancelMount(generation: gen), .unmount(localPort: 47010),
                            .mount(localPort: 47010, secret: FilesSecret("new"), generation: mountGen(actions)!,
                                   knownPath: nil)])
        #expect(p.menu == .mounting)
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad")
            == [.unmountPath(path: "/Volumes/MatePad", localPort: 47010)])
    }

    @Test func staleMountNeverDetachesTheCurrentSessionsVolumeOnAReusedPort() {
        var p = forwarded()
        let old = mountGen(p.openRequested())!
        _ = p.sessionEnded()
        // A new session gets the same local port and mounts.
        _ = p.sessionStarted(transport: .usb, capable: true)
        let fwd = installGen(p.filesInfo(ready))!
        _ = p.forwardFinished(generation: fwd, localPort: 47010)
        let current = mountGen(p.openRequested())!
        #expect(p.mountFinished(generation: current, localPort: 47010, path: "/Volumes/MatePad")
            == [.reveal(path: "/Volumes/MatePad")])
        // The old request reports late: never a port-wide unmount, never the current path.
        #expect(p.mountFinished(generation: old, localPort: 47010, path: "/Volumes/MatePad").isEmpty)
        #expect(p.mountFinished(generation: old, localPort: 47010, path: "/Volumes/MatePad-1")
            == [.unmountPath(path: "/Volumes/MatePad-1", localPort: 47010)])
        #expect(p.mountFinished(generation: old, localPort: 47010, path: nil).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
    }

    @Test func teardownWithoutAMountInFlightCancelsNothing() {
        var p = forwarded()
        #expect(p.sessionEnded() == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
    }

    // MARK: Forward removal ownership

    @Test func successfulRemovalClearsOwnership() {
        var p = forwarded()
        _ = p.sessionEnded()
        #expect(p.owedForwardPorts == [47010])
        #expect(p.forwardRemoved(localPort: 47010, success: true).isEmpty)
        #expect(p.owedForwardPorts.isEmpty)
        #expect(p.forwardRemoved(localPort: 47010, success: false).isEmpty)  // not ours any more
    }

    @Test func failedRemovalRetriesWithBackoffThenWaitsForTheNextEvent() {
        var p = forwarded()
        _ = p.sessionEnded()
        #expect(p.forwardRemoved(localPort: 47010, success: false) == [.retryRemoveForward(localPort: 47010, delay: 1)])
        #expect(p.forwardRemovalDue(localPort: 47010) == [.removeForward(localPort: 47010)])
        #expect(p.forwardRemoved(localPort: 47010, success: false) == [.retryRemoveForward(localPort: 47010, delay: 2)])
        #expect(p.forwardRemovalDue(localPort: 47010) == [.removeForward(localPort: 47010)])
        #expect(p.forwardRemoved(localPort: 47010, success: false) == [.retryRemoveForward(localPort: 47010, delay: 4)])
        #expect(p.forwardRemovalDue(localPort: 47010) == [.removeForward(localPort: 47010)])
        #expect(p.forwardRemoved(localPort: 47010, success: false).isEmpty)  // round over
        #expect(p.forwardRemovalDue(localPort: 47010).isEmpty)
        #expect(p.owedForwardPorts == [47010])  // ownership kept
        // The next session event starts a new round.
        #expect(p.sessionStarted(transport: .network, capable: true) == [.removeForward(localPort: 47010)])
        #expect(p.forwardRemoved(localPort: 47010, success: false) == [.retryRemoveForward(localPort: 47010, delay: 1)])
    }

    @Test func givenUpRemovalIsRetriedWhenUsbComesBackAndAtShutdown() {
        var p = forwarded()
        _ = p.usbDevice(present: false)
        for _ in 0..<TabletFilesPlanner.removalAttempts { _ = p.forwardRemoved(localPort: 47010, success: false) }
        let back = p.usbDevice(present: true)
        #expect(back.first == .removeForward(localPort: 47010))
        #expect(installGen(back) != nil)  // and the session's forward comes back
        var q = forwarded()
        _ = q.sessionEnded()
        _ = q.forwardRemoved(localPort: 47010, success: false)  // a retry is scheduled, still owed
        #expect(q.shutdown() == [.removeForward(localPort: 47010)])
        #expect(q.forwardRemoved(localPort: 47010, success: false).isEmpty)  // no retries after shutdown
        #expect(q.forwardRemovalDue(localPort: 47010).isEmpty)
    }

    @Test func shutdownTriesTheCurrentAndOwedForwardsOnce() {
        var p = TabletFilesPlanner()
        _ = p.sessionStarted(transport: .usb, capable: true)
        let stale = installGen(p.filesInfo(ready))!
        _ = p.sessionEnded()
        #expect(p.forwardFinished(generation: stale, localPort: 47011) == [.removeForward(localPort: 47011)])
        _ = p.forwardRemoved(localPort: 47011, success: false)
        _ = p.sessionStarted(transport: .usb, capable: true)
        let gen = installGen(p.filesInfo(ready))!
        _ = p.forwardFinished(generation: gen, localPort: 47010)
        #expect(p.shutdown() == [.unmount(localPort: 47010), .removeForward(localPort: 47010),
                                 .removeForward(localPort: 47011)])
    }

    @Test func aNewForwardOnAnOwedPortEndsThatDebt() {
        var p = forwarded()
        _ = p.sessionEnded()
        for _ in 0..<TabletFilesPlanner.removalAttempts { _ = p.forwardRemoved(localPort: 47010, success: false) }
        _ = p.sessionStarted(transport: .usb, capable: true)  // new round: removal sent again
        _ = p.forwardRemoved(localPort: 47010, success: false)
        let gen = installGen(p.filesInfo(ready))!
        _ = p.forwardFinished(generation: gen, localPort: 47010)  // adb let us bind it: the old one is gone
        #expect(p.owedForwardPorts.isEmpty)
        #expect(p.forwardRemovalDue(localPort: 47010).isEmpty)  // the pending retry must not kill the new one
    }

    // MARK: Remount after a server restart (T-206)

    @Test func tokenChangeRemountsAMountedVolumeOnceOurUnmountIsReported() {
        var p = mounted()
        #expect(p.filesInfo(restarted) == [.unmount(localPort: 47010)])
        #expect(p.watchedPaths == [volume])
        let remount = p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: [])
        #expect(remount == [.mount(localPort: 47010, secret: FilesSecret(newToken), generation: mountGen(remount)!,
                                   knownPath: nil)])
        #expect(p.menu == .mounting)
        #expect(p.watchedPaths.isEmpty)
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: []).isEmpty)  // nothing owed now
        #expect(p.filesInfo(restarted).isEmpty)  // the same READY again: no second attempt
    }

    @Test func offThenReadyRemountsOnceTheNewForwardIsUp() {
        var p = mounted()
        #expect(p.filesInfo(.off) == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
        #expect(p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: []).isEmpty)
        let late = p.volumeUnmounted(path: volume, mountedNow: [])  // our own unmount's notification
        #expect(!late)
        #expect(p.remountsAfterRestart)
        let install = p.filesInfo(FilesInfo(state: .ready, port: 47020, token: newToken))
        #expect(install == [.installForward(remotePort: 47020, generation: installGen(install)!)])
        let up = p.forwardFinished(generation: installGen(install)!, localPort: 47011)
        #expect(up == [.mount(localPort: 47011, secret: FilesSecret(newToken), generation: mountGen(up)!,
                              knownPath: nil)])
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: 47011).isEmpty)
    }

    @Test func remountWaitsForTheUnmountResultWhicheverComesFirst() {
        var p = mounted()
        let install = p.filesInfo(FilesInfo(state: .ready, port: 47020, token: newToken))
        #expect(install == [.unmount(localPort: 47010), .removeForward(localPort: 47010),
                            .installForward(remotePort: 47020, generation: installGen(install)!)])
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: 47011).isEmpty)  // result not in yet
        #expect(mountGen(p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: [])) != nil)
    }

    @Test func neverOpenedMeansNoRemount() {
        var p = forwarded()
        #expect(!p.remountsAfterRestart)
        #expect(p.filesInfo(restarted) == [.unmount(localPort: 47010)])
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: []).isEmpty)
        _ = p.filesInfo(.off)
        let install = p.filesInfo(ready)
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: 47010).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
    }

    @Test func ejectSeenBeforeTheRestartPreventsTheRemount() {
        var p = mounted()
        let eject = p.volumeUnmounted(path: volume, mountedNow: [])
        #expect(eject)
        #expect(!p.remountsAfterRestart)
        #expect(p.watchedPaths.isEmpty)
        let again = p.volumeUnmounted(path: volume, mountedNow: [])  // a duplicate notification
        #expect(!again)
        #expect(p.filesInfo(restarted) == [.unmount(localPort: 47010)])
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: []).isEmpty)
        // Opening again brings the intent back, and with it the remount.
        let gen = mountGen(p.openRequested())!
        #expect(p.openRequested().isEmpty)
        _ = p.mountFinished(generation: gen, localPort: 47010, path: volume)
        #expect(p.filesInfo(ready) == [.unmount(localPort: 47010)])
        #expect(mountGen(p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: [])) != nil)
    }

    @Test func ejectSeenOnlyAfterATokenChangeStillPreventsTheRemount() {
        var p = mounted()
        // The user ejects, but the restart is handled before the notification: our unmount finds nothing.
        #expect(p.filesInfo(restarted) == [.unmount(localPort: 47010)])
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: []).isEmpty)
        #expect(!p.remountsAfterRestart)
        #expect(p.watchedPaths.isEmpty)
        let late = p.volumeUnmounted(path: volume, mountedNow: [])
        #expect(!late)
        // The next READY does not mount either.
        _ = p.filesInfo(.off)
        let install = p.filesInfo(ready)
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: 47010).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
    }

    @Test func ejectSeenOnlyAfterOffStillPreventsTheRemount() {
        var p = mounted()
        #expect(p.filesInfo(.off) == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: []).isEmpty)
        #expect(!p.remountsAfterRestart)
        let install = p.filesInfo(restarted)
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: 47010).isEmpty)
    }

    @Test func ourOwnUnmountWithALateNotificationStillRemounts() {
        var p = mounted()
        _ = p.filesInfo(restarted)
        let gen = mountGen(p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: []))!
        let beforeRemount = p.volumeUnmounted(path: volume, mountedNow: [])
        #expect(!beforeRemount)
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: volume).isEmpty)
        let afterRemount = p.volumeUnmounted(path: volume, mountedNow: [volume])  // landed on the same path
        #expect(!afterRemount)
        #expect(p.remountsAfterRestart)
        // The next restart remounts again.
        _ = p.filesInfo(.off)
        #expect(p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: []).isEmpty)
        let install = p.filesInfo(ready)
        #expect(mountGen(p.forwardFinished(generation: installGen(install)!, localPort: 47010)) != nil)
    }

    @Test func busyOldVolumeIsOursAndItsLaterUnmountIsNotAnEject() {
        var p = mounted()
        _ = p.filesInfo(restarted)
        // T-209: the busy old volume is dead (new token), so it is forced first; here the force fails too.
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
            == [.forceUnmount(path: volume, localPort: 47010, identity: ourVolume)])
        let gen = mountGen(p.forceUnmountFinished(path: volume, localPort: 47010, gone: false))!
        _ = p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad-1")
        let old = p.volumeUnmounted(path: volume, mountedNow: ["/Volumes/MatePad-1"])
        #expect(!old)
        #expect(p.remountsAfterRestart)
        #expect(p.watchedPaths == ["/Volumes/MatePad-1"])
        let eject = p.volumeUnmounted(path: "/Volumes/MatePad-1/", mountedNow: [])
        #expect(eject)
        #expect(!p.remountsAfterRestart)
    }

    @Test func otherVolumesAndStillMountedPathsAreNotEjects() {
        var p = mounted()
        let other = p.volumeUnmounted(path: "/Volumes/MatePad-1", mountedNow: [volume])
        let backup = p.volumeUnmounted(path: "/Volumes/Backup", mountedNow: [volume])
        let stillThere = p.volumeUnmounted(path: volume, mountedNow: [volume])
        #expect(!other && !backup && !stillThere)
        #expect(p.remountsAfterRestart)
        #expect(p.watchedPaths == [volume])
    }

    @Test func unmountResultOfAnotherPortResolvesNothing() {
        var p = mounted()
        _ = p.filesInfo(restarted)
        #expect(p.unmountFinished(localPort: 47099, detached: [], stillMounted: []).isEmpty)
        #expect(p.remountsAfterRestart)
        #expect(mountGen(p.unmountFinished(localPort: 47010, detached: [volume + "/"], stillMounted: [])) != nil)
    }

    @Test func replacedVolumesAreBoundedAndForgottenPerSession() {
        var p = forwarded()
        for i in 0..<6 {
            let gen = mountGen(p.openRequested())!
            _ = p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad-\(i)")
            _ = p.filesInfo(FilesInfo(state: .ready, port: 47010, token: "t\(i)"))  // no result reported
        }
        #expect(TabletFilesPlanner.rememberedMounts == 4)
        #expect(p.watchedPaths == Set((2..<6).map { "/Volumes/MatePad-\($0)" }))
        _ = p.sessionEnded()
        #expect(p.watchedPaths.isEmpty)

        var q = mounted()
        _ = q.filesInfo(restarted)
        _ = q.sessionStarted(transport: .usb, capable: true)
        #expect(q.watchedPaths.isEmpty)
        var r = mounted()
        _ = r.shutdown()
        #expect(r.watchedPaths.isEmpty)
        #expect(r.unmountFinished(localPort: 47010, detached: [volume], stillMounted: []).isEmpty)
    }

    @Test func sessionEndAndShutdownForgetTheIntent() {
        var ended = mounted()
        _ = ended.sessionEnded()
        #expect(!ended.remountsAfterRestart)
        _ = ended.unmountFinished(localPort: 47010, detached: [volume], stillMounted: [])
        _ = ended.sessionStarted(transport: .usb, capable: true)
        let install = ended.filesInfo(ready)
        #expect(ended.forwardFinished(generation: installGen(install)!, localPort: 47010).isEmpty)
        #expect(mountGen(ended.openRequested()) != nil)  // a later session needs the user's open

        var restartedSession = mounted()
        _ = restartedSession.sessionStarted(transport: .usb, capable: true)  // a new session without an end
        #expect(!restartedSession.remountsAfterRestart)

        var toWifi = mounted()
        _ = toWifi.sessionStarted(transport: .network, capable: true)
        #expect(!toWifi.remountsAfterRestart)
        #expect(toWifi.filesInfo(ready).isEmpty)

        var quitting = mounted()
        _ = quitting.shutdown()
        #expect(!quitting.remountsAfterRestart)
        let afterShutdown = quitting.volumeUnmounted(path: volume, mountedNow: [])
        #expect(!afterShutdown)
    }

    @Test func failedRemountIsNotRetriedUntilTheNextReady() {
        var p = mounted()
        _ = p.filesInfo(restarted)
        let gen = mountGen(p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: []))!
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: nil).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: true))
        #expect(p.filesInfo(restarted).isEmpty)
        #expect(p.retry().isEmpty)
        #expect(p.usbDevice(present: true).isEmpty)
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: []).isEmpty)
        #expect(p.remountsAfterRestart)  // the user did not eject: the next restart tries once more
        let next = p.filesInfo(ready)  // nothing was mounted, so no result to wait for
        #expect(next.first == .unmount(localPort: 47010))
        #expect(mountGen(next) != nil)
        #expect(p.openRequested().isEmpty)  // still mounting
    }

    @Test func automaticRemountIsNotRevealed() {
        var p = mounted()
        _ = p.filesInfo(restarted)
        let gen = mountGen(p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: []))!
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: volume).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
        // The user opening it afterwards reveals the remounted volume.
        let open = p.openRequested()
        let userGen = mountGen(open)!
        #expect(open == [.mount(localPort: 47010, secret: FilesSecret(newToken), generation: userGen,
                                knownPath: volume)])
        #expect(p.mountFinished(generation: userGen, localPort: 47010, path: volume) == [.reveal(path: volume)])
    }

    @Test func remountWaitsForAFailedForwardThenFiresOnce() {
        var p = mounted()
        _ = p.filesInfo(.off)
        _ = p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: [])
        let install = p.filesInfo(ready)
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: nil).isEmpty)
        let retry = p.retry()
        #expect(mountGen(p.forwardFinished(generation: installGen(retry)!, localPort: 47010)) != nil)
        #expect(p.openRequested().isEmpty)
    }

    @Test func remountOwedAcrossUsbLossFiresWhenTheDeviceReturns() {
        var p = mounted()
        #expect(p.usbDevice(present: false) == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
        #expect(p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: []).isEmpty)
        #expect(p.filesInfo(restarted).isEmpty)
        let back = p.usbDevice(present: true)
        #expect(mountGen(back) == nil)
        #expect(mountGen(p.forwardFinished(generation: installGen(back)!, localPort: 47010)) != nil)
    }

    @Test func restartDuringTheUsersMountRemountsWithTheNewToken() {
        var p = forwarded()
        let userGen = mountGen(p.openRequested())!
        let actions = p.filesInfo(restarted)
        let gen = mountGen(actions)!
        #expect(actions == [.cancelMount(generation: userGen), .unmount(localPort: 47010),
                            .mount(localPort: 47010, secret: FilesSecret(newToken), generation: gen, knownPath: nil)])
        // The user's request reports late: only its own volume is detached, the remount is kept.
        #expect(p.mountFinished(generation: userGen, localPort: 47010, path: "/Volumes/MatePad-1")
            == [.unmountPath(path: "/Volumes/MatePad-1", localPort: 47010)])
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: volume).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
    }

    // MARK: Dead leftovers (T-209)

    @Test func tokenChangeWithABusyVolumeForcesItOnceThenRemounts() {
        var p = mounted()
        #expect(p.filesInfo(restarted) == [.unmount(localPort: 47010)])
        // EBUSY: the old volume stays, but its token is dead, so it is forced once and the remount waits for that.
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume + "/"])
            == [.forceUnmount(path: volume, localPort: 47010, identity: ourVolume)])
        #expect(p.leftoverPaths == [volume])
        #expect(p.watchedPaths.isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
        let remount = p.forceUnmountFinished(path: volume, localPort: 47010, gone: true)
        #expect(remount == [.mount(localPort: 47010, secret: FilesSecret(newToken), generation: mountGen(remount)!,
                                   knownPath: nil)])
        #expect(p.leftoverPaths.isEmpty)
        #expect(p.forceUnmountFinished(path: volume, localPort: 47010, gone: true).isEmpty)  // not pending any more
        // The remount is a new volume at the same path: a new fsid.
        let remounted = VolumeIdentity(fsid: 0x0000_002a_0000_0040, fsType: "webdav",
                                       mountedFrom: "http://127.0.0.1:47010/MatePad/")
        #expect(p.mountFinished(generation: mountGen(remount)!, localPort: 47010, path: volume, identity: remounted)
            .isEmpty)  // no reveal
        #expect(p.remountsAfterRestart)
        // The next restart with a busy volume forces again (a new leftover), never a loop within one READY.
        #expect(p.filesInfo(ready) == [.unmount(localPort: 47010)])
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
            == [.forceUnmount(path: volume, localPort: 47010, identity: remounted)])
        #expect(mountGen(p.forceUnmountFinished(path: volume, localPort: 47010, gone: false)) != nil)
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)
    }

    @Test func busyVolumeLeftAtSessionEndIsForcedOnceTheNextSessionHasANewToken() {
        // The device case: the tablet app restarts while "MatePad" is open in Finder.
        var p = mounted()
        #expect(p.sessionEnded() == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
        // Session end says nothing about the token: busy, so it stays, and nothing is forced.
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)
        #expect(p.leftoverPaths == [volume])
        #expect(p.watchedPaths.isEmpty)
        _ = p.forwardRemoved(localPort: 47010, success: true)
        #expect(p.sessionStarted(transport: .usb, capable: true).isEmpty)
        let actions = p.filesInfo(restarted)
        #expect(actions == [.forceUnmount(path: volume, localPort: 47010, identity: ourVolume),
                            .installForward(remotePort: 47010, generation: installGen(actions)!)])
        #expect(p.forceUnmountFinished(path: volume, localPort: 47010, gone: true).isEmpty)  // no intent: no mount
        #expect(p.forwardFinished(generation: installGen(actions)!, localPort: 47010).isEmpty)
        // The user's open now mounts with the new token and lands on the freed mount point.
        let open = p.openRequested()
        #expect(open == [.mount(localPort: 47010, secret: FilesSecret(newToken), generation: mountGen(open)!,
                                knownPath: nil)])
        #expect(p.mountFinished(generation: mountGen(open)!, localPort: 47010, path: volume) == [.reveal(path: volume)])
        #expect(p.leftoverPaths.isEmpty)
    }

    @Test func remountAfterOffWaitsForThePendingForce() {
        var p = mounted()
        _ = p.filesInfo(.off)
        // OFF: no READY, so the busy volume is not provably dead yet.
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)
        let actions = p.filesInfo(restarted)
        #expect(actions == [.forceUnmount(path: volume, localPort: 47010, identity: ourVolume),
                            .installForward(remotePort: 47010, generation: installGen(actions)!)])
        #expect(p.forwardFinished(generation: installGen(actions)!, localPort: 47010).isEmpty)  // force pending
        #expect(mountGen(p.forceUnmountFinished(path: volume, localPort: 47010, gone: true)) != nil)
    }

    @Test func mountCollidingWithADeadLeftoverForcesItAndRetriesOnce() {
        var p = mounted()
        _ = p.sessionEnded()
        _ = p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
        _ = p.sessionStarted(transport: .usb, capable: true)
        let install = p.filesInfo(restarted)
        #expect(p.forceUnmountFinished(path: volume, localPort: 47010, gone: false).isEmpty)  // the first force failed
        #expect(p.leftoverPaths == [volume])
        _ = p.forwardFinished(generation: installGen(install)!, localPort: 47010)
        let gen = mountGen(p.openRequested())!
        // NetFS: EEXIST, the URL is still mounted at our dead volume's path.
        #expect(p.mountCollided(generation: gen, localPort: 47010, mountedNow: [volume])
            == [.forceUnmount(path: volume, localPort: 47010, identity: ourVolume)])
        #expect(p.menu == .mounting)
        #expect(p.openRequested().isEmpty)
        let retry = p.forceUnmountFinished(path: volume, localPort: 47010, gone: true)
        #expect(retry == [.mount(localPort: 47010, secret: FilesSecret(newToken), generation: mountGen(retry)!,
                                 knownPath: nil)])
        #expect(p.mountFinished(generation: mountGen(retry)!, localPort: 47010, path: volume) == [.reveal(path: volume)])
        #expect(p.menu == .ready(lastMountFailed: false))
    }

    @Test func collisionRetryIsTriedOnlyOnce() {
        var p = deadLeftoverWithForward()
        let gen = mountGen(p.openRequested())!
        #expect(p.mountCollided(generation: gen, localPort: 47010, mountedNow: [volume]).count == 1)
        let retry = mountGen(p.forceUnmountFinished(path: volume, localPort: 47010, gone: true))!
        // Something remounted the URL in between: no second force, the failure shows.
        #expect(p.mountCollided(generation: retry, localPort: 47010, mountedNow: [volume]).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: true))

        var q = deadLeftoverWithForward()
        let qGen = mountGen(q.openRequested())!
        _ = q.mountCollided(generation: qGen, localPort: 47010, mountedNow: [volume])
        #expect(q.forceUnmountFinished(path: volume, localPort: 47010, gone: false).isEmpty)  // force failed: no retry
        #expect(q.menu == .ready(lastMountFailed: true))
        #expect(q.leftoverPaths == [volume])
    }

    @Test func collisionWithAVolumeThatIsNotOursForcesNothing() {
        // The user's own "MatePad" (or anything we did not leave behind) is never forced.
        var p = forwarded()
        let gen = mountGen(p.openRequested())!
        #expect(p.mountCollided(generation: gen, localPort: 47010, mountedNow: [volume]).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: true))
        // A dead leftover that is not what blocks this URL is not forced by the collision either.
        var q = deadLeftoverWithForward()
        let qGen = mountGen(q.openRequested())!
        #expect(q.mountCollided(generation: qGen, localPort: 47010, mountedNow: ["/Volumes/MatePad-1"]).isEmpty)
        #expect(q.mountCollided(generation: qGen, localPort: 47010, mountedNow: [volume]).isEmpty)  // stale now
        #expect(q.menu == .ready(lastMountFailed: true))
    }

    @Test func liveTokenVolumeIsNeverForced() {
        // Session end with the same server still running: the volume is alive again with the next forward.
        var ended = mounted()
        _ = ended.sessionEnded()
        #expect(ended.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)
        _ = ended.sessionStarted(transport: .usb, capable: true)
        let install = ended.filesInfo(ready)  // same token
        #expect(install == [.installForward(remotePort: 47010, generation: installGen(install)!)])
        _ = ended.forwardFinished(generation: installGen(install)!, localPort: 47010)
        let gen = mountGen(ended.openRequested())!
        #expect(ended.mountCollided(generation: gen, localPort: 47010, mountedNow: [volume]).isEmpty)
        #expect(ended.menu == .ready(lastMountFailed: true))
        // A later new token makes it dead: then it is forced, after the normal unmount.
        #expect(ended.filesInfo(restarted) == [.unmount(localPort: 47010),
                                               .forceUnmount(path: volume, localPort: 47010, identity: ourVolume)])

        // OFF and USB loss teardowns: busy volume kept, nothing forced while the token is unknown or the same.
        var off = mounted()
        _ = off.filesInfo(.off)
        #expect(off.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)
        let back = off.filesInfo(ready)
        #expect(back == [.installForward(remotePort: 47010, generation: installGen(back)!)])
        var unplugged = mounted()
        _ = unplugged.usbDevice(present: false)
        #expect(unplugged.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)
        #expect(!unplugged.usbDevice(present: true).contains { if case .forceUnmount = $0 { true } else { false } })
        var quitting = mounted()
        _ = quitting.shutdown()
        #expect(quitting.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)
        #expect(quitting.leftoverPaths.isEmpty)
    }

    @Test func forcedUnmountIsNotAnEject() {
        var p = mounted()
        _ = p.filesInfo(restarted)
        _ = p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
        let early = p.volumeUnmounted(path: volume, mountedNow: [])  // the force's notification, before its result
        #expect(!early)
        #expect(p.remountsAfterRestart)
        let gen = mountGen(p.forceUnmountFinished(path: volume, localPort: 47010, gone: true))!
        let beforeRemount = p.volumeUnmounted(path: volume, mountedNow: [])
        #expect(!beforeRemount)
        _ = p.mountFinished(generation: gen, localPort: 47010, path: volume)
        let afterRemount = p.volumeUnmounted(path: volume, mountedNow: [volume])
        #expect(!afterRemount)
        #expect(p.remountsAfterRestart)
    }

    @Test func leftoverIsForgottenWhenItIsGoneOrANewMountTakesItsPath() {
        var p = mounted()
        _ = p.sessionEnded()
        _ = p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
        _ = p.sessionStarted(transport: .usb, capable: true)
        let install = p.filesInfo(ready)
        _ = p.forwardFinished(generation: installGen(install)!, localPort: 47010)
        // The next teardown's unmount detached it (the user closed the Finder window): forgotten, never forced.
        _ = p.filesInfo(.off)
        #expect(p.unmountFinished(localPort: 47010, detached: [volume], stillMounted: []).isEmpty)
        #expect(p.leftoverPaths.isEmpty)
        #expect(p.filesInfo(restarted).allSatisfy { if case .forceUnmount = $0 { false } else { true } })

        // A mount of ours that lands on its mount point means it is gone.
        var q = mounted()
        _ = q.sessionEnded()
        _ = q.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
        _ = q.sessionStarted(transport: .usb, capable: true)
        let qInstall = q.filesInfo(ready)
        _ = q.forwardFinished(generation: installGen(qInstall)!, localPort: 47010)
        let gen = mountGen(q.openRequested())!
        _ = q.mountFinished(generation: gen, localPort: 47010, path: volume)
        #expect(q.leftoverPaths.isEmpty)
    }

    @Test func leftoversAreBounded() {
        var p = forwarded()
        var gen = mountGen(p.openRequested())!
        for i in 0..<6 {
            _ = p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad-\(i)")
            _ = p.filesInfo(.off)
            // `volume` is busy too, but it is not ours: never remembered.
            _ = p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume] + (0...i).map {
                "/Volumes/MatePad-\($0)"
            })
            let install = p.filesInfo(ready)  // same token: nothing forced
            gen = mountGen(p.forwardFinished(generation: installGen(install)!, localPort: 47010))!  // the remount
        }
        #expect(p.leftoverPaths == (2..<6).map { "/Volumes/MatePad-\($0)" })
    }

    @Test func remountWaitsForTheWholeCleanupAfterAUsbReturn() {
        // Codex P2: a busy leftover from a USB loss, no current volume, then a same-port token change.
        func setUp() -> TabletFilesPlanner {
            var p = mounted()
            #expect(p.usbDevice(present: false) == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
            #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)  // same token
            let back = p.usbDevice(present: true)
            #expect(p.forwardFinished(generation: installGen(back)!, localPort: 47010).isEmpty)
            // The normal unmount runs first, then the force; nothing mounts in this list.
            #expect(p.filesInfo(restarted) == [.unmount(localPort: 47010),
                                               .forceUnmount(path: volume, localPort: 47010, identity: ourVolume)])
            return p
        }
        // The host's order: unmount result, then force result. The remount comes only with the last one.
        var p = setUp()
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)
        #expect(mountGen(p.forceUnmountFinished(path: volume, localPort: 47010, gone: true)) != nil)
        // The other order: a force result first must not start a mount while the normal unmount is still queued.
        var q = setUp()
        #expect(q.forceUnmountFinished(path: volume, localPort: 47010, gone: true).isEmpty)
        #expect(q.menu == .ready(lastMountFailed: false))
        #expect(mountGen(q.unmountFinished(localPort: 47010, detached: [], stillMounted: [])) != nil)
    }

    @Test func leftoverWithoutAKnownIdentityIsNeverForced() {
        var p = forwarded()
        let gen = mountGen(p.openRequested())!
        _ = p.mountFinished(generation: gen, localPort: 47010, path: volume)  // the host could not read its identity
        _ = p.filesInfo(restarted)
        let next = p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
        #expect(!next.contains { if case .forceUnmount = $0 { true } else { false } })
        #expect(mountGen(next) != nil)  // the remount goes ahead (and may collide: then the failure shows)
        #expect(p.mountCollided(generation: mountGen(next)!, localPort: 47010, mountedNow: [volume]).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: true))
    }

    @Test func identityMatchesOnlyTheExactVolumeWeMounted() {
        // Codex P1: the decision right before MNT_FORCE.
        #expect(TabletFilesPlanner.identityMatches(expected: ourVolume, current: ourVolume, localPort: 47010))
        // Gone, or not ours on that port.
        #expect(!TabletFilesPlanner.identityMatches(expected: ourVolume, current: nil, localPort: 47010))
        // Someone else's volume mounted later at the same path from the very same URL: another fsid.
        let replacement = VolumeIdentity(fsid: 0x0000_002a_0000_0099, fsType: "webdav",
                                         mountedFrom: ourVolume.mountedFrom)
        #expect(!TabletFilesPlanner.identityMatches(expected: ourVolume, current: replacement, localPort: 47010))
        // Same fsid but another source or type: not the same volume.
        let otherShare = VolumeIdentity(fsid: ourVolume.fsid, fsType: "webdav",
                                        mountedFrom: "http://127.0.0.1:47010/Share/")
        #expect(!TabletFilesPlanner.identityMatches(expected: ourVolume, current: otherShare, localPort: 47010))
        let otherType = VolumeIdentity(fsid: ourVolume.fsid, fsType: "smbfs", mountedFrom: ourVolume.mountedFrom)
        #expect(!TabletFilesPlanner.identityMatches(expected: ourVolume, current: otherType, localPort: 47010))
        // The expected volume itself must be our exact URL on that port.
        #expect(!TabletFilesPlanner.identityMatches(expected: ourVolume, current: ourVolume, localPort: 47011))
        for from in ["http://127.0.0.1:47010/", "http://127.0.0.1:47010/Share/", "http://localhost:47010/MatePad/",
                     "https://127.0.0.1:47010/MatePad/", "http://u:p@127.0.0.1:47010/MatePad/",
                     "http://127.0.0.1:47010/MatePad/?x=1", "http://127.0.0.1/MatePad/"] {
            let id = VolumeIdentity(fsid: 7, fsType: "webdav", mountedFrom: from)
            #expect(!TabletFilesPlanner.identityMatches(expected: id, current: id, localPort: 47010), "\(from)")
        }
        let noSlash = VolumeIdentity(fsid: 7, fsType: "webdav", mountedFrom: "http://127.0.0.1:47010/MatePad")
        #expect(TabletFilesPlanner.identityMatches(expected: noSlash, current: noSlash, localPort: 47010))
    }

    @Test func reopeningAReplacedVolumeNeverAdoptsItAndNeverForcesIt() {
        // Codex P2 (second pass): our volume was ejected, another client mounted the same URL at the same path, and
        // the user reopens before the eject notification arrives.
        let replacement = VolumeIdentity(fsid: 0x0000_002a_0000_0077, fsType: "webdav",
                                         mountedFrom: ourVolume.mountedFrom)
        var p = mounted()
        let open = p.openRequested()
        let gen = mountGen(open)!
        #expect(open == [.mount(localPort: 47010, secret: FilesSecret(token), generation: gen, knownPath: volume)])
        // The host finds a volume at the known path, but it is not the one we mounted: not adopted.
        #expect(p.mountReused(generation: gen, localPort: 47010, path: volume, identity: replacement) == nil)
        #expect(p.watchedPaths.isEmpty)  // our record of that path is gone
        #expect(p.menu == .mounting)  // the host mounts afresh
        // Afresh, NetFS lands elsewhere; a later eject notification of the old path is not ours any more.
        _ = p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad-1", identity: ourVolume)
        let late = p.volumeUnmounted(path: volume, mountedNow: [volume, "/Volumes/MatePad-1"])
        #expect(!late)
        // Token change with both busy: only our own new volume can be forced, never the replacement.
        #expect(p.filesInfo(restarted) == [.unmount(localPort: 47010)])
        let next = p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume, "/Volumes/MatePad-1"])
        #expect(next == [.forceUnmount(path: "/Volumes/MatePad-1", localPort: 47010, identity: ourVolume)])
        #expect(p.leftoverPaths == ["/Volumes/MatePad-1"])

        // The same, but the fresh mount collides with the replacement (EEXIST): nothing is forced, ever.
        var q = mounted()
        let qGen = mountGen(q.openRequested())!
        #expect(q.mountReused(generation: qGen, localPort: 47010, path: volume, identity: replacement) == nil)
        #expect(q.mountCollided(generation: qGen, localPort: 47010, mountedNow: [volume]).isEmpty)
        #expect(q.menu == .ready(lastMountFailed: true))
        let restart = q.filesInfo(restarted)  // no current volume: the T-206 remount follows the unmount
        #expect(restart.first == .unmount(localPort: 47010) && mountGen(restart) != nil)
        #expect(q.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume]).isEmpty)
        #expect(q.leftoverPaths.isEmpty)
    }

    @Test func reopeningOurOwnVolumeKeepsTheIdentityWeRecorded() {
        var p = mounted()
        let gen = mountGen(p.openRequested())!
        #expect(p.mountReused(generation: gen, localPort: 47010, path: volume + "/", identity: ourVolume)
            == [.reveal(path: volume)])
        _ = p.filesInfo(restarted)
        #expect(p.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
            == [.forceUnmount(path: volume, localPort: 47010, identity: ourVolume)])

        // No identity recorded at mount time: reused by path as before, but it stays unforceable.
        var q = forwarded()
        let first = mountGen(q.openRequested())!
        _ = q.mountFinished(generation: first, localPort: 47010, path: volume)
        let again = mountGen(q.openRequested())!
        #expect(q.mountReused(generation: again, localPort: 47010, path: volume, identity: ourVolume)
            == [.reveal(path: volume)])
        _ = q.filesInfo(restarted)
        let next = q.unmountFinished(localPort: 47010, detached: [], stillMounted: [volume])
        #expect(!next.contains { if case .forceUnmount = $0 { true } else { false } })

        // A stale request reuses nothing and mounts nothing.
        var r = mounted()
        let stale = mountGen(r.openRequested())!
        _ = r.sessionEnded()
        #expect(r.mountReused(generation: stale, localPort: 47010, path: volume, identity: ourVolume) == [])
    }

    @Test func teardownDropsAPendingCollisionRetry() {
        var p = deadLeftoverWithForward()
        let gen = mountGen(p.openRequested())!
        _ = p.mountCollided(generation: gen, localPort: 47010, mountedNow: [volume])
        _ = p.sessionEnded()
        #expect(p.forceUnmountFinished(path: volume, localPort: 47010, gone: true).isEmpty)
        #expect(p.leftoverPaths.isEmpty)
        #expect(p.mountCollided(generation: gen, localPort: 47010, mountedNow: [volume]).isEmpty)
    }

    @Test func pathsAreComparedWithoutTrailingSlashes() {
        #expect(TabletFilesPlanner.samePath("/Volumes/MatePad", "/Volumes/MatePad/"))
        #expect(TabletFilesPlanner.samePath("/Volumes/MatePad//", "/Volumes/MatePad"))
        #expect(!TabletFilesPlanner.samePath("/Volumes/MatePad", "/Volumes/MatePad-1"))
        #expect(TabletFilesPlanner.normalizedPath("/") == "/")
        #expect(TabletFilesPlanner.normalizedPath("/Volumes/MatePad/") == "/Volumes/MatePad")
    }

    @Test func secretNeverAppearsInActionDescriptions() {
        var p = forwarded()
        let actions = p.openRequested()
        #expect(!String(describing: actions).contains(token))
        #expect(!String(reflecting: actions).contains(token))
    }
}

@Suite struct EpochCoalescerTests {
    @Test func burstKeepsTheLatestAndSchedulesOneDrain() {
        var c = EpochCoalescer<Int>()
        let first = c.offer(1, epoch: 1)
        let second = c.offer(2, epoch: 1)
        let third = c.offer(3, epoch: 1)
        #expect(first && !second && !third)
        let taken = c.take(epoch: 1)
        let again = c.take(epoch: 1)
        #expect(taken == 3 && again == nil)
        let afterDrain = c.offer(4, epoch: 1)
        #expect(afterDrain)  // after a drain a new one is needed
    }

    @Test func valueNeverCrossesASessionBoundary() {
        var c = EpochCoalescer<Int>()
        let old = c.offer(1, epoch: 1)
        let new = c.offer(2, epoch: 2)
        #expect(old && new)  // a new epoch needs its own drain
        let oldDrain = c.take(epoch: 1)
        let newDrain = c.take(epoch: 2)
        #expect(oldDrain == nil)  // the old drain gets nothing (that session ended)
        #expect(newDrain == 2)
    }
}

/// The cursor prefs and clipboard mailboxes (T-313) are this coalescer with a session epoch; these are the rules that
/// `CursorPrefsMailbox` and `LatestValueSlot` had.
@Suite struct EpochCoalescerBoundaryTests {
    @Test func theNewestWinsAndOnlyOneWakeIsScheduledPerEpoch() {
        var m = EpochCoalescer<Int>()
        let first = m.offer(1, epoch: 0), second = m.offer(2, epoch: 0), third = m.offer(3, epoch: 0)
        #expect(first && !second && !third)
        let taken = m.take(epoch: 0), again = m.take(epoch: 0)
        #expect(taken == 3 && again == nil)
        let afterWake = m.offer(4, epoch: 0)
        #expect(afterWake)  // the wake was spent
    }

    @Test func aBoundaryVoidsWhatWasPostedAndOldWakesAreStale() {
        var m = EpochCoalescer<Int>()
        let old = m.offer(1, epoch: 0)
        m.clear()  // the session ends and the next one starts: the epoch moves on
        let new = m.offer(2, epoch: 1)  // the old wake does not count for the new session: it gets its own
        let stale = m.take(epoch: 0)  // the stale wake runs first: it takes nothing and leaves the value alone
        let current = m.take(epoch: 1)
        #expect(old && new && stale == nil && current == 2)
    }

    @Test func clearDropsPendingAndTheNextValueSchedulesItsOwnWake() {
        var m = EpochCoalescer<Int>()
        _ = m.offer(1, epoch: 0)
        m.clear()
        let dropped = m.take(epoch: 0)
        let next = m.offer(2, epoch: 0)
        #expect(dropped == nil && next)
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
