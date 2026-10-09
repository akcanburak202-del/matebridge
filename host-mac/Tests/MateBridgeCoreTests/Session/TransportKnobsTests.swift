import XCTest
@testable import MateBridgeCore

/// T-088: transport classification and log names, bitrate source, service class and send-queue knobs.
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

    // MARK: Bitrate source

    func testRemovedWifiBitrateKnobIsInert() {
        // T-302: `MATEBRIDGE_WIFI_BITRATE_KBPS` no longer changes anything.
        let prefs120 = StreamPrefs(fps: 120, scalePermille: 1000)
        let plain = VideoSettings.tabletDefault.applyingExperimentKnobs([:])
        let withKnob = VideoSettings.tabletDefault.applyingExperimentKnobs(["MATEBRIDGE_WIFI_BITRATE_KBPS": "25000"])
        XCTAssertEqual(withKnob, plain)
        XCTAssertEqual(withKnob.applying(prefs120).bitrateKbps, 60_000)
        XCTAssertEqual(withKnob.applying(prefs120).bitrateSource, "prefs")
    }

    func testEnvBitrateSource() {
        let s = VideoSettings.tabletDefault.applyingExperimentKnobs(["MATEBRIDGE_BITRATE_KBPS": "90000"])
        XCTAssertEqual(s.applying(StreamPrefs(fps: 120, scalePermille: 1000)).bitrateKbps, 90_000)
        XCTAssertEqual(s.bitrateSource, "env")
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

    // MARK: Explicit IP TOS (T-326)

    func testIpTosDefaultsToOff() {
        for d in [nil, "", "  ", "off", "OFF", " Off "] { XCTAssertEqual(IpTosKnob.parse(d), .off, "\(String(describing: d))") }
        XCTAssertEqual(IpTosKnob.parse([:]), .off)
        XCTAssertEqual(IpTosKnob.parse(["OTHER": "ef"]), .off)
        XCTAssertTrue(IpTosKnob.off.isOff)
        XCTAssertNil(IpTosKnob.off.warning)
        XCTAssertEqual(IpTosKnob.off.logFields, "ip_tos=off")
    }

    func testIpTosPresets() {
        let ef = IpTosKnob.parse(["MATEBRIDGE_IP_TOS": "ef"])
        XCTAssertEqual(ef.video, 0x88)
        XCTAssertEqual(ef.control, 0xB8)
        XCTAssertEqual(ef.logFields, "ip_tos=video=0x88,control=0xb8")
        let cs6 = IpTosKnob.parse(" CS6 ")
        XCTAssertEqual(cs6.video, 0x88)
        XCTAssertEqual(cs6.control, 0xC0)
        XCTAssertEqual(cs6.logFields, "ip_tos=video=0x88,control=0xc0")
        XCTAssertNil(ef.warning)
        XCTAssertFalse(ef.isOff)
    }

    func testIpTosExplicitValues() {
        let k = IpTosKnob.parse("video=0x88,control=0xb8")
        XCTAssertEqual(k, IpTosKnob(video: 0x88, control: 0xB8))
        // Decimal, any order, spaces, upper case; the two ECN bits are cleared.
        XCTAssertEqual(IpTosKnob.parse("Control=184, VIDEO=0X8B"), IpTosKnob(video: 0x88, control: 0xB8))
        XCTAssertEqual(IpTosKnob.parse("control=0xff"), IpTosKnob(video: nil, control: 0xFC))
        XCTAssertEqual(IpTosKnob.parse("control=255").logFields, "ip_tos=control=0xfc")
        // Either listener may be left out; 0 is a value (DSCP 0 explicitly), not "unset".
        XCTAssertEqual(IpTosKnob.parse("video=0x88"), IpTosKnob(video: 0x88, control: nil))
        XCTAssertEqual(IpTosKnob.parse("video=0,control=3"), IpTosKnob(video: 0, control: 0))
        XCTAssertEqual(IpTosKnob.parse("video=0").logFields, "ip_tos=video=0x00")
        XCTAssertEqual(IpTosKnob.parse("video=0x88,control=0xb8").logFields, "ip_tos=video=0x88,control=0xb8")
    }

    func testIpTosInvalidFallsBackToOffWithWarning() {
        for bad in ["ef,cs6", "af41", "video=256", "control=0x100", "video=-1", "video=", "video", "=5", "control=zz",
                    "video=1,video=2", "audio=0x88", "video=0x88,", ",", "0x88"] {
            let k = IpTosKnob.parse(bad)
            XCTAssertTrue(k.isOff, bad)
            XCTAssertNotNil(k.warning, bad)
            XCTAssertTrue(k.logFields.hasPrefix("ip_tos=off ip_tos_invalid="), bad)
        }
        XCTAssertEqual(IpTosKnob.parse("video=256").logFields, "ip_tos=off ip_tos_invalid=video=256")
        // The echoed text is log-safe: odd characters become `_`, and it is cut.
        XCTAssertEqual(IpTosKnob.parse("a b;c\\td").warning, "a_b_c_td")
        XCTAssertEqual(IpTosKnob.parse(String(repeating: "x", count: 100)).warning?.count, 40)
    }

    // MARK: Send-queue log

    func testSendQueueLogKnob() {
        XCTAssertFalse(SendQueueLogKnob.isEnabled([:]))
        XCTAssertFalse(SendQueueLogKnob.isEnabled(["MATEBRIDGE_SENDQ_LOG": "0", "MATEBRIDGE_LAT_TRACE": "yes"]))
        XCTAssertTrue(SendQueueLogKnob.isEnabled(["MATEBRIDGE_SENDQ_LOG": "1"]))
        XCTAssertTrue(SendQueueLogKnob.isEnabled(["MATEBRIDGE_LAT_TRACE": "1"]))
    }
}
