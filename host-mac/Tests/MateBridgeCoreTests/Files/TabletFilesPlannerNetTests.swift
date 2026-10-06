import Foundation
import Testing
@testable import MateBridgeCore

// Wi-Fi branch of the tablet files planner (decision 0035, PROTOCOL.md 0x09 STANDBY and 0x0A): the upstream of the
// NetFS mount is the host's loopback proxy instead of `adb forward`, opened by the user's click through
// `FILES_NET(OPEN)`. The USB tests of `TabletFilesPlannerTests` are untouched and must keep passing byte for byte.

private let token = "0123456789abcdef0123456789abcdef"
private let newToken = "fedcba9876543210fedcba9876543210"
private let ready = FilesInfo(state: .ready, port: 47010, token: token)
private let restarted = FilesInfo(state: .ready, port: 47011, token: newToken)  // even a new port
private let proxyPort: UInt16 = 47012
private let filesPort: UInt16 = 47003
private let volume = "/Volumes/MatePad"
private let ourVolume = VolumeIdentity(fsid: 0x0000_002a_0000_0031, fsType: "webdav",
                                       mountedFrom: "http://127.0.0.1:47012/MatePad/")
private let open = FilesNet.open(port: filesPort, pool: 2, max: 12)

private func proxyGen(_ actions: [TabletFilesAction]) -> UInt64? {
    for case .startProxy(let gen) in actions { return gen }
    return nil
}

private func mountGen(_ actions: [TabletFilesAction]) -> UInt64? {
    for case .mount(_, _, let gen, _) in actions { return gen }
    return nil
}

private func wifi(netCapable: Bool = true) -> TabletFilesPlanner {
    var p = TabletFilesPlanner()
    #expect(p.sessionStarted(transport: .network, capable: true, netCapable: netCapable).isEmpty)
    return p
}

/// A Wi-Fi session at STANDBY after the user's click and the proxy start: `FILES_NET(OPEN)` went out, READY is awaited.
private func opening() -> (TabletFilesPlanner, proxy: UInt64) {
    var p = wifi()
    #expect(p.filesInfo(.standby).isEmpty)
    let gen = proxyGen(p.openRequested())!
    #expect(p.proxyFinished(generation: gen, localPort: proxyPort, filesPort: filesPort) == [.sendFilesNet(open)])
    return (p, gen)
}

/// The whole chain: STANDBY, click, proxy, OPEN, READY, mount at `/Volumes/MatePad`.
private func mounted() -> TabletFilesPlanner {
    var (p, _) = opening()
    let gen = mountGen(p.filesInfo(ready))!
    #expect(p.mountFinished(generation: gen, localPort: proxyPort, path: volume, identity: ourVolume) == [.reveal(path: volume)])
    #expect(p.remountsAfterRestart)
    return p
}

@Suite struct TabletFilesPlannerNetTests {
    // MARK: Offer

    @Test func standbyAndReadyOfferTheVolumeOnWifi() {
        var p = wifi()
        #expect(p.menu == .enableOnTablet)
        #expect(p.filesInfo(.standby).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
        #expect(p.filesInfo(ready).isEmpty)  // READY without a proxy: still just an offer
        #expect(p.menu == .ready(lastMountFailed: false))
        #expect(p.forwardedLocalPort == nil)
        #expect(p.filesInfo(.off).isEmpty)
        #expect(p.menu == .enableOnTablet)
    }

    @Test func aWifiClientWithoutBit12KeepsTheOldBehaviour() {
        var p = wifi(netCapable: false)
        #expect(p.menu == .usbOnly)
        #expect(p.filesInfo(ready).isEmpty)
        #expect(p.filesInfo(.standby).isEmpty)
        #expect(p.menu == .usbOnly)
        #expect(p.openRequested().isEmpty)
    }

    @Test func standbyOnUsbCountsAsOffAndNetCapableDoesNotChangeUsb() {
        var p = TabletFilesPlanner()
        _ = p.sessionStarted(transport: .usb, capable: true, netCapable: true)
        let actions = p.filesInfo(ready)
        guard case .installForward(let remote, let gen)? = actions.first else { Issue.record("no forward"); return }
        #expect(remote == 47010)
        _ = p.forwardFinished(generation: gen, localPort: 47010)
        #expect(p.menu == .ready(lastMountFailed: false))
        #expect(p.filesInfo(.standby) == [.unmount(localPort: 47010), .removeForward(localPort: 47010)])
        #expect(p.menu == .enableOnTablet)
    }

