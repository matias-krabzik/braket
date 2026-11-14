import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Miniatura derivada del fotograma activo (PXA-01 §1): PNG de hasta 512 × 512, sin interpolar.
/// Nunca es fuente de verdad: si no es válida se descarta con aviso y se regenera.
enum PixelArtPreview {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func png(of state: PixelArtState, frame: UUID?) -> Data? {
        guard let frameID = frame ?? state.frames.first?.id, state.frames.contains(where: { $0.id == frameID }) else { return nil }
        let bitmap = PixelArtRenderer.render(state, frame: frameID)
        let maxAxis = PxaLimits.previewAxis
        let ratio = min(Double(maxAxis) / Double(bitmap.width), Double(maxAxis) / Double(bitmap.height))
        let upscale = ratio >= 1 ? Int(ratio) : 1
        let targetWidth = ratio >= 1 ? bitmap.width * upscale : max(1, Int(Double(bitmap.width) * ratio))
        let targetHeight = ratio >= 1 ? bitmap.height * upscale : max(1, Int(Double(bitmap.height) * ratio))
        var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                let sourceX = ratio >= 1 ? x / upscale : min(bitmap.width - 1, Int(Double(x) / ratio))
                let sourceY = ratio >= 1 ? y / upscale : min(bitmap.height - 1, Int(Double(y) / ratio))
                let source = (sourceY * bitmap.width + sourceX) * 4
                let target = (y * targetWidth + x) * 4
                pixels.replaceSubrange(target..<target + 4, with: bitmap.rgba[source..<source + 4])
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: targetWidth, height: targetHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: targetWidth * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Comprobación barata: firma PNG y un IHDR con dimensiones dentro del tope. No decodifica la imagen.
    static func isAcceptable(_ data: Data) -> Bool {
        guard data.count >= 33, Array(data.prefix(8)) == pngSignature, data.count <= PxaLimits.imageBytes else { return false }
        let header = [UInt8](data[12..<24])
        guard String(decoding: header[0..<4], as: UTF8.self) == "IHDR" else { return false }
        let width = Int(header[4]) << 24 | Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7])
        let height = Int(header[8]) << 24 | Int(header[9]) << 16 | Int(header[10]) << 8 | Int(header[11])
        return (1...PxaLimits.previewAxis).contains(width) && (1...PxaLimits.previewAxis).contains(height)
    }
}
