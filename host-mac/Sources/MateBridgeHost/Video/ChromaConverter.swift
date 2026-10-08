import CoreVideo
import Foundation
import MateBridgeCore
import Metal

/// Why a Metal pass could not be set up (shared by `ChromaKernels`, `PackedChromaKernels`, `MetalPassSupport`).
enum MetalSetupError: Error, CustomStringConvertible {
    case noDevice
    case noQueue
    case noTable
    case compile(String)
    case textureCache(CVReturn)
    case pool(CVReturn)

    var description: String {
        switch self {
        case .noDevice: return "no_metal_device"
        case .noQueue: return "no_command_queue"
        case .noTable: return "no_eotf_table"
        case .compile(let m): return "compile:\(m)"
        case .textureCache(let s): return "texture_cache:\(s)"
        case .pool(let s): return "pool:\(s)"
        }
    }
}

/// T-311 (A8): the device and command queue both Metal passes (`ChromaConverter`, `PackedChromaPacker`) share, and the
/// one way their kernels are compiled. Created once per process, on first use (the result is kept: no retry).
final class MetalShared: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue

    static let shared: Result<MetalShared, MetalSetupError> = {
        do throws(MetalSetupError) { return .success(try MetalShared()) } catch { return .failure(error) }
    }()

    private init() throws(MetalSetupError) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw .noDevice }
        guard let queue = device.makeCommandQueue() else { throw .noQueue }
        self.device = device
        self.queue = queue
    }

    /// Compiles `source` with safe math (division and rounding stay close to the CPU references) and returns the
    /// compute pipeline of each named function.
    func pipelines(source: String, functions: [String]) throws(MetalSetupError) -> [MTLComputePipelineState] {
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        do {
            let library = try device.makeLibrary(source: source, options: options)
            return try functions.map { name in
                guard let f = library.makeFunction(name: name) else { throw MetalSetupError.compile("function_missing") }
                return try device.makeComputePipelineState(function: f)
            }
        } catch let e as MetalSetupError {
            throw e
        } catch {
            throw .compile(String(describing: error).split(separator: "\n").first.map(String.init) ?? "unknown")
        }
    }
}

/// T-311 (A8): what both passes need around their kernels: a texture cache, an output buffer pool, texture wrapping
/// of pixel buffers, one timed synchronous dispatch and the session colour tags. Used from one thread at a time.
final class MetalPassSupport: @unchecked Sendable {
    /// A pixel-buffer plane as a Metal texture; the `CVMetalTexture` must outlive the command buffer.
    struct Wrapped {
        let cv: CVMetalTexture
        let texture: MTLTexture
    }

    /// Timing of one pass: wall (command buffer creation to completion) and GPU (`gpuEndTime - gpuStartTime`).
    struct Timing {
        let wallUs: UInt64
        let gpuUs: UInt64
    }

    let shared: MetalShared
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary

