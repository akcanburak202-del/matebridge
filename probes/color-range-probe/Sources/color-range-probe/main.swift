import ColorRangeProbeCore
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// T-230 colour-range bitstream probe. Encodes a known luma band pattern with an encoder session configured like
// MateBridge's HEVCEncoder (fast profile), then reports the SPS VUI and the luma VideoToolbox decodes back on the Mac.
// No window, no virtual display, no ScreenCaptureKit, no network. Uses the hardware HEVC encoder for a few frames.
//
//   color-range-probe [--only prod,noretag,...] [--frames 3] [--size 2800x1840] [--bitrate-kbps 30000] [--fps 60]
//                     [--out DIR]

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

let opts: ProbeOptions
switch ProbeOptions.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let o): opts = o
case .failure(let e):
    fail("color-range-probe: \(e)\nconfigs: \(ProbeConfig.all.map(\.name).joined(separator: ", "))")
}

// MARK: - Pixel formats and tags

func cvFormat(_ f: YUVFormat) -> OSType {
    f == .full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
}

func fourCC(_ t: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((t >> $0) & 0xFF) }
    return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? String(decoding: bytes, as: UTF8.self) : String(t)
}

// HEVCEncoder.session{Primaries,Transfer,Matrix} (T-113).
let sessionPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2
let sessionTransfer = kCVImageBufferTransferFunction_sRGB
let sessionMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2

/// ScreenCaptureKit's attachments on its sRGB 4:2:0 buffers (EncodeBench.tagLikeScreenCaptureKit, measured T-113).
func tagLikeScreenCaptureKit(_ pb: CVPixelBuffer) {
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                          .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    if let cs = CGColorSpace(name: CGColorSpace.sRGB) {
        CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
    }
}

/// HEVCEncoder.retagForSession: overwrite the three tags (the CGColorSpace attachment stays, as in production).
func retagForSession(_ pb: CVPixelBuffer) {
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, sessionPrimaries, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, sessionTransfer, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, sessionMatrix, .shouldPropagate)
}

func tagSummary(_ pb: CVPixelBuffer) -> String {
    func t(_ k: CFString) -> String { (CVBufferCopyAttachment(pb, k, nil) as? String) ?? "-" }
    let cs = CVBufferCopyAttachment(pb, kCVImageBufferCGColorSpaceKey, nil) != nil ? "+CGColorSpace" : ""
    return "\(t(kCVImageBufferColorPrimariesKey))/\(t(kCVImageBufferTransferFunctionKey))/"
        + "\(t(kCVImageBufferYCbCrMatrixKey))\(cs)"
}

func makeInput(_ c: ProbeConfig) -> CVPixelBuffer {
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, opts.width, opts.height, cvFormat(c.input), attrs as CFDictionary, &pb)
            == kCVReturnSuccess, let pb else { fail("CVPixelBufferCreate failed") }
    CVPixelBufferLockBaseAddress(pb, [])
    Bands.fillLuma(CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self),
                   width: opts.width, height: opts.height, stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
    Bands.fillChroma(CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self),
                     widthBytes: CVPixelBufferGetWidthOfPlane(pb, 1) * 2, height: CVPixelBufferGetHeightOfPlane(pb, 1),
                     stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
    CVPixelBufferUnlockBaseAddress(pb, [])
    switch c.tags {
    case .sckRetagged: tagLikeScreenCaptureKit(pb); retagForSession(pb)
    case .sck: tagLikeScreenCaptureKit(pb)
    case .none: break
    }
    return pb
}

func lumaStats(_ pb: CVImageBuffer) -> [Bands.Stat]? {
    let f = CVPixelBufferGetPixelFormatType(pb)
    guard f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    else { return nil }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    return Bands.measureLuma(CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self),
                             width: CVPixelBufferGetWidthOfPlane(pb, 0), height: CVPixelBufferGetHeightOfPlane(pb, 0),
                             stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
}

// MARK: - Encode (session properties mirror HEVCEncoder.init with the default `.fast` profile)

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CMSampleBuffer] = []
    private var images: [CVImageBuffer] = []
    private(set) var errors: [OSStatus] = []
    func add(_ s: CMSampleBuffer) { lock.lock(); items.append(s); lock.unlock() }
    func add(_ i: CVImageBuffer) { lock.lock(); images.append(i); lock.unlock() }
    func error(_ e: OSStatus) { lock.lock(); errors.append(e); lock.unlock() }
    var samples: [CMSampleBuffer] { lock.lock(); defer { lock.unlock() }; return items }
    var decoded: [CVImageBuffer] { lock.lock(); defer { lock.unlock() }; return images }
}

