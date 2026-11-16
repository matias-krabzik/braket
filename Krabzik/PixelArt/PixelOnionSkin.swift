import Foundation

/// Guías derivadas: no alteran el estado artístico ni la exportación.
enum PixelOnionSkin {
    static func previews(_ state: PixelArtState, frame: UUID, previous: Int, next: Int) -> [(Int, PixelBitmap)] {
        guard let index = state.frameIndex(frame) else { return [] }
        let current = PixelArtRenderer.render(state, frame: frame)
        return (-min(2, max(0, previous))...min(2, max(0, next)))
            .filter { $0 != 0 && state.frames.indices.contains(index + $0) }
            .sorted { abs($0) > abs($1) }
            .map { offset in
                var bitmap = PixelArtRenderer.render(state, frame: state.frames[index + offset].id)
                for pixel in stride(from: 0, to: bitmap.rgba.count, by: 4) {
                    if bitmap.rgba[pixel..<pixel + 4].elementsEqual(current.rgba[pixel..<pixel + 4]) {
                        bitmap.rgba[pixel + 3] = 0
                    }
                }
                return (offset, bitmap)
            }
    }
}