    /// `420f` output pool of `width x height`: `minimumBuffers` kept, at most `allocationThreshold` outstanding.
    init(shared: MetalShared, width: Int, height: Int, minimumBuffers: Int, allocationThreshold: Int) throws {
        self.shared = shared
        let usage = MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
        var cache: CVMetalTextureCache?
        let cst = CVMetalTextureCacheCreate(nil, nil, shared.device, [kCVMetalTextureUsage: usage] as CFDictionary, &cache)
        guard cst == kCVReturnSuccess, let cache else { throw MetalSetupError.textureCache(cst) }
        textureCache = cache
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        let pst = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: minimumBuffers] as CFDictionary,
                                          attrs as CFDictionary, &p)
        guard pst == kCVReturnSuccess, let p else { throw MetalSetupError.pool(pst) }
        pool = p
        auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: allocationThreshold] as CFDictionary
    }

    /// A buffer from the pool, or nil when it is exhausted (the CoreVideo status goes to `status`).
    func makeOutput(status: UnsafeMutablePointer<CVReturn>? = nil) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let st = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxAttributes, &made)
        status?.pointee = st
        return st == kCVReturnSuccess ? made : nil
    }

    func texture(_ pb: CVPixelBuffer, plane: Int, _ format: MTLPixelFormat, _ w: Int, _ h: Int) -> Wrapped? {
        var cv: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format, w, h, plane, &cv)
        guard st == kCVReturnSuccess, let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
        return Wrapped(cv: cv, texture: t)
    }

    /// Runs `encode` in one compute encoder of one command buffer and waits for it (so no frame is in flight on the
    /// GPU afterwards). `keepAlive` holds the texture wrappers until the wait is over. On failure the timing is nil
    /// and the reason is one of the `failed(_)` strings of the passes.
    func run(label: String, keepAlive: [Wrapped], _ encode: (MTLComputeCommandEncoder) -> Void) -> (Timing?, String?) {
        run(label: label, keepAlive: keepAlive, encodeBuffer: { cb in
            guard let e = cb.makeComputeCommandEncoder() else { return false }
            e.label = label
            encode(e)
            e.endEncoding()
            return true
        })
    }

    /// Like `run`, but `encode` makes its own encoders on the command buffer (several, when a later dispatch reads
    /// what an earlier one wrote) and returns false when it could not.
    func run(label: String, keepAlive: [Wrapped], encodeBuffer encode: (MTLCommandBuffer) -> Bool)
        -> (Timing?, String?) {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let cb = shared.queue.makeCommandBuffer() else { return (nil, "command_buffer") }
        cb.label = label
        guard encode(cb) else { return (nil, "encoder") }
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime(keepAlive) {}
        CVMetalTextureCacheFlush(textureCache, 0)
        guard cb.status == .completed else { return (nil, "gpu_status_\(cb.status.rawValue)") }
        let wallUs = (DispatchTime.now().uptimeNanoseconds - start) / 1000
        let gpu = cb.gpuEndTime - cb.gpuStartTime
        return (Timing(wallUs: wallUs, gpuUs: gpu.isFinite && gpu > 0 ? UInt64(gpu * 1_000_000) : 0), nil)
    }

    /// Session colour tags (no VideoToolbox colour conversion, T-113) and the chroma siting of the pass.
    static func tag(_ pb: CVPixelBuffer, chromaLocation: CFString) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, HEVCEncoder.sessionPrimaries, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, HEVCEncoder.sessionTransfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, HEVCEncoder.sessionMatrix, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, chromaLocation, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, chromaLocation, .shouldPropagate)
    }

    static func threadgroup(_ p: MTLComputePipelineState) -> MTLSize {
        let w = p.threadExecutionWidth
        return MTLSize(width: w, height: max(1, p.maxTotalThreadsPerThreadgroup / w), depth: 1)
    }
}

/// The compiled two-pass kernels (`SharpYUVKernel`), shared by every converter: compiled once per process.
final class ChromaKernels: @unchecked Sendable {
    typealias SetupError = MetalSetupError

    let shared: MetalShared
    let chroma: MTLComputePipelineState
    let luma: MTLComputePipelineState
    /// `SharpYUV.eotfTable`, read by `sharp_luma` (buffer 1, `constant` address space).
    let eotfTable: MTLBuffer

    /// The process-wide kernels, or why they could not be set up (the result is kept: no retry per pipeline).
    static let shared: Result<ChromaKernels, MetalSetupError> = {
        do throws(MetalSetupError) { return .success(try ChromaKernels()) } catch { return .failure(error) }
    }()

