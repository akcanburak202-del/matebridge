import AppKit
import CoreGraphics
import Foundation
import ObjectiveC
import ScreenCaptureKit
import VideoToolbox

// Read-only reports. Nothing here creates a display, a window, a capture or a compression session.

enum Inspect {
    /// Selectors of the CGVirtualDisplay* classes that matter for HDR (runtime metadata only, no instances).
    static func runtime() {
        print("== CGVirtualDisplay runtime (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        for name in ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"] {
            guard let cls: AnyClass = objc_getClass(name) as? AnyClass else { print("  \(name): NOT FOUND"); continue }
            var n: UInt32 = 0
            var sels: [String] = []
            if let ms = class_copyMethodList(cls, &n) {
                for i in 0..<Int(n) { sels.append(NSStringFromSelector(method_getName(ms[i]))) }
                free(ms)
            }
            let relevant = sels.filter {
                let l = $0.lowercased()
                return l.contains("transfer") || l.contains("eotf") || l.contains("reference") || l.contains("primary")
                    || l.contains("whitepoint") || l.contains("displayinfo") || l.contains("hdr")
            }.sorted()
            print("  \(name): \(relevant.isEmpty ? "(no HDR-related selectors)" : relevant.joined(separator: " "))")
        }
        print("  transferFunction initializer: \(HDRVirtualDisplay.hasTransferFunctionInit ? "present" : "absent")")
    }

    /// One line per screen: EDR headroom and colour space (what games read).
    static func screens(only id: CGDirectDisplayID? = nil) {
        for s in NSScreen.screens {
            let sid = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            if let id, id != sid { continue }
            print(screenLine(s, id: sid))
        }
        if let id, !NSScreen.screens.contains(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
            print("  display \(id): not (yet) an NSScreen; CG view: \(cgLine(id))")
        }
    }

    static func screenLine(_ s: NSScreen, id: CGDirectDisplayID) -> String {
        "  screen id=\(id) \"\(s.localizedName)\" maxPotentialEDR=\(s.maximumPotentialExtendedDynamicRangeColorComponentValue) "
            + "maxEDR=\(s.maximumExtendedDynamicRangeColorComponentValue) "
            + "maxReferenceEDR=\(s.maximumReferenceExtendedDynamicRangeColorComponentValue) "
            + "nsColorSpace=\(s.colorSpace?.localizedName ?? "nil") depth=\(s.depth.rawValue) | \(cgLine(id))"
    }

    static func cgLine(_ id: CGDirectDisplayID) -> String {
        let cs = CGDisplayCopyColorSpace(id)
        var line = "cgColorSpace=\(cs.name as String? ?? "unnamed") wide=\(cs.isWideGamutRGB) hdr=\(cs.isHDR())"
        if let m = CGDisplayCopyDisplayMode(id) {
            line += " mode=\(m.pixelWidth)x\(m.pixelHeight)@\(Int(m.refreshRate.rounded()))"
        }
        return line
    }

    static func encoder() {
        print("== VideoToolbox HEVC 2800x1840 (capability query, no session)")
        for (label, spec) in [("default", nil), ("LLRC", [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true])]
            as [(String, [CFString: Any]?)] {
            var id: CFString?
            var props: CFDictionary?
            let st = VTCopySupportedPropertyDictionaryForEncoder(
                width: 2800, height: 1840, codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary?,
                encoderIDOut: &id, supportedPropertiesOut: &props)
            let d = props as? [String: Any] ?? [:]
            var profiles = "?"
            if let pl = d[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any],
               let list = pl[kVTPropertySupportedValueListKey as String] as? [String] {
                profiles = list.joined(separator: ",")
            }
            let hdrKeys = [kVTCompressionPropertyKey_MasteringDisplayColorVolume, kVTCompressionPropertyKey_ContentLightLevelInfo,
                           kVTCompressionPropertyKey_HDRMetadataInsertionMode]
                .map { "\($0)=\(d[$0 as String] != nil ? "yes" : "no")" }.joined(separator: " ")
            print("  [\(label)] status=\(st) id=\(id as String? ?? "nil") profiles=\(profiles) \(hdrKeys)")
        }
    }

    static func capturePresets() {
        print("== ScreenCaptureKit HDR presets (configuration objects only)")
        for (name, p) in [("hdrStreamLocal", SCStreamConfiguration.Preset.captureHDRStreamLocalDisplay),
                          ("hdrStreamCanonical", .captureHDRStreamCanonicalDisplay),
                          ("hdrRecordingSDRHDR10", .captureHDRRecordingPreservedSDRHDR10)] {
            let c = SCStreamConfiguration(preset: p)
            print("  \(name): pixelFormat=\(fourCC(c.pixelFormat)) colorSpace=\(c.colorSpaceName) "
                  + "matrix=\(c.colorMatrix) dynamicRange=\(c.captureDynamicRange.rawValue)")
        }
    }
}

func fourCC(_ v: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
    return String(bytes: bytes, encoding: .ascii) ?? String(v)
}
