import XCTest
@testable import MateBridgeCore

final class BuildInfoTests: XCTestCase {
    private let full: [String: Any] = [
        "CFBundleShortVersionString": "0.1",
        "CFBundleVersion": "20261003121314",
        "MBGitCommit": "65dc662",
        "CFBundleIdentifier": "dev.matebridge.host",
    ]

    func testFullDictionary() {
        let info = BuildInfo(infoDictionary: full)
        XCTAssertEqual(info.version, "0.1")
        XCTAssertEqual(info.build, "20261003121314")
        XCTAssertEqual(info.sha, "65dc662")
    }

    func testDirtyShaIsKept() {
        var dict = full
        dict["MBGitCommit"] = "65dc662-dirty"
        XCTAssertEqual(BuildInfo(infoDictionary: dict).sha, "65dc662-dirty")
    }

    func testEachMissingKeyBecomesUnknown() {
        for key in ["CFBundleShortVersionString", "CFBundleVersion", "MBGitCommit"] {
            var dict = full
            dict.removeValue(forKey: key)
            let info = BuildInfo(infoDictionary: dict)
            XCTAssertEqual(info.version, key == "CFBundleShortVersionString" ? "unknown" : "0.1", key)
            XCTAssertEqual(info.build, key == "CFBundleVersion" ? "unknown" : "20261003121314", key)
            XCTAssertEqual(info.sha, key == "MBGitCommit" ? "unknown" : "65dc662", key)
        }
    }

    func testNoBundle() {
        // `swift run`: no Info.plist, `Bundle.main.infoDictionary` is nil or lacks every key.
        let expected = BuildInfo(version: "unknown", build: "unknown", sha: "unknown")
        XCTAssertEqual(BuildInfo(infoDictionary: nil), expected)
        XCTAssertEqual(BuildInfo(infoDictionary: [:]), expected)
        XCTAssertEqual(BuildInfo(infoDictionary: nil).logFields(os: "Version 27.0"),
                       "version=unknown build=unknown sha=unknown os=Version_27.0")
    }

    func testEmptyNonStringAndPlaceholderValuesBecomeUnknown() {
        let info = BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "  ",
            "CFBundleVersion": "__BUILD__",
            "MBGitCommit": 42,
        ])
        XCTAssertEqual(info, BuildInfo(version: "unknown", build: "unknown", sha: "unknown"))
        XCTAssertEqual(BuildInfo(infoDictionary: ["MBGitCommit": "__GIT_COMMIT__"]).sha, "unknown")
    }

    func testLogFieldsExactFormat() {
        let info = BuildInfo(infoDictionary: full)
        XCTAssertEqual(info.logFields(os: "Version 27.0 (Build 27A123)"),
                       "version=0.1 build=20261003121314 sha=65dc662 os=Version_27.0_(Build_27A123)")
        XCTAssertEqual(info.logFields(os: ""), "version=0.1 build=20261003121314 sha=65dc662 os=unknown")
    }

    func testLogFieldsKeepOneTokenPerField() {
        let info = BuildInfo(version: "0.1 beta", build: "1=2", sha: "abc\tdef")
        let fields = info.logFields(os: "x").split(separator: " ")
        XCTAssertEqual(fields, ["version=0.1_beta", "build=1_2", "sha=abc_def", "os=x"])
    }

    func testMenuTitle() {
        XCTAssertEqual(BuildInfo(infoDictionary: full).menuTitle, "Sürüm 0.1 (65dc662, 20261003121314)")
        XCTAssertEqual(BuildInfo(infoDictionary: nil).menuTitle, "Sürüm unknown (unknown, unknown)")
    }
}
