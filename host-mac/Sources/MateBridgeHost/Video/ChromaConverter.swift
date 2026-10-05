import CoreVideo
import Foundation
import MateBridgeCore
import Metal

/// The compiled T-235 kernels (`SharpYUVKernel`), shared by every converter: compiled once per process, on first use.
final class ChromaKernels: @unchecked Sendable {
    enum SetupError: Error, CustomStringConvertible {
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

    let device: MTLDevice
    let queue: MTLCommandQueue
    let chroma: MTLComputePipelineState
    let luma: MTLComputePipelineState
    /// `SharpYUV.eotfTable`, read by `sharp_luma` (buffer 1).
    let eotfTable: MTLBuffer

    /// The process-wide kernels, or why they could not be set up (the result is kept: no retry per pipeline).
    static let shared: Result<ChromaKernels, SetupError> = {
        do throws(SetupError) { return .success(try ChromaKernels()) } catch { return .failure(error) }
    }()

    private init() throws(SetupError) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw .noDevice }
        guard let queue = device.makeCommandQueue() else { throw .noQueue }
        let options = MTLCompileOptions()
        // Keep division and rounding close to the CPU reference (`SharpYUV`).
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        do {
            let library = try device.makeLibrary(source: SharpYUVKernel.metalSource, options: options)
            guard let c = library.makeFunction(name: SharpYUVKernel.chromaFunction),
                  let l = library.makeFunction(name: SharpYUVKernel.lumaFunction) else {
                throw SetupError.compile("function_missing")
            }
            chroma = try device.makeComputePipelineState(function: c)
            luma = try device.makeComputePipelineState(function: l)
        } catch let e as SetupError {
            throw e
        } catch {
            throw .compile(String(describing: error).split(separator: "\n").first.map(String.init) ?? "unknown")
        }
        self.device = device
        self.queue = queue
        guard let table = SharpYUV.eotfTable.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
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
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary

    /// Throws when Metal or the kernels are unavailable, or the texture cache / pool cannot be created.
    init(width: Int, height: Int, upsample: SharpYUV.Upsample) throws {
        let kernels = try ChromaKernels.shared.get()
        self.kernels = kernels
        self.width = width
        self.height = height
        lumaMode = SharpYUVKernel.lumaMode(upsample)

        let usage = MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
        var cache: CVMetalTextureCache?
        let cst = CVMetalTextureCacheCreate(nil, nil, kernels.device,
                                            [kCVMetalTextureUsage: usage] as CFDictionary, &cache)
        guard cst == kCVReturnSuccess, let cache else { throw ChromaKernels.SetupError.textureCache(cst) }
        textureCache = cache

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        let pst = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                          attrs as CFDictionary, &p)
        guard pst == kCVReturnSuccess, let p else { throw ChromaKernels.SetupError.pool(pst) }
        pool = p
        auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: Self.poolAllocationThreshold] as CFDictionary
    }

    func convert(_ src: CVPixelBuffer) -> Result {
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(src) == width, CVPixelBufferGetHeight(src) == height else { return .passThrough }
        var made: CVPixelBuffer?
        let st = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxAttributes, &made)
        guard st == kCVReturnSuccess, let out = made else { return .failed("pool_\(st)") }
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        // The CVMetalTexture wrappers must outlive the command buffer: they are locals until after the wait.
        guard let srcTex = texture(src, plane: 0, .bgra8Unorm, width, height),
              let yTex = texture(out, plane: 0, .r8Unorm, width, height),
              let cTex = texture(out, plane: 1, .rg8Unorm, cw, ch) else { return .failed("texture") }
        let start = DispatchTime.now().uptimeNanoseconds
        guard let cb = kernels.queue.makeCommandBuffer() else { return .failed("command_buffer") }
        // Two encoders: the luma pass reads the chroma the first pass wrote.
        guard let e1 = cb.makeComputeCommandEncoder() else { return .failed("encoder") }
        e1.setComputePipelineState(kernels.chroma)
        e1.setTexture(srcTex.texture, index: 0)
        e1.setTexture(cTex.texture, index: 1)
        e1.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1),
                           threadsPerThreadgroup: Self.threadgroup(kernels.chroma))
        e1.endEncoding()
        guard let e2 = cb.makeComputeCommandEncoder() else { return .failed("encoder") }
        var mode = lumaMode
        e2.setComputePipelineState(kernels.luma)
        e2.setTexture(srcTex.texture, index: 0)
        e2.setTexture(cTex.texture, index: 1)
        e2.setTexture(yTex.texture, index: 2)
        e2.setBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)
        e2.setBuffer(kernels.eotfTable, offset: 0, index: 1)
        e2.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                           threadsPerThreadgroup: Self.threadgroup(kernels.luma))
        e2.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime((srcTex, yTex, cTex)) {}
        CVMetalTextureCacheFlush(textureCache, 0)
        guard cb.status == .completed else { return .failed("gpu_status_\(cb.status.rawValue)") }
        let wallUs = (DispatchTime.now().uptimeNanoseconds - start) / 1000
        let gpu = cb.gpuEndTime - cb.gpuStartTime
        let gpuUs = gpu.isFinite && gpu > 0 ? UInt64(gpu * 1_000_000) : 0
        Self.tag(out)
        return .converted(out, wallUs: wallUs, gpuUs: gpuUs)
    }

    /// Session colour tags (no VideoToolbox colour conversion) and the centred chroma siting of the box mean.
    private static func tag(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, HEVCEncoder.sessionPrimaries, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, HEVCEncoder.sessionTransfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, HEVCEncoder.sessionMatrix, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Center,
                              .shouldPropagate)
    }

    private struct Wrapped {
        let cv: CVMetalTexture
        let texture: MTLTexture
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, _ format: MTLPixelFormat, _ w: Int, _ h: Int) -> Wrapped? {
        var cv: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format, w, h, plane, &cv)
        guard st == kCVReturnSuccess, let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
        return Wrapped(cv: cv, texture: t)
    }

    private static func threadgroup(_ p: MTLComputePipelineState) -> MTLSize {
        let w = p.threadExecutionWidth
        return MTLSize(width: w, height: max(1, p.maxTotalThreadsPerThreadgroup / w), depth: 1)
    }
}
