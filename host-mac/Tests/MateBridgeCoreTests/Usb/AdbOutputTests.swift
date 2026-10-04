import XCTest
@testable import MateBridgeCore

final class AdbOutputTests: XCTestCase {
    func testDevicesIgnoreBannersAndHeader() {
        let text = "* daemon not running; starting now at tcp:5037\n* daemon started successfully\nList of devices attached\nABC123\tdevice\nXYZ\tunauthorized\n\n"
        XCTAssertEqual(AdbOutput.parseDevices(text), [AdbDevice(serial: "ABC123", state: "device"),
                                                      AdbDevice(serial: "XYZ", state: "unauthorized")])
        XCTAssertTrue(AdbOutput.parseDevices("List of devices attached\n\n").isEmpty)
    }

    func testReverseListParsesForwardedPorts() {
        let text = "host-19 tcp:47001 tcp:47001\nhost-19 tcp:47002 tcp:47002\nhost-19 tcp:8080 tcp:9090\nlocalabstract:x tcp:1\n"
        XCTAssertEqual(AdbOutput.parseReverseList(text), [47001, 47002])
        XCTAssertEqual(AdbOutput.parseReverseList("tcp:47001 tcp:47001"), [47001])
        XCTAssertTrue(AdbOutput.parseReverseList("").isEmpty)
    }

    func testForwardPortSkipsBannersAndRejectsGarbage() {
        XCTAssertEqual(AdbOutput.parseForwardPort("54321\n"), 54321)
        XCTAssertEqual(AdbOutput.parseForwardPort("* daemon not running; starting now at tcp:5037\n"
                                                  + "* daemon started successfully\n53000\n"), 53000)
        XCTAssertNil(AdbOutput.parseForwardPort(""))
        XCTAssertNil(AdbOutput.parseForwardPort("0\n"))
        XCTAssertNil(AdbOutput.parseForwardPort("70000\n"))
        XCTAssertNil(AdbOutput.parseForwardPort("error: cannot bind listener: Address already in use\n"))
    }

    func testForwardListFiltersBySerialAndTcp() {
        let text = "* daemon started successfully\n"
            + "ABC123 tcp:47010 tcp:47010\n"
            + "ABC123 tcp:53000 tcp:47012\n"
            + "OTHER tcp:47011 tcp:47010\n"
            + "ABC123 localabstract:foo tcp:1\n"
            + "garbage\n"
        XCTAssertEqual(AdbOutput.parseForwardList(text, serial: "ABC123"), [47010, 53000])
        XCTAssertEqual(AdbOutput.parseForwardList(text, serial: "OTHER"), [47011])
        XCTAssertEqual(AdbOutput.parseForwardList("", serial: "ABC123"), [])
    }

    func testSelectDevicePrefersPhysicalReadyDevice() {
        let devices = [AdbDevice(serial: "emulator-5554", state: "device"),
                       AdbDevice(serial: "OFF", state: "offline"),
                       AdbDevice(serial: "REAL", state: "device")]
        XCTAssertEqual(AdbOutput.selectDevice(devices)?.serial, "REAL")
        XCTAssertEqual(AdbOutput.selectDevice([devices[0]])?.serial, "emulator-5554")
        XCTAssertNil(AdbOutput.selectDevice([devices[1]]))
    }

    func testNetworkSerialsAreRecognized() {
        for serial in ["192.168.1.105:5555", "[fe80::1%en0]:5555", "tablet.local:5555",
                       "adb-ABC123-xYz9._adb-tls-connect._tcp", "adb-ABC123-xYz9._adb-tls-connect._tcp.",
                       "adb-ABC123._adb._tcp"] {
            XCTAssertTrue(AdbDevice(serial: serial, state: "device").isNetwork, serial)
        }
        for serial in ["ABC123DEF456", "emulator-5554", "R5CT-1234_x"] {
            XCTAssertFalse(AdbDevice(serial: serial, state: "device").isNetwork, serial)
        }
    }

    func testSelectDeviceSkipsNetworkAdb() {
        let wifi = AdbDevice(serial: "192.168.1.105:5555", state: "device")
        let mdns = AdbDevice(serial: "adb-ABC123-xYz9._adb-tls-connect._tcp", state: "device")
        let usb = AdbDevice(serial: "ABC123", state: "device")
        let emulator = AdbDevice(serial: "emulator-5554", state: "device")
        XCTAssertNil(AdbOutput.selectDevice([wifi]))
        XCTAssertNil(AdbOutput.selectDevice([wifi, mdns]))
        XCTAssertEqual(AdbOutput.selectDevice([wifi, usb]), usb)
        XCTAssertEqual(AdbOutput.selectDevice([mdns, usb, wifi]), usb)
        XCTAssertEqual(AdbOutput.selectDevice([usb, wifi]), usb)
        XCTAssertEqual(AdbOutput.selectDevice([wifi, emulator]), emulator)
        XCTAssertEqual(AdbOutput.selectDevice([wifi, emulator, usb]), usb)
        XCTAssertNil(AdbOutput.selectDevice([AdbDevice(serial: "ABC123", state: "unauthorized"), wifi]))
    }

    func testSelectDeviceFromRealDevicesOutputWithWirelessAdb() {
        let text = "List of devices attached\n192.168.1.105:5555\tdevice\n"
            + "adb-ABC123-xYz9._adb-tls-connect._tcp\tdevice\n"
        let devices = AdbOutput.parseDevices(text)
        XCTAssertEqual(devices.map(\.serial), ["192.168.1.105:5555", "adb-ABC123-xYz9._adb-tls-connect._tcp"])
        XCTAssertNil(AdbOutput.selectDevice(devices))
        XCTAssertEqual(AdbOutput.selectDevice(AdbOutput.parseDevices(text + "ABC123\tdevice\n"))?.serial, "ABC123")
    }

    func testPlannerReportsNoDeviceWhenOnlyNetworkAdb() {
        var planner = UsbTunnelPlanner()
        let snapshot = UsbSnapshot(adbFound: true, serverUp: true,
                                   devices: [AdbDevice(serial: "192.168.1.105:5555", state: "device")])
        let decision = planner.decide(snapshot)
        XCTAssertEqual(decision.state, .noDevice)
        XCTAssertNil(decision.action)
    }

    func testServerLaunchNeverListensOnAllInterfaces() {
        let cmd = AdbServerLaunch.command(adb: "/sdk/platform-tools/adb")
        XCTAssertFalse(cmd.contains("-a"))
        XCTAssertFalse(cmd.contains { $0.hasPrefix("-") && $0.contains("a") && !$0.hasPrefix("--") })
        XCTAssertEqual(cmd.suffix(3), ["/sdk/platform-tools/adb", "nodaemon", "server"])
        XCTAssertTrue(cmd.contains("ADB_MDNS=0") && cmd.contains("ADB_MDNS_AUTO_CONNECT=0"))
    }

    func testLocatorOrder() {
        let c = AdbLocator.candidates(androidHome: "/sdk", home: "/Users/u", path: "/usr/bin:/opt/pt")
        XCTAssertEqual(c.prefix(4), ["/sdk/platform-tools/adb", "/Users/u/Library/Android/sdk/platform-tools/adb",
                                     "/usr/bin/adb", "/opt/pt/adb"])
        XCTAssertEqual(AdbLocator.candidates(androidHome: nil, home: "/h", path: nil).first,
                       "/h/Library/Android/sdk/platform-tools/adb")
    }
}
