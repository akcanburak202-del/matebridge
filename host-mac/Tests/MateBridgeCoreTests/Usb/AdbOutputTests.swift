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

    func testSelectDevicePrefersPhysicalReadyDevice() {
        let devices = [AdbDevice(serial: "emulator-5554", state: "device"),
                       AdbDevice(serial: "OFF", state: "offline"),
                       AdbDevice(serial: "REAL", state: "device")]
        XCTAssertEqual(AdbOutput.selectDevice(devices)?.serial, "REAL")
        XCTAssertEqual(AdbOutput.selectDevice([devices[0]])?.serial, "emulator-5554")
        XCTAssertNil(AdbOutput.selectDevice([devices[1]]))
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
