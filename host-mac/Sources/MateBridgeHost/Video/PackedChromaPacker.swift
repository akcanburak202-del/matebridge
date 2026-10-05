import CoreVideo
import Foundation
import MateBridgeCore
import Metal

/// The compiled packer kernel (`PackedChromaKernel`), shared by every packer: compiled once per process, on first use.
final class PackedChromaKernels: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pack: MTLComputePipelineState

    static let shared: Result<PackedChromaKernels, ChromaKernels.SetupError> = {
        do throws(ChromaKernels.SetupError) { return .success(try PackedChromaKernels()) } catch { return .failure(error) }
    }()

    private init() throws(ChromaKernels.SetupError) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw .noDevice }
        guard let queue = device.makeCommandQueue() else { throw .noQueue }
        let options = MTLCompileOptions()
        // Keep division and rounding close to the CPU reference (`AVC444v2.planes444`).
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        do {
            let library = try device.makeLibrary(source: PackedChromaKernel.metalSource, options: options)
            guard let f = library.makeFunction(name: PackedChromaKernel.function) else {
                throw ChromaKernels.SetupError.compile("function_missing")
            }
            pack = try device.makeComputePipelineState(function: f)
        } catch let e as ChromaKernels.SetupError {
            throw e
        } catch {
            throw .compile(String(describing: error).split(separator: "\n").first.map(String.init) ?? "unknown")
        }
        self.device = device
        self.queue = queue
    }
}

/// Decision 0034 (T-258): ScreenCaptureKit `BGRA` -> the AVC444v2 main and auxiliary `420f` pictures in one Metal pass
/// (port of the T-255 probe's `Packer444`, fused kernel, main chroma = `pick`). Both outputs carry the encoder
/// session's colour tags, so VideoToolbox does not colour-convert them (T-113): the auxiliary picture holds raw
/// samples, never a colour conversion's result (T-255 M4 bit-exactness condition).
///
/// Used from one thread at a time (the encoder's owner queue): `pack` waits for its command buffer.
final class PackedChromaPacker: @unchecked Sendable {
    enum Result {
        /// Both pictures, the wall time of the pass and its GPU time.
        case packed(main: CVPixelBuffer, aux: CVPixelBuffer, wallUs: UInt64, gpuUs: UInt64)
        /// Not a `BGRA` buffer of the session size: nothing was packed.
        case passThrough
        case failed(String)
    }

    /// In flight in the encoders (2 + 2), the retained last ones, the pair being packed, slack.
    static let poolAllocationThreshold = 16

    let width: Int
    let height: Int
    private let kernels: PackedChromaKernels
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary

    /// Throws when Metal or the kernel is unavailable, the size cannot be packed, or the cache / pool fail.
    init(width: Int, height: Int) throws {
        guard AVC444v2.isValid(width: width, height: height) else {
            throw ChromaKernels.SetupError.compile("invalid_size_\(width)x\(height)")
        }
        let kernels = try PackedChromaKernels.shared.get()
        self.kernels = kernels
        self.width = width
        self.height = height
        let usage = MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
        var cache: CVMetalTextureCache?
        let cst = CVMetalTextureCacheCreate(nil, nil, kernels.device, [kCVMetalTextureUsage: usage] as CFDictionary, &cache)
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
        let pst = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                          attrs as CFDictionary, &p)
        guard pst == kCVReturnSuccess, let p else { throw ChromaKernels.SetupError.pool(pst) }
        pool = p
        auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: Self.poolAllocationThreshold] as CFDictionary
    }

    func pack(_ src: CVPixelBuffer) -> Result {
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(src) == width, CVPixelBufferGetHeight(src) == height else { return .passThrough }
        guard let main = output(), let aux = output() else { return .failed("pool") }
        let cw = width / 2, ch = height / 2
        // The CVMetalTexture wrappers must outlive the command buffer: they are locals until after the wait.
        guard let srcTex = texture(src, plane: 0, .bgra8Unorm, width, height),
              let mY = texture(main, plane: 0, .r8Unorm, width, height),
              let mC = texture(main, plane: 1, .rg8Unorm, cw, ch),
              let aY = texture(aux, plane: 0, .r8Unorm, width, height),
              let aC = texture(aux, plane: 1, .rg8Unorm, cw, ch) else { return .failed("texture") }
        let start = DispatchTime.now().uptimeNanoseconds
        guard let cb = kernels.queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else {
            return .failed("command_buffer")
        }
        e.setComputePipelineState(kernels.pack)
        e.setTexture(srcTex.texture, index: 0)
        e.setTexture(mY.texture, index: 1)
        e.setTexture(mC.texture, index: 2)
        e.setTexture(aY.texture, index: 3)
        e.setTexture(aC.texture, index: 4)
        let w = kernels.pack.threadExecutionWidth
        e.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: w, height: max(1, kernels.pack.maxTotalThreadsPerThreadgroup / w),
                                                         depth: 1))
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime((srcTex, mY, mC, aY, aC)) {}
        CVMetalTextureCacheFlush(textureCache, 0)
        guard cb.status == .completed else { return .failed("gpu_status_\(cb.status.rawValue)") }
        let wallUs = (DispatchTime.now().uptimeNanoseconds - start) / 1000
        let gpu = cb.gpuEndTime - cb.gpuStartTime
        let gpuUs = gpu.isFinite && gpu > 0 ? UInt64(gpu * 1_000_000) : 0
        Self.tag(main)
        Self.tag(aux)
        return .packed(main: main, aux: aux, wallUs: wallUs, gpuUs: gpuUs)
    }

    /// Session colour tags (no VideoToolbox colour conversion, T-113) and top-left chroma siting (`pick`).
    static func tag(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, HEVCEncoder.sessionPrimaries, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, HEVCEncoder.sessionTransfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, HEVCEncoder.sessionMatrix, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_TopLeft,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_TopLeft,
                              .shouldPropagate)
    }

    private func output() -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let st = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxAttributes, &made)
        return st == kCVReturnSuccess ? made : nil
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
}
