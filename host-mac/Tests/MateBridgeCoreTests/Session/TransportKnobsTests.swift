import XCTest
@testable import MateBridgeCore

/// T-088: transport classification and log names, Wi-Fi bitrate precedence, service class and send-queue knobs.
final class TransportKnobsTests: XCTestCase {
    // MARK: Transport

    func testTransportClassificationAndLogName() {
        for loopback in ["127.0.0.1", "::1", "::ffff:127.0.0.1", "localhost", "::1%lo0"] {
            XCTAssertEqual(SessionTransport.classify(peerHost: loopback), .usb, loopback)
        }
        for lan in ["192.168.1.20", "fe80::1%en0", "10.0.0.2", nil] {
            XCTAssertEqual(SessionTransport.classify(peerHost: lan), .network)
        }
        XCTAssertEqual(SessionTransport.usb.logName, "usb")
        XCTAssertEqual(SessionTransport.network.logName, "wifi")
    }

    // MARK: Wi-Fi bitrate

    private let prefs120 = StreamPrefs(fps: 120, scalePermille: 1000)

    private func base(_ env: [String: String], _ transport: SessionTransport) -> VideoSettings {
        VideoSettings.tabletDefault.applyingExperimentKnobs(env).applyingTransportKnobs(env, transport: transport)
    }

    func testWifiBitrateAppliesOnlyToWifiSessions() {
        let env = ["MATEBRIDGE_WIFI_BITRATE_KBPS": "25000"]
        let wifi = base(env, .network)
        XCTAssertEqual(wifi.bitrateKbps, 25_000)
        XCTAssertEqual(wifi.bitrateSource, "wifi_env")
        // It survives STREAM_PREFS (whose default would be 60 Mbps at 120 fps) and a reconnect with stored prefs.
        let applied = wifi.applying(prefs120)
        XCTAssertEqual(applied.bitrateKbps, 25_000)
        XCTAssertEqual(applied.bitrateSource, "wifi_env")
        XCTAssertEqual(applied.streamConfig(configID: 2).bitrateKbps, 25_000)
        let initial = VideoSettings.initialSettings(defaults: wifi, stored: StreamPrefs(fps: 60, scalePermille: 500),
                                                    defaultRefreshHz: 60)
        XCTAssertEqual(initial.bitrateKbps, 25_000)

        // USB: unchanged, the mode default as before.
        let usb = base(env, .usb)
        XCTAssertEqual(usb, VideoSettings.tabletDefault.applyingExperimentKnobs([:]))
        XCTAssertEqual(usb.applying(prefs120).bitrateKbps, 60_000)
        XCTAssertEqual(usb.applying(prefs120).bitrateSource, "prefs")
    }

    func testEnvBitrateWinsOverWifiBitrate() {
        let env = ["MATEBRIDGE_WIFI_BITRATE_KBPS": "25000", "MATEBRIDGE_BITRATE_KBPS": "90000"]
        for transport in [SessionTransport.network, .usb] {
            let s = base(env, transport).applying(prefs120)
            XCTAssertEqual(s.bitrateKbps, 90_000)
            XCTAssertEqual(s.bitrateSource, "env")
        }
    }

    func testInvalidWifiBitrateIsIgnored() {
        for bad in ["", "abc", "4999", "150001", "-1"] {
            let s = base(["MATEBRIDGE_WIFI_BITRATE_KBPS": bad], .network)
            XCTAssertNil(s.bitrateOverrideKbps, bad)
            XCTAssertEqual(s.applying(prefs120).bitrateKbps, 60_000, bad)
            XCTAssertEqual(s.bitrateSource, "prefs", bad)
        }
        // Range edges are accepted.
        XCTAssertEqual(base(["MATEBRIDGE_WIFI_BITRATE_KBPS": "5000"], .network).bitrateKbps, 5_000)
        XCTAssertEqual(base(["MATEBRIDGE_WIFI_BITRATE_KBPS": " 150000 "], .network).bitrateKbps, 150_000)
    }