func encode(_ c: ProbeConfig, input: CVPixelBuffer) -> (samples: [CMSampleBuffer], report: [String]) {
    let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
    var s: VTCompressionSession?
    let st = VTCompressionSessionCreate(
        allocator: nil, width: Int32(opts.width), height: Int32(opts.height), codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &s)
    guard st == noErr, let s else { fail("VTCompressionSessionCreate failed (\(st))") }
    var report: [String] = []
    func set(_ name: String, _ key: CFString, _ value: CFTypeRef) {
        let r = VTSessionSetProperty(s, key: key, value: value)
        if r != noErr { report.append("\(name)=\(r)") }
    }
    let perSecond = opts.bitrateKbps * 1000 / 8 * 2
    set("RealTime", kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
    set("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
    set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, opts.fps as CFNumber)
    set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (opts.bitrateKbps * 1000) as CFNumber)
    set("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits,
        [NSNumber(value: perSecond), NSNumber(value: 1)] as CFArray)
    set("MaxKeyFrameIntervalDuration", kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 300 as CFNumber)
    set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
        kCFBooleanTrue)
    set("ColorPrimaries", kVTCompressionPropertyKey_ColorPrimaries, sessionPrimaries)
    set("TransferFunction", kVTCompressionPropertyKey_TransferFunction, sessionTransfer)
    set("YCbCrMatrix", kVTCompressionPropertyKey_YCbCrMatrix, sessionMatrix)
    VTCompressionSessionPrepareToEncodeFrames(s)

    var hw: CFTypeRef?
    _ = withUnsafeMutablePointer(to: &hw) {
        VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: UnsafeMutableRawPointer($0))
    }
    report.append("hardware=\((hw as? Bool).map { $0 ? "yes" : "no" } ?? "?")")

    let out = Collector()
    for f in 0..<opts.frames {
        let pts = CMTime(value: CMTimeValue(f), timescale: CMTimeScale(opts.fps))
        let props: CFDictionary? = f == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let r = VTCompressionSessionEncodeFrame(
            s, imageBuffer: input, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(opts.fps)), frameProperties: props, infoFlagsOut: nil
        ) { status, _, sample in
            if status != noErr { out.error(status) } else if let sample { out.add(sample) }
        }
        if r != noErr { out.error(r) }
    }
    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(s)
    if !out.errors.isEmpty { report.append("encode_errors=\(out.errors)") }
    return (out.samples, report)
}

func parameterSets(_ fd: CMFormatDescription) -> [[UInt8]] {
    var count = 0
    guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
        parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
    return (0..<count).compactMap { i in
        var p: UnsafePointer<UInt8>?
        var n = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }
}

func sampleBytes(_ s: CMSampleBuffer) -> [UInt8] {
    guard let bb = CMSampleBufferGetDataBuffer(s) else { return [] }
    var out = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(bb))
    _ = out.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    return out
}

// MARK: - Decode

/// Decodes all samples; `format` nil = let the decoder pick its native output format.
func decode(_ samples: [CMSampleBuffer], format: YUVFormat?) -> (images: [CVImageBuffer], error: String?) {
    guard let fd = samples.first.flatMap(CMSampleBufferGetFormatDescription) else { return ([], "no format") }
    var attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    if let format { attrs[kCVPixelBufferPixelFormatTypeKey] = cvFormat(format) }
    var d: VTDecompressionSession?
    let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                          imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                          decompressionSessionOut: &d)
    guard st == noErr, let d else { return ([], "VTDecompressionSessionCreate=\(st)") }
    let out = Collector()
    for s in samples {
        let r = VTDecompressionSessionDecodeFrame(d, sampleBuffer: s, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            if status != noErr { out.error(status) } else if let img { out.add(img) }
        }
        if r != noErr { out.error(r) }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(d)
    VTDecompressionSessionInvalidate(d)
    return (out.decoded, out.errors.isEmpty ? nil : "decode_errors=\(out.errors)")
}

