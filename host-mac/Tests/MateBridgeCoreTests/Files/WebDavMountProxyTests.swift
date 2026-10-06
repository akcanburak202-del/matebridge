import Testing
@testable import MateBridgeCore

// Decision 0035: the Wi-Fi volume is mounted through the loopback proxy (47012), the USB one through the adb forward
// (47010); `isOurs` tells them apart by port.
@Suite struct WebDavMountProxyTests {
    @Test func theProxyPortIsNotTheForwardPortAndTheMountTableTellsThemApart() {
        #expect(WebDavMount.proxyPreferredLocalPort == 47012)
        #expect(WebDavMount.preferredLocalPort == 47010)
        #expect(WebDavMount.isPreferredProxyPort(47012))
        #expect(!WebDavMount.isPreferredProxyPort(WebDavMount.preferredLocalPort))
        let wifi = WebDavMount.url(localPort: WebDavMount.proxyPreferredLocalPort).absoluteString
        #expect(wifi == "http://127.0.0.1:47012/MatePad/")
        #expect(WebDavMount.isOurs(fsType: "webdav", mountedFrom: wifi, localPort: 47012))
        #expect(!WebDavMount.isOurs(fsType: "webdav", mountedFrom: wifi, localPort: 47010))  // USB volume != Wi-Fi volume
        let usb = WebDavMount.url(localPort: 47010).absoluteString
        #expect(!WebDavMount.isOurs(fsType: "webdav", mountedFrom: usb, localPort: 47012))
    }

    @Test func aWifiVolumeIdentityIsOnlyForceableOnItsOwnProxyPort() {
        let identity = VolumeIdentity(fsid: 1, fsType: "webdav", mountedFrom: "http://127.0.0.1:47012/MatePad/")
        #expect(TabletFilesPlanner.identityMatches(expected: identity, current: identity, localPort: 47012))
        #expect(!TabletFilesPlanner.identityMatches(expected: identity, current: identity, localPort: 47010))
    }
}
