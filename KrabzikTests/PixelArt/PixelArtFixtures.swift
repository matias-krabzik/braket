@testable import Krabzik
import XCTest

/// Documentos de prueba compartidos por las pruebas del motor de pixel art.
enum PixelArtFixtures {
    static let red = PixelRGBA(255, 0, 0)
    static let blue = PixelRGBA(0, 0, 255)

    /// 40 × 40 (cruza el borde de un bloque), 2 capas, 2 fotogramas y una paleta de 2 entradas con
    /// píxeles libres y vinculados mezclados en la misma capa.
    static func mixedState() -> PixelArtState {
        var state = PixelArtState.blank(width: 40, height: 40)
        state.palette = PixelPalette(name: "Base", entries: [
            PaletteEntry(id: 7, name: "piel", color: red),
            PaletteEntry(id: 9, name: "madera", color: red, locked: true)
        ])
        state.layers.append(PixelLayer(name: "Detalle", opacity: 128))
        state.frames.append(PixelFrame(duration: 250))
        let base = state.layers[0].id
        let detail = state.layers[1].id
        var cel = PixelCel()
        cel.setPixel(x: 0, y: 0, to: .linked(7))
        cel.setPixel(x: 1, y: 0, to: .free(red))
        cel.setPixel(x: 39, y: 39, to: .linked(9))
        state.frames[0].cels[base] = cel
        var second = PixelCel()
        second.setPixel(x: 33, y: 2, to: .free(PixelRGBA(10, 20, 30, 40)))
        state.frames[1].cels[detail] = second
        state.sequences = [PixelSequence(name: "Idle", frameIDs: state.frames.map(\.id), playback: .pingPong)]
        return state
    }

    static func roundTrip(_ state: PixelArtState) throws -> PixelArtState {
        var store = PxaObjectStore()
        let ref = PixelArtStateCodec.encode(state, into: &store)
        return try PixelArtStateCodec.decode(ref, from: store)
    }
}
