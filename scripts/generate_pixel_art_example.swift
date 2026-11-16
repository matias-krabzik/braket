// Rebuild example (use a temporary copy of sources if another agent is editing):
// swiftc Krabzik/PixelArt/*.swift scripts/generate_pixel_art_example.swift ...
// Swift requires this executable's source to be named main.swift when compiling multiple files.
// Run the resulting executable with the Examples/Pixel art directory as its sole argument.
import CoreGraphics
import Foundation
import ImageIO
let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard let src = CGImageSourceCreateWithURL(root.appendingPathComponent("bosque-referencia.png") as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("No se pudo cargar la referencia") }
let size = 64
var bytes = [UInt8](repeating: 0, count: size * size * 4)
bytes.withUnsafeMutableBytes { buffer in
    guard let c = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("No se pudo crear el contexto de imagen") }
    c.interpolationQuality = .none
    c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
}
var doc = try PixelArtDocument(width: size, height: size)
let base = doc.state.layers[0].id
let smoke = PixelLayer(name: "Humo")
let light = PixelLayer(name: "Luces")
let fireflies = PixelLayer(name: "Luciérnagas")
func apply(_ label: String, _ ops: [PixelOperation]) throws {
    try doc.core.apply(PixelTransaction(label: label, operationKind: "example", scope: .document(doc.state), operations: ops))
}
try apply("Capas del bosque",
          [.setLayerProperty(base, .name("Entorno")), .addLayer(smoke, at: 1), .addLayer(light, at: 2), .addLayer(fireflies, at: 3)])
for _ in 1..<8 { try apply("Fotograma", [.addFrame(PixelFrame(duration: 125), at: doc.state.frames.count)]) }
for (n, frame) in doc.state.frames.enumerated() {
    var background: [PixelWrite] = [], fumes: [PixelWrite] = []
    for y in 0..<size { for x in 0..<size {
        let p = (y * size + x) * 4
        let color = PixelRGBA(bytes[p], bytes[p+1], bytes[p+2])
        let isSmoke = y < 14 && x > 39 && x < 56 && Int(color.red) > Int(color.green) + 12 && color.blue > 70
        if isSmoke {
            background.append(PixelWrite(x: x, y: y, value: .free(PixelRGBA(19, 24, 42))))
            let shift = [0,1,2,1,0,-1,-2,-1][n]
            fumes.append(PixelWrite(x: x + shift, y: y, value: .free(color)))
        } else { background.append(PixelWrite(x: x, y: y, value: .free(color))) }
    }}
    let spark = PixelWrite(x: 14 + n, y: 20 + [0,1,2,1,0,-1,-2,-1][n], value: .free(PixelRGBA(255, 211, 110)))
    try apply("Bosque · fotograma \(n + 1)",
              [
                  .writePixels(layer: base, frame: frame.id, writes: background),
                  .writePixels(layer: smoke.id, frame: frame.id, writes: fumes),
                  .writePixels(layer: fireflies.id, frame: frame.id, writes: [spark])
              ])
}
let colors = [
    PixelRGBA(24,20,39),
    PixelRGBA(56,42,73),
    PixelRGBA(101,75,132),
    PixelRGBA(139,115,164),
    PixelRGBA(38,72,77),
    PixelRGBA(55,102,85),
    PixelRGBA(90,130,58),
    PixelRGBA(143,170,70),
    PixelRGBA(108,70,68),
    PixelRGBA(164,104,80),
    PixelRGBA(205,137,91),
    PixelRGBA(255,211,110),
    PixelRGBA(250,232,165),
    PixelRGBA(28,37,52),
    PixelRGBA(64,82,102),
    PixelRGBA(179,151,164)
]
let ids = try doc.core.reserveEntryIDs(colors.count)
try apply("Paleta nocturna",
          colors.enumerated().map { .addPaletteEntry(PaletteEntry(id: ids[$0.offset], name: "Color \($0.offset + 1)", color: $0.element)) })
doc.editor.activeFrameID = doc.state.frames[2].id
doc.editor.activeLayerID = smoke.id
doc.editor.onionSkin = true
doc.editor.onionPrevious = 2
doc.editor.onionNext = 1
doc.editor.zoomPercent = 800
let data = try PixelArtFile.snapshot(of: doc).data
let loaded = try PixelArtFile.read(data)
precondition(loaded.state == doc.state && loaded.editor == doc.editor)
precondition(PixelOnionSkin.previews(loaded.state, frame: loaded.state.frames[0].id, previous: 2, next: 2).count == 2)
try data.write(to: root.appendingPathComponent("bosque.pxa"))
print("Ejemplo verificado: \(data.count) bytes, 4 capas, 8 fotogramas")