    private init() throws(MetalSetupError) {
        let base = try MetalShared.shared.get()
        shared = base
        let pipelines = try base.pipelines(source: SharpYUVKernel.metalSource,
                                           functions: [SharpYUVKernel.chromaFunction, SharpYUVKernel.lumaFunction])
        chroma = pipelines[0]
        luma = pipelines[1]
        guard let table = SharpYUV.eotfTable.withUnsafeBytes({
            base.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw .noTable }
        eotfTable = table
    }
}

/// T-235 `MATEBRIDGE_CHROMA=sharp_*`: ScreenCaptureKit `BGRA` -> full-range BT.709 `420f` with the luma adjustment
/// (`SharpYUV`), on the GPU. The output carries the encoder session's colour tags (no VideoToolbox conversion, T-113)
/// and a centred chroma location (the siting the 2x2 box mean has).
///
/// Used from one thread at a time (the encoder's owner queue): `convert` waits for its command buffer, so no frame is
/// in flight on the GPU after it returns. Output buffers come from a pool capped at `poolAllocationThreshold`.
final class ChromaConverter: @unchecked Sendable {
    enum Result {
        /// The converted frame, the wall time of the pass (command buffer creation to completion) and its GPU time.
        case converted(CVPixelBuffer, wallUs: UInt64, gpuUs: UInt64)
        /// Not a `BGRA` buffer of the session size (e.g. a bench's `420f` frame): encode it unchanged.
        case passThrough
        /// The pass could not run (pool exhausted, texture or GPU error): encode the `BGRA` buffer unchanged.
        case failed(String)
    }

    /// Buffers the encoder may hold: in flight (2), the retained last one, one being converted, slack.
    static let poolAllocationThreshold = 8

    let width: Int
    let height: Int
    private let kernels: ChromaKernels
    private let lumaMode: UInt32
    private let support: MetalPassSupport

    /// Throws when Metal or the kernels are unavailable, or the texture cache / pool cannot be created.
    init(width: Int, height: Int, upsample: SharpYUV.Upsample) throws {
        let kernels = try ChromaKernels.shared.get()
        self.kernels = kernels
        self.width = width
        self.height = height
        lumaMode = SharpYUVKernel.lumaMode(upsample)
        support = try MetalPassSupport(shared: kernels.shared, width: width, height: height, minimumBuffers: 3,
                                       allocationThreshold: Self.poolAllocationThreshold)
    }

    func convert(_ src: CVPixelBuffer) -> Result {
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(src) == width, CVPixelBufferGetHeight(src) == height else { return .passThrough }
        var poolStatus: CVReturn = 0
        guard let out = support.makeOutput(status: &poolStatus) else { return .failed("pool_\(poolStatus)") }
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        // The CVMetalTexture wrappers must outlive the command buffer: they are locals until after the wait.
        guard let srcTex = support.texture(src, plane: 0, .bgra8Unorm, width, height),
              let yTex = support.texture(out, plane: 0, .r8Unorm, width, height),
              let cTex = support.texture(out, plane: 1, .rg8Unorm, cw, ch) else { return .failed("texture") }
        var mode = lumaMode
        // Two encoders in one command buffer: the luma pass reads the chroma the first pass wrote.
        let (timing, failure) = support.run(label: "sharp_yuv", keepAlive: [srcTex, yTex, cTex], encodeBuffer: { cb in
            guard let e1 = cb.makeComputeCommandEncoder() else { return false }
            e1.setComputePipelineState(kernels.chroma)
            e1.setTexture(srcTex.texture, index: 0)
            e1.setTexture(cTex.texture, index: 1)
            e1.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1),
                               threadsPerThreadgroup: MetalPassSupport.threadgroup(kernels.chroma))
            e1.endEncoding()
            guard let e2 = cb.makeComputeCommandEncoder() else { return false }
            e2.setComputePipelineState(kernels.luma)
            e2.setTexture(srcTex.texture, index: 0)
            e2.setTexture(cTex.texture, index: 1)
            e2.setTexture(yTex.texture, index: 2)
            e2.setBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)
            e2.setBuffer(kernels.eotfTable, offset: 0, index: 1)
            e2.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                               threadsPerThreadgroup: MetalPassSupport.threadgroup(kernels.luma))
            e2.endEncoding()
            return true
        })
        guard let timing else { return .failed(failure ?? "gpu") }
        // The centred chroma siting the 2x2 box mean has.
        MetalPassSupport.tag(out, chromaLocation: kCVImageBufferChromaLocation_Center)
        return .converted(out, wallUs: timing.wallUs, gpuUs: timing.gpuUs)
    }
}