    func testNoKnobsLeavesSettingsUnchanged() {
        let plain = VideoSettings.tabletDefault.applyingExperimentKnobs([:])
        XCTAssertEqual(plain.applyingTransportKnobs([:], transport: .network), plain)
        XCTAssertEqual(plain.applyingTransportKnobs([:], transport: .usb), plain)
    }

    func testOverrideWithoutRecordedSourceCountsAsEnv() {
        var s = VideoSettings.tabletDefault
        s.bitrateOverrideKbps = 40_000
        XCTAssertEqual(s.bitrateSource, "env")
    }

    // MARK: Service class

    func testServiceClassParsing() {
        // T-124: the default is `signaling`; anything unknown falls back to it, only an explicit `off` turns it off.
        XCTAssertEqual(ServiceClassKnob.defaultValue, .signaling)
        for d in [nil, "", " ", "voice", "1", "bestEffort"] { XCTAssertEqual(ServiceClassKnob.parse(d), .signaling) }
        for off in ["off", "OFF", " Off "] { XCTAssertEqual(ServiceClassKnob.parse(off), .off) }
        XCTAssertEqual(ServiceClassKnob.parse(" Video "), .video)
        XCTAssertEqual(ServiceClassKnob.parse("SIGNALING"), .signaling)
        XCTAssertEqual(ServiceClassKnob.parse([:]), .signaling)
        XCTAssertEqual(ServiceClassKnob.parse(["OTHER": "off"]), .signaling)
        XCTAssertEqual(ServiceClassKnob.parse(["MATEBRIDGE_SERVICE_CLASS": "off"]), .off)
        XCTAssertEqual(ServiceClassKnob.parse(["MATEBRIDGE_SERVICE_CLASS": "video"]), .video)
    }

    func testServiceClassDefaultAndOffClasses() {
        let d = ServiceClassKnob.parse([:])
        XCTAssertEqual(d.videoClass, .interactiveVideo)
        XCTAssertEqual(d.controlClass, .interactiveVoice)
        XCTAssertEqual(d.logFields,
                       "service_class=signaling video_class=interactiveVideo control_class=interactiveVoice")
        let off = ServiceClassKnob.parse(["MATEBRIDGE_SERVICE_CLASS": "off"])
        XCTAssertNil(off.videoClass)
        XCTAssertNil(off.controlClass)
        XCTAssertEqual(off.logFields, "service_class=off")
    }

    func testServiceClassMapping() {
        XCTAssertNil(ServiceClassKnob.off.videoClass)
        XCTAssertNil(ServiceClassKnob.off.controlClass)
        XCTAssertEqual(ServiceClassKnob.video.videoClass, .interactiveVideo)
        XCTAssertEqual(ServiceClassKnob.video.controlClass, .responsiveData)
        XCTAssertEqual(ServiceClassKnob.signaling.videoClass, .interactiveVideo)
        XCTAssertEqual(ServiceClassKnob.signaling.controlClass, .interactiveVoice)
        XCTAssertEqual(ServiceClassKnob.off.logFields, "service_class=off")
        XCTAssertEqual(ServiceClassKnob.signaling.logFields,
                       "service_class=signaling video_class=interactiveVideo control_class=interactiveVoice")
    }

    // MARK: Send-queue log

    func testSendQueueLogKnob() {
        XCTAssertFalse(SendQueueLogKnob.isEnabled([:]))
        XCTAssertFalse(SendQueueLogKnob.isEnabled(["MATEBRIDGE_SENDQ_LOG": "0", "MATEBRIDGE_LAT_TRACE": "yes"]))
        XCTAssertTrue(SendQueueLogKnob.isEnabled(["MATEBRIDGE_SENDQ_LOG": "1"]))
        XCTAssertTrue(SendQueueLogKnob.isEnabled(["MATEBRIDGE_LAT_TRACE": "1"]))
    }
}
