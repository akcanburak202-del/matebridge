import CoreVideo
import Foundation
import Metal
import YUV444Core

/// The colour tags VideoToolbox sessions and buffers carry in the probe: the same as MateBridge's SDR session
/// (`HEVCEncoder.sessionPrimaries/Transfer/Matrix`: BT.709 primaries, sRGB transfer, BT.709 matrix). Buffers carrying
/// exactly these are not colour-converted by VideoToolbox (T-113); the aux view's data must never be.
public enum SessionTags {
    public static var primaries: CFString { kCVImageBufferColorPrimaries_ITU_R_709_2 }
    public static var transfer: CFString { kCVImageBufferTransferFunction_sRGB }
    public static var matrix: CFString { kCVImageBufferYCbCrMatrix_ITU_R_709_2 }

    public static func apply(to pb: CVPixelBuffer, centredChroma: Bool) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        let loc = centredChroma ? kCVImageBufferChromaLocation_Center : kCVImageBufferChromaLocation_TopLeft
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, loc, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, loc, .shouldPropagate)
    }
}

public enum PackerError: Error, CustomStringConvertible {
    case noDevice, noQueue, compile(String), invalidSize(Int, Int), textureCache(CVReturn), pool(CVReturn)
    case runtime(String)

    public var description: String {
        switch self {
        case .noDevice: return "no_metal_device"
        case .noQueue: return "no_command_queue"
        case .compile(let m): return "compile:\(m)"
        case .invalidSize(let w, let h): return "invalid_size:\(w)x\(h) (width % 4 == 0, height % 2 == 0)"
        case .textureCache(let s): return "texture_cache:\(s)"
        case .pool(let s): return "pool:\(s)"
        case .runtime(let m): return m
        }
    }
}

/// One packing pass over a BGRA frame: the AVC444v2 main and auxiliary views as `420f` IOSurface buffers.
public final class Packer444: @unchecked Sendable {
    public enum Strategy: String, Sendable, CaseIterable {
        /// One kernel: BGRA read (with the aux source samples re-read), everything written.
        case fused
        /// `convert444` to three full-resolution planes, then the pack kernel (extra memory traffic, simpler kernels).
        case twoPass
    }

    public struct Result {
        public var main: CVPixelBuffer
        public var aux: CVPixelBuffer?
        /// Command buffer creation to completion, microseconds.
        public var wallUs: UInt64
        /// GPU start to GPU end of the command buffer, microseconds (0 if the driver reports none).
        public var gpuUs: UInt64
    }

    public let width: Int
    public let height: Int
    public let mainChroma: MainChroma
    public let strategy: Strategy
    /// false = main view only (the cost of a plain BGRA -> 420f pass, the baseline).
    public let includeAux: Bool

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fused: MTLComputePipelineState
    private let convert: MTLComputePipelineState
    private let fromPlanes: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary
    private let planeTextures: [MTLTexture]

    public init(width: Int, height: Int, mainChroma: MainChroma, strategy: Strategy = .fused, includeAux: Bool = true,
                device: MTLDevice? = nil) throws {
        guard AVC444v2.isValid(width: width, height: height) else { throw PackerError.invalidSize(width, height) }
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw PackerError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw PackerError.noQueue }
        self.device = device
        self.queue = queue
        self.width = width
        self.height = height
        self.mainChroma = mainChroma
        self.strategy = strategy
        self.includeAux = includeAux

        let options = MTLCompileOptions()
        options.mathMode = .safe   // keep division and rounding close to the CPU reference
        options.mathFloatingPointFunctions = .precise
        do {
            let lib = try device.makeLibrary(source: PackerKernel.metalSource, options: options)
            func fn(_ name: String) throws -> MTLComputePipelineState {
                guard let f = lib.makeFunction(name: name) else { throw PackerError.compile("missing \(name)") }
                return try device.makeComputePipelineState(function: f)
            }
            fused = try fn(PackerKernel.fused)
            convert = try fn(PackerKernel.convert)
            fromPlanes = try fn(PackerKernel.fromPlanes)
        } catch let e as PackerError {
            throw e
        } catch {
            throw PackerError.compile(String(describing: error).split(separator: "\n").first.map(String.init) ?? "unknown")
        }

