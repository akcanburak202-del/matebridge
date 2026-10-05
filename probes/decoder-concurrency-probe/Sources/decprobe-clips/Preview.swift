import CoreGraphics
import DecProbeCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `--preview N`: one rendered frame per clip as PNG (no encoder involved).
enum Preview {
    static func write(scene: Scene, spec: ClipSpec, frame: Int, to path: String) throws {
        guard let ctx = CGContext(
            data: nil, width: spec.width, height: spec.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ProbeError("context") }
        scene.draw(frame: frame, into: ctx, originX: spec.x, originY: spec.y, clipHeight: spec.height)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { throw ProbeError("png \(path)") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ProbeError("png finalize \(path)") }
    }
}
