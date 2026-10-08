import CoreVideo
import Foundation
import MateBridgeCore
import Metal

/// The compiled packer kernel (`PackedChromaKernel`), shared by every packer: compiled once per process, on first use.
final class PackedChromaKernels: @unchecked Sendable {
    let shared: MetalShared
    let pack: MTLComputePipelineState

    static let shared: Result<PackedChromaKernels, MetalSetupError> = {
        do throws(MetalSetupError) { return .success(try PackedChromaKernels()) } catch { return .failure(error) }
    }()

    private init() throws(MetalSetupError) {
        // Safe math (in `MetalShared.pipelines`) keeps division and rounding close to the CPU reference
        // (`AVC444v2.planes444`).
        let base = try MetalShared.shared.get()
        shared = base
        pack = try base.pipelines(source: PackedChromaKernel.metalSource, functions: [PackedChromaKernel.function])[0]
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
    private let support: MetalPassSupport

    /// Throws when Metal or the kernel is unavailable, the size cannot be packed, or the cache / pool fail.
    init(width: Int, height: Int) throws {
        guard AVC444v2.isValid(width: width, height: height) else {
            throw MetalSetupError.compile("invalid_size_\(width)x\(height)")
        }
        let kernels = try PackedChromaKernels.shared.get()
        self.kernels = kernels
        self.width = width
        self.height = height
        support = try MetalPassSupport(shared: kernels.shared, width: width, height: height, minimumBuffers: 4,
                                       allocationThreshold: Self.poolAllocationThreshold)
    }

    func pack(_ src: CVPixelBuffer) -> Result {
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(src) == width, CVPixelBufferGetHeight(src) == height else { return .passThrough }
        guard let main = support.makeOutput(), let aux = support.makeOutput() else { return .failed("pool") }
        let cw = width / 2, ch = height / 2
        // The CVMetalTexture wrappers must outlive the command buffer: they are locals until after the wait.
        guard let srcTex = support.texture(src, plane: 0, .bgra8Unorm, width, height),
              let mY = support.texture(main, plane: 0, .r8Unorm, width, height),
              let mC = support.texture(main, plane: 1, .rg8Unorm, cw, ch),
              let aY = support.texture(aux, plane: 0, .r8Unorm, width, height),
              let aC = support.texture(aux, plane: 1, .rg8Unorm, cw, ch) else { return .failed("texture") }
        let (timing, failure) = support.run(label: "pack444", keepAlive: [srcTex, mY, mC, aY, aC]) { e in
            e.setComputePipelineState(kernels.pack)
            e.setTexture(srcTex.texture, index: 0)
            e.setTexture(mY.texture, index: 1)
            e.setTexture(mC.texture, index: 2)
            e.setTexture(aY.texture, index: 3)
            e.setTexture(aC.texture, index: 4)
            e.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1),
                              threadsPerThreadgroup: MetalPassSupport.threadgroup(kernels.pack))
        }
        guard let timing else { return .failed(failure ?? "gpu") }
        Self.tag(main)
        Self.tag(aux)
        return .packed(main: main, aux: aux, wallUs: timing.wallUs, gpuUs: timing.gpuUs)
    }

    /// Session colour tags (no VideoToolbox colour conversion, T-113) and top-left chroma siting (`pick`).
    static func tag(_ pb: CVPixelBuffer) {
        MetalPassSupport.tag(pb, chromaLocation: kCVImageBufferChromaLocation_TopLeft)
    }
}