        let usage = MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
        var cache: CVMetalTextureCache?
        let cst = CVMetalTextureCacheCreate(nil, nil, device, [kCVMetalTextureUsage: usage] as CFDictionary, &cache)
        guard cst == kCVReturnSuccess, let cache else { throw PackerError.textureCache(cst) }
        textureCache = cache

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        let pst = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                          attrs as CFDictionary, &p)
        guard pst == kCVReturnSuccess, let p else { throw PackerError.pool(pst) }
        pool = p
        auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 12] as CFDictionary

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        var planes: [MTLTexture] = []
        for _ in 0..<3 {
            guard let t = device.makeTexture(descriptor: d) else { throw PackerError.runtime("plane_texture") }
            planes.append(t)
        }
        planeTextures = planes
    }

    /// Packs one `BGRA` buffer of the packer's size. Blocks until the GPU is done (no frame in flight afterwards).
    public func pack(_ src: CVPixelBuffer) throws -> Result {
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(src) == width, CVPixelBufferGetHeight(src) == height
        else { throw PackerError.runtime("source_not_bgra_\(width)x\(height)") }
        let main = try output()
        let aux = includeAux ? try output() : nil
        let cw = width / 2, ch = height / 2
        let srcTex = try texture(src, plane: 0, .bgra8Unorm, width, height)
        let mY = try texture(main, plane: 0, .r8Unorm, width, height)
        let mC = try texture(main, plane: 1, .rg8Unorm, cw, ch)
        let aY = try aux.map { try texture($0, plane: 0, .r8Unorm, width, height) }
        let aC = try aux.map { try texture($0, plane: 1, .rg8Unorm, cw, ch) }
        // Kernel slots for an absent aux still need textures (writes are skipped): reuse the main ones.
        let auxYTex = aY?.texture ?? mY.texture, auxCTex = aC?.texture ?? mC.texture

        let start = DispatchTime.now().uptimeNanoseconds
        guard let cb = queue.makeCommandBuffer() else { throw PackerError.runtime("command_buffer") }
        var mode: UInt32 = mainChroma == .pick ? 0 : 1
        var withAux: UInt32 = includeAux ? 1 : 0
        switch strategy {
        case .fused:
            guard let e = cb.makeComputeCommandEncoder() else { throw PackerError.runtime("encoder") }
            e.setComputePipelineState(fused)
            e.setTexture(srcTex.texture, index: 0)
            e.setTexture(mY.texture, index: 1)
            e.setTexture(mC.texture, index: 2)
            e.setTexture(auxYTex, index: 3)
            e.setTexture(auxCTex, index: 4)
            e.setBytes(&mode, length: 4, index: 0)
            e.setBytes(&withAux, length: 4, index: 1)
            e.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1), threadsPerThreadgroup: group(fused))
            e.endEncoding()
        case .twoPass:
            guard let e1 = cb.makeComputeCommandEncoder() else { throw PackerError.runtime("encoder") }
            e1.setComputePipelineState(convert)
            e1.setTexture(srcTex.texture, index: 0)
            for k in 0..<3 { e1.setTexture(planeTextures[k], index: 1 + k) }
            e1.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group(convert))
            e1.endEncoding()
            guard let e2 = cb.makeComputeCommandEncoder() else { throw PackerError.runtime("encoder") }
            e2.setComputePipelineState(fromPlanes)
            for k in 0..<3 { e2.setTexture(planeTextures[k], index: k) }
            e2.setTexture(mY.texture, index: 3)
            e2.setTexture(mC.texture, index: 4)
            e2.setTexture(auxYTex, index: 5)
            e2.setTexture(auxCTex, index: 6)
            e2.setBytes(&mode, length: 4, index: 0)
            e2.setBytes(&withAux, length: 4, index: 1)
            e2.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1), threadsPerThreadgroup: group(fromPlanes))
            e2.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime((srcTex, mY, mC, aY, aC)) {}
        CVMetalTextureCacheFlush(textureCache, 0)
        guard cb.status == .completed else { throw PackerError.runtime("gpu_status_\(cb.status.rawValue)") }
        let wallUs = (DispatchTime.now().uptimeNanoseconds - start) / 1000
        let gpu = cb.gpuEndTime - cb.gpuStartTime
        SessionTags.apply(to: main, centredChroma: mainChroma == .box)
        if let aux { SessionTags.apply(to: aux, centredChroma: false) }
        return Result(main: main, aux: aux, wallUs: wallUs, gpuUs: gpu.isFinite && gpu > 0 ? UInt64(gpu * 1_000_000) : 0)
    }

    /// The full-resolution 4:4:4 planes the `convert444` kernel makes from `src` (the 4:4:4 truth of the tools).
    public func planes444(_ src: CVPixelBuffer) throws -> Planes444 {
        let srcTex = try texture(src, plane: 0, .bgra8Unorm, width, height)
        guard let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else {
            throw PackerError.runtime("command_buffer")
        }
        e.setComputePipelineState(convert)
        e.setTexture(srcTex.texture, index: 0)
        for k in 0..<3 { e.setTexture(planeTextures[k], index: 1 + k) }
        e.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group(convert))
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime(srcTex) {}
        CVMetalTextureCacheFlush(textureCache, 0)
        guard cb.status == .completed else { throw PackerError.runtime("gpu_status_\(cb.status.rawValue)") }
        var out = Planes444(width: width, height: height)
        func read(_ t: MTLTexture) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height)
            bytes.withUnsafeMutableBytes {
                t.getBytes($0.baseAddress!, bytesPerRow: width, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return bytes
        }
        out.y = read(planeTextures[0])
        out.cb = read(planeTextures[1])
        out.cr = read(planeTextures[2])
        return out
    }

    // MARK: Plumbing

    private func output() throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let st = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxAttributes, &made)
        guard st == kCVReturnSuccess, let out = made else { throw PackerError.pool(st) }
        return out
    }

    private struct Wrapped {
        let cv: CVMetalTexture
        let texture: MTLTexture
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, _ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> Wrapped {
        var cv: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format, w, h, plane, &cv)
        guard st == kCVReturnSuccess, let cv, let t = CVMetalTextureGetTexture(cv) else {
            throw PackerError.runtime("texture_\(st)")
        }
        return Wrapped(cv: cv, texture: t)
    }

    private func group(_ p: MTLComputePipelineState) -> MTLSize {
        let w = p.threadExecutionWidth
        return MTLSize(width: w, height: max(1, p.maxTotalThreadsPerThreadgroup / w), depth: 1)
    }
}