    // MARK: Open

    @Test func clickOpensTheProxyThenFilesNetThenMountsWhenReady() {
        var p = wifi()
        _ = p.filesInfo(.standby)
        let start = p.openRequested()
        let gen = proxyGen(start)!
        #expect(start == [.startProxy(generation: gen)])
        #expect(p.menu == .preparing)
        #expect(p.openRequested().isEmpty)  // a second click while it is on its way
        #expect(p.proxyFinished(generation: gen, localPort: proxyPort, filesPort: filesPort) == [.sendFilesNet(open)])
        #expect(p.menu == .preparing)  // FILES_NET(OPEN) is out, READY is awaited
        #expect(p.forwardedLocalPort == proxyPort)
        let mount = p.filesInfo(ready)
        guard case .mount(let local, let secret, let mountGen, nil)? = mount.first, mount.count == 1 else {
            Issue.record("no mount: \(mount)")
            return
        }
        #expect(local == proxyPort)
        #expect(secret.value == token)
        #expect(p.menu == .mounting)
        // The click is the user's own mount: it is revealed in Finder.
        #expect(p.mountFinished(generation: mountGen, localPort: proxyPort, path: volume, identity: ourVolume)
            == [.reveal(path: volume)])
        #expect(p.menu == .ready(lastMountFailed: false))
    }

    @Test func clickWhileReadyButWithoutAProxyMountsRightAfterTheProxyIsUp() {
        var p = wifi()
        _ = p.filesInfo(ready)
        let gen = proxyGen(p.openRequested())!
        let actions = p.proxyFinished(generation: gen, localPort: proxyPort, filesPort: filesPort)
        #expect(actions.first == .sendFilesNet(open))
        #expect(actions.count == 2)
        guard case .mount(_, let secret, let mountGen, _) = actions[1] else { Issue.record("no mount"); return }
        #expect(secret.value == token)
        #expect(p.mountFinished(generation: mountGen, localPort: proxyPort, path: volume, identity: ourVolume)
            == [.reveal(path: volume)])
    }

    @Test func readyArrivingBeforeTheProxyIsUpWaitsForIt() {
        var p = wifi()
        _ = p.filesInfo(.standby)
        let gen = proxyGen(p.openRequested())!
        #expect(p.filesInfo(ready).isEmpty)  // still installing
        let actions = p.proxyFinished(generation: gen, localPort: proxyPort, filesPort: filesPort)
        #expect(actions.first == .sendFilesNet(open))
        let mountGen = mountGen(actions)!
        #expect(p.mountFinished(generation: mountGen, localPort: proxyPort, path: volume, identity: ourVolume)
            == [.reveal(path: volume)])
    }

    @Test func clickAgainOnAMountedVolumeJustRevealsIt() {
        var p = mounted()
        let actions = p.openRequested()
        guard case .mount(_, _, let gen, let known)? = actions.first else { Issue.record("no mount"); return }
        #expect(known == volume)
        #expect(p.mountReused(generation: gen, localPort: proxyPort, path: volume, identity: ourVolume)
            == [.reveal(path: volume)])
    }

    @Test func aProxyThatCannotStartShowsTheFailureAndCanBeRetriedByClicking() {
        var p = wifi()
        _ = p.filesInfo(.standby)
        let gen = proxyGen(p.openRequested())!
        #expect(p.proxyFinished(generation: gen, localPort: nil, filesPort: 0).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: true))
        #expect(p.forwardedLocalPort == nil)
        #expect(p.retry().isEmpty)
        let again = p.openRequested()
        #expect(proxyGen(again) != nil && proxyGen(again) != gen)
        #expect(p.menu == .preparing)
    }

    @Test func aFailedMountAfterOpenIsShownAndCanBeTried() {
        var (p, _) = opening()
        let gen = mountGen(p.filesInfo(ready))!
        #expect(p.mountFinished(generation: gen, localPort: proxyPort, path: nil).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: true))
        #expect(mountGen(p.openRequested()) != nil)  // the proxy stays up: the click mounts again
    }

    @Test func nothingHappensWithoutAnOfferOrWhenShutDown() {
        var p = wifi()
        #expect(p.openRequested().isEmpty)  // neither STANDBY nor READY known
        _ = p.filesInfo(.standby)
        _ = p.shutdown()
        #expect(p.openRequested().isEmpty)
        #expect(p.menu == .hidden)
    }

    // MARK: Teardown (volume first, then the upstream)

    @Test func sessionEndDetachesTheVolumeThenStopsTheProxyWithoutAMessage() {
        var p = mounted()
        #expect(p.sessionEnded() == [.unmount(localPort: proxyPort), .stopProxy(localPort: proxyPort)])
        #expect(p.menu == .hidden)
        #expect(p.forwardedLocalPort == nil)
    }

    @Test func aNewSessionTearsTheOldProxyDownAndNeedsTheClickAgain() {
        var p = mounted()
        let out = p.sessionStarted(transport: .network, capable: true, netCapable: true)
        #expect(out == [.unmount(localPort: proxyPort), .stopProxy(localPort: proxyPort)])
        #expect(!p.remountsAfterRestart)
        #expect(p.filesInfo(.standby).isEmpty)  // no automatic open: the user has not asked in this session
    }

    @Test func tabletOffTakesTheProxyAwayButKeepsTheIntent() {
        var p = mounted()
        #expect(p.filesInfo(.off) == [.unmount(localPort: proxyPort), .stopProxy(localPort: proxyPort)])
        #expect(p.unmountFinished(localPort: proxyPort, detached: [volume], stillMounted: []).isEmpty)
        #expect(p.menu == .enableOnTablet)
        #expect(p.remountsAfterRestart)
        // Sharing is switched on again on the tablet: STANDBY asks for a new OPEN by itself (T-206 on Wi-Fi).
        let reopen = p.filesInfo(.standby)
        let gen = proxyGen(reopen)!
        #expect(reopen == [.startProxy(generation: gen)])
        #expect(p.proxyFinished(generation: gen, localPort: proxyPort, filesPort: filesPort) == [.sendFilesNet(open)])
        // The automatic mount of the new READY is not revealed (the user did not click this time).
        let mount = mountGen(p.filesInfo(ready))!
        #expect(p.mountFinished(generation: mount, localPort: proxyPort, path: volume, identity: ourVolume).isEmpty)
    }

    @Test func tabletStandbyWhileMountedReopensWhenTheUserStillWantsTheVolume() {
        var p = mounted()
        let out = p.filesInfo(.standby)
        #expect(out.prefix(2) == [.unmount(localPort: proxyPort), .stopProxy(localPort: proxyPort)])
        #expect(proxyGen(out) != nil)
        #expect(!out.contains(.sendFilesNet(.close)))  // the tablet closed by itself
    }

    @Test func shutdownStopsTheProxyLikeASessionEnd() {
        var p = mounted()
        #expect(p.shutdown() == [.unmount(localPort: proxyPort), .stopProxy(localPort: proxyPort)])
        #expect(p.filesInfo(ready).isEmpty)
    }

    @Test func aStaleProxyIsStoppedAgain() {
        var p = wifi()
        _ = p.filesInfo(.standby)
        let gen = proxyGen(p.openRequested())!
        #expect(p.sessionEnded().isEmpty)  // nothing was up yet
        #expect(p.proxyFinished(generation: gen, localPort: proxyPort, filesPort: filesPort)
            == [.stopProxy(localPort: proxyPort)])
        #expect(p.proxyFinished(generation: gen, localPort: nil, filesPort: 0).isEmpty)
        #expect(p.forwardedLocalPort == nil)
    }

    @Test func aProxyThatFinishesForAnOlderRequestDoesNotReplaceTheCurrentOne() {
        var p = wifi()
        _ = p.filesInfo(.standby)
        let first = proxyGen(p.openRequested())!
        _ = p.filesInfo(.off)  // the open attempt is abandoned
        _ = p.filesInfo(.standby)
        #expect(p.proxyFinished(generation: first, localPort: proxyPort, filesPort: filesPort)
            == [.stopProxy(localPort: proxyPort)])
    }

    // MARK: Restart, eject

    @Test func aServerRestartRemountsWithTheNewTokenThroughTheSameProxy() {
        var p = mounted()
        // New token and even a new tablet port: the proxy and its address stay, the volume is mounted again.
        #expect(p.filesInfo(restarted) == [.unmount(localPort: proxyPort)])
        #expect(p.forwardedLocalPort == proxyPort)
        let remount = p.unmountFinished(localPort: proxyPort, detached: [volume], stillMounted: [])
        guard case .mount(let local, let secret, let gen, _)? = remount.first else { Issue.record("no remount"); return }
        #expect(local == proxyPort)
        #expect(secret.value == newToken)
        #expect(p.mountFinished(generation: gen, localPort: proxyPort, path: volume, identity: ourVolume).isEmpty)
        #expect(p.remountsAfterRestart)
    }

    @Test func aFinderEjectClosesTheFileConnectionsAndStopsTheProxy() {
        var p = mounted()
        #expect(p.takeQueuedActions().isEmpty)
        let ejected = p.volumeUnmounted(path: volume, mountedNow: [])
        #expect(ejected)
        #expect(!p.remountsAfterRestart)
        #expect(p.watchedPaths.isEmpty)
        #expect(p.takeQueuedActions() == [.sendFilesNet(.close), .unmount(localPort: proxyPort),
                                          .stopProxy(localPort: proxyPort)])
        #expect(p.takeQueuedActions().isEmpty)
        #expect(p.forwardedLocalPort == nil)
        // The tablet answers CLOSE with STANDBY; nothing opens by itself any more.
        #expect(p.filesInfo(.standby).isEmpty)
        #expect(p.menu == .ready(lastMountFailed: false))
    }

    @Test func anEjectThatOnlyShowsAtTheRestartAlsoClosesTheConnections() {
        var p = mounted()
        _ = p.filesInfo(restarted)
        let out = p.unmountFinished(localPort: proxyPort, detached: [], stillMounted: [])  // already gone: ejected
        #expect(out.first == .sendFilesNet(.close))
        #expect(out.contains(.stopProxy(localPort: proxyPort)))
        #expect(!out.contains { if case .mount = $0 { true } else { false } })
        #expect(!p.remountsAfterRestart)
    }

    @Test func anUnrelatedUnmountDoesNothingOnWifi() {
        var p = mounted()
        let other = p.volumeUnmounted(path: "/Volumes/Other", mountedNow: [])
        #expect(!other)
        #expect(p.takeQueuedActions().isEmpty)
        #expect(p.forwardedLocalPort == proxyPort)
    }

    // MARK: USB device events do not touch the Wi-Fi proxy

    @Test func theCableComingAndGoingLeavesTheProxyAlone() {
        var p = mounted()
        #expect(p.usbDevice(present: false).isEmpty)
        #expect(p.forwardedLocalPort == proxyPort)
        #expect(p.menu == .ready(lastMountFailed: false))
        #expect(p.usbDevice(present: true).isEmpty)
        #expect(p.forwardedLocalPort == proxyPort)
    }

    // MARK: Leftovers

    @Test func aBusyWifiVolumeIsForcedOutOnceItsTokenIsKnownDead() {
        var p = mounted()
        _ = p.sessionEnded()
        _ = p.unmountFinished(localPort: proxyPort, detached: [], stillMounted: [volume])  // busy: stays mounted
        #expect(p.leftoverPaths == [volume])
        _ = p.sessionStarted(transport: .network, capable: true, netCapable: true)
        _ = p.filesInfo(.standby)
        // A READY with another token (after the user opened again) makes the old volume dead.
        let gen = proxyGen(p.openRequested())!
        _ = p.proxyFinished(generation: gen, localPort: proxyPort, filesPort: filesPort)
        let out = p.filesInfo(restarted)
        #expect(out == [.forceUnmount(path: volume, localPort: proxyPort, identity: ourVolume)])  // the mount waits
        let mount = p.forceUnmountFinished(path: volume, localPort: proxyPort, gone: true)
        guard case .mount(_, let secret, let mountGen, _)? = mount.first else { Issue.record("no mount"); return }
        #expect(secret.value == newToken)
        #expect(p.mountFinished(generation: mountGen, localPort: proxyPort, path: volume, identity: ourVolume)
            == [.reveal(path: volume)])  // still the user's own mount
    }
}
