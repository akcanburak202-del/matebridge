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

/// `forwarded()` plus a user mount that succeeded at `/Volumes/MatePad`.
private func mounted(local: UInt16 = 47010) -> TabletFilesPlanner {
    var p = forwarded(local: local)
    let gen = mountGen(p.openRequested())!
    #expect(p.mountFinished(generation: gen, localPort: local, path: "/Volumes/MatePad")
        == [.reveal(path: "/Volumes/MatePad")])
    #expect(p.remountsAfterRestart)
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

    @Test func tokenChangeRemountsAMountedVolumeWithTheNewToken() {
        var p = mounted()
        let restarted = FilesInfo(state: .ready, port: 47010, token: newToken)
        let actions = p.filesInfo(restarted)
        guard let gen = mountGen(actions) else {
            Issue.record("no remount")
            return
        }
        #expect(actions == [.unmount(localPort: 47010),
                            .mount(localPort: 47010, secret: FilesSecret(newToken), generation: gen, knownPath: nil)])
        #expect(p.menu == .mounting)
        #expect(p.filesInfo(restarted).isEmpty)  // the same READY again: no second attempt
    }

    @Test func offThenReadyRemountsOnceTheNewForwardIsUp() {
        var p = mounted()
        #expect(p.filesInfo(.off) == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
        #expect(p.remountsAfterRestart)
        let moved = FilesInfo(state: .ready, port: 47020, token: newToken)
        let install = p.filesInfo(moved)
        #expect(install == [.installForward(remotePort: 47020, generation: installGen(install)!)])
        let up = p.forwardFinished(generation: installGen(install)!, localPort: 47011)
        #expect(up == [.mount(localPort: 47011, secret: FilesSecret(newToken), generation: mountGen(up)!,
                              knownPath: nil)])
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: 47011).isEmpty)
    }

    @Test func portChangeWhileMountedRemountsOnTheNewForward() {
        var p = mounted()
        let install = p.filesInfo(FilesInfo(state: .ready, port: 47020, token: newToken))
        #expect(mountGen(install) == nil)  // not before the forward is up
        #expect(mountGen(p.forwardFinished(generation: installGen(install)!, localPort: 47010)) != nil)
    }

    @Test func neverOpenedMeansNoRemount() {
        var p = forwarded()
        #expect(!p.remountsAfterRestart)
        #expect(p.filesInfo(FilesInfo(state: .ready, port: 47010, token: newToken)) == [.unmount(localPort: 47010)])
        _ = p.filesInfo(.off)
        let install = p.filesInfo(ready)
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: 47010).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
    }

    @Test func ejectedVolumeIsNotRemounted() {
        var p = mounted()
        #expect(p.volumeUnmounted(path: "/Volumes/MatePad").isEmpty)
        #expect(!p.remountsAfterRestart)
        #expect(p.filesInfo(FilesInfo(state: .ready, port: 47010, token: newToken)) == [.unmount(localPort: 47010)])
        _ = p.filesInfo(.off)
        let install = p.filesInfo(ready)
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: 47010).isEmpty)
        // Opening again brings the intent back, and with it the remount.
        let gen = mountGen(p.openRequested())!
        #expect(p.openRequested().isEmpty)
        _ = p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad")
        #expect(mountGen(p.filesInfo(FilesInfo(state: .ready, port: 47010, token: newToken))) != nil)
    }

    @Test func unmountOfAnotherVolumeKeepsTheIntent() {
        var p = mounted()
        #expect(p.volumeUnmounted(path: "/Volumes/MatePad-1").isEmpty)
        #expect(p.volumeUnmounted(path: "/Volumes/Backup").isEmpty)
        #expect(p.remountsAfterRestart)
        // Our own token-change unmount clears the path first, so its notification never counts as an eject.
        let actions = p.filesInfo(FilesInfo(state: .ready, port: 47010, token: newToken))
        #expect(p.volumeUnmounted(path: "/Volumes/MatePad").isEmpty)
        #expect(p.remountsAfterRestart)
        #expect(p.mountFinished(generation: mountGen(actions)!, localPort: 47010, path: "/Volumes/MatePad").isEmpty)
        #expect(p.volumeUnmounted(path: "/Volumes/MatePad").isEmpty)  // now it is the user's eject
        #expect(!p.remountsAfterRestart)
    }

    @Test func sessionEndAndShutdownForgetTheIntent() {
        var ended = mounted()
        _ = ended.sessionEnded()
        #expect(!ended.remountsAfterRestart)
        _ = ended.sessionStarted(transport: .usb, capable: true)
        let install = ended.filesInfo(ready)
        #expect(ended.forwardFinished(generation: installGen(install)!, localPort: 47010).isEmpty)
        #expect(mountGen(ended.openRequested()) != nil)  // a later session needs the user's open

        var restarted = mounted()
        _ = restarted.sessionStarted(transport: .usb, capable: true)  // a new session without an end
        #expect(!restarted.remountsAfterRestart)

        var toWifi = mounted()
        _ = toWifi.sessionStarted(transport: .network, capable: true)
        #expect(!toWifi.remountsAfterRestart)
        #expect(toWifi.filesInfo(ready).isEmpty)

        var quitting = mounted()
        _ = quitting.shutdown()
        #expect(!quitting.remountsAfterRestart)
        #expect(quitting.volumeUnmounted(path: "/Volumes/MatePad").isEmpty)
    }

    @Test func failedRemountIsNotRetriedUntilTheNextReady() {
        var p = mounted()
        let restarted = FilesInfo(state: .ready, port: 47010, token: newToken)
        let gen = mountGen(p.filesInfo(restarted))!
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: nil).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: true))
        #expect(p.filesInfo(restarted).isEmpty)
        #expect(p.retry().isEmpty)
        #expect(p.usbDevice(present: true).isEmpty)
        #expect(p.remountsAfterRestart)  // the user did not eject: the next restart tries once more
        #expect(mountGen(p.filesInfo(ready)) != nil)
        #expect(p.openRequested().isEmpty)  // still mounting
    }

    @Test func automaticRemountIsNotRevealed() {
        var p = mounted()
        let gen = mountGen(p.filesInfo(FilesInfo(state: .ready, port: 47010, token: newToken)))!
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad").isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
        // The user opening it afterwards reveals the remounted volume.
        let open = p.openRequested()
        let userGen = mountGen(open)!
        #expect(open == [.mount(localPort: 47010, secret: FilesSecret(newToken), generation: userGen,
                                knownPath: "/Volumes/MatePad")])
        #expect(p.mountFinished(generation: userGen, localPort: 47010, path: "/Volumes/MatePad")
            == [.reveal(path: "/Volumes/MatePad")])
    }

    @Test func remountWaitsForAFailedForwardThenFiresOnce() {
        var p = mounted()
        _ = p.filesInfo(.off)
        let install = p.filesInfo(ready)
        #expect(p.forwardFinished(generation: installGen(install)!, localPort: nil).isEmpty)
        let retry = p.retry()
        #expect(mountGen(p.forwardFinished(generation: installGen(retry)!, localPort: 47010)) != nil)
        #expect(p.openRequested().isEmpty)
    }

    @Test func remountOwedAcrossUsbLossFiresWhenTheDeviceReturns() {
        var p = mounted()
        _ = p.usbDevice(present: false)
        #expect(p.filesInfo(FilesInfo(state: .ready, port: 47010, token: newToken)).isEmpty)
        let back = p.usbDevice(present: true)
        #expect(mountGen(back) == nil)
        #expect(mountGen(p.forwardFinished(generation: installGen(back)!, localPort: 47010)) != nil)
    }

    @Test func restartDuringTheUsersMountRemountsWithTheNewToken() {
        var p = forwarded()
        let userGen = mountGen(p.openRequested())!
        let actions = p.filesInfo(FilesInfo(state: .ready, port: 47010, token: newToken))
        let gen = mountGen(actions)!
        #expect(actions == [.cancelMount(generation: userGen), .unmount(localPort: 47010),
                            .mount(localPort: 47010, secret: FilesSecret(newToken), generation: gen, knownPath: nil)])
        // The user's request reports late: only its own volume is detached, the remount is kept.
        #expect(p.mountFinished(generation: userGen, localPort: 47010, path: "/Volumes/MatePad-1")
            == [.unmountPath(path: "/Volumes/MatePad-1", localPort: 47010)])
        #expect(p.mountFinished(generation: gen, localPort: 47010, path: "/Volumes/MatePad").isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
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