/// Reads the planes of a `420f` buffer into `Planes420` (rows copied without padding).
public enum PixelBufferIO {
    public static func readPlanes420(_ pb: CVPixelBuffer) -> Planes420 {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let cw = w / 2, ch = h / 2
        var out = Planes420(width: w, height: h)
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0..<h { out.y.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: y * w).update(from: yBase + y * yStride, count: w) } }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for j in 0..<ch {
            let row = cBase + j * cStride
            for i in 0..<cw {
                out.cb[j * cw + i] = row[2 * i]
                out.cr[j * cw + i] = row[2 * i + 1]
            }
        }
        return out
    }

    /// Writes `p` into a `420f` buffer of the same size (the source of encoder tests and sharp-YUV comparison frames).
    public static func write(_ p: Planes420, to pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = p.width, h = p.height, cw = w / 2, ch = h / 2
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        p.y.withUnsafeBufferPointer { src in
            for y in 0..<h { (yBase + y * yStride).update(from: src.baseAddress! + y * w, count: w) }
        }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for j in 0..<ch {
            let row = cBase + j * cStride
            for i in 0..<cw {
                row[2 * i] = p.cb[j * cw + i]
                row[2 * i + 1] = p.cr[j * cw + i]
            }
        }
    }

    /// Reads a `BGRA` buffer as tightly packed bytes.
    public static func readBGRA(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h { (dst.baseAddress! + y * w * 4).update(from: base + y * stride, count: w * 4) }
        }
        return out
    }

    /// Creates a Metal-compatible IOSurface `BGRA` buffer.
    public static func makeBGRA(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return pb
    }

    /// Creates a Metal-compatible IOSurface `420f` buffer.
    public static func make420f(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &pb)
        return pb
    }
}