// MARK: - Run

let outDir = opts.outDir ?? (NSHomeDirectory() + "/.cache/matebridge-tools/data/color-probe")
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

print("color-range-probe (T-230): \(opts.width)x\(opts.height), \(opts.frames) frames, \(opts.bitrateKbps) kbps, "
      + "session tags 709/sRGB/709, bands Y=\(Bands.values.map(String.init).joined(separator: ",")) Cb=Cr=128")
print("output: \(outDir)")

let bandHeader = Bands.values.map { "Y\($0)" }.joined(separator: " | ")
var table: [String] = [
    "| config | input | tags | VUI full / prim / trc / matrix | decode out | \(bandHeader) |",
    "|" + String(repeating: "---|", count: 5 + Bands.values.count),
]
var verdicts: [String] = []

for c in opts.configs {
    let input = makeInput(c)
    print("\n== \(c.name): \(c.note)")
    print("  input \(fourCC(CVPixelBufferGetPixelFormatType(input))) tags=\(tagSummary(input))")
    let (samples, report) = encode(c, input: input)
    print("  encoder: \(report.joined(separator: " "))")
    guard let fd = samples.first.flatMap(CMSampleBufferGetFormatDescription) else {
        print("  no encoded output"); continue
    }
    let ext = { (k: CFString) in CMFormatDescriptionGetExtension(fd, extensionKey: k).map { "\($0)" } ?? "-" }
    print("  format ext: FullRangeVideo=\(ext(kCMFormatDescriptionExtension_FullRangeVideo)) "
          + "primaries=\(ext(kCMFormatDescriptionExtension_ColorPrimaries)) "
          + "transfer=\(ext(kCMFormatDescriptionExtension_TransferFunction)) "
          + "matrix=\(ext(kCMFormatDescriptionExtension_YCbCrMatrix))")

    let sets = parameterSets(fd)
    let vui = sets.lazy.compactMap { HEVCSPS.vuiColor(sps: $0) }.first
    let vuiText = vui.map { "\($0.fullRange ? 1 : 0) / \($0.colourPrimaries) / \($0.transferCharacteristics) / "
        + "\($0.matrixCoefficients)\($0.colourDescriptionPresent ? "" : " (no colour desc)")" } ?? "none"
    print("  SPS VUI: video_full_range_flag / colour_primaries / transfer_characteristics / matrix_coeffs = \(vuiText)")

    var stream = AnnexB.parameterSets(sets)
    for s in samples { stream += AnnexB.convert(lengthPrefixed: sampleBytes(s)) ?? [] }
    let path = "\(outDir)/\(c.name).hevc"
    do {
        try Data(stream).write(to: URL(fileURLWithPath: path))
        print("  wrote \(path) (\(stream.count) bytes, \(samples.count) frames)")
    } catch { print("  write failed: \(error)") }

    var coded: [UInt8]?
    for target in [YUVFormat.full, .video, nil] {
        let (images, err) = decode(samples, format: target)
        let label: String
        if let img = images.last {
            label = (target == nil ? "native " : "") + fourCC(CVPixelBufferGetPixelFormatType(img))
        } else { label = target?.rawValue ?? "native" }
        guard let first = images.first, let last = images.last,
              let a = lumaStats(first), let b = lumaStats(last) else {
            print("  decode \(label): \(err ?? "no measurable output")")
            continue
        }
        let firstText = a == b ? "" : "  (keyframe: \(a.map(\.text).joined(separator: ", ")))"
        print("  decode \(label): \(b.map(\.text).joined(separator: ", "))\(firstText)\(err.map { " " + $0 } ?? "")")
        table.append("| \(c.name) | \(c.input.rawValue) | \(c.tags.rawValue) | \(vuiText) | \(label) | "
                     + b.map { "\($0.median)" }.joined(separator: " | ") + " |")
        if let target, target == YUVFormat.matching(vuiFullRange: vui?.fullRange ?? false) {
            coded = b.map(\.median)
        }
    }
    if let coded {
        let v = Verdict.classify(input: c.input, vuiFullRange: vui?.fullRange, coded: coded)
        print("  verdict: \(v)")
        verdicts.append("- \(c.name): \(v)")
    }
}

print("\n" + table.joined(separator: "\n"))
print("\n" + verdicts.joined(separator: "\n"))
