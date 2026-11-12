import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Observation

/// Un archivo abierto en el editor.
///
/// El texto **no** se mantiene actualizado en cada tecla: `text` se relee de la vista
/// nativa cuando alguien lo pide (ver su documentación y C11). `originalData` es lo que
/// se leyó del disco y es con lo que se compara al guardar, para no pisar un cambio
/// externo. Confinado al main actor.
@MainActor @Observable
final class EditorDocument: Identifiable {
    let id: URL
    var url: URL { id }
    var isDirty = false
    var isSaving = false
    var hasExternalChange = false
    var previewImage: NSImage?
    var line = 1
    var column = 1
    /// El texto del documento. **No se mantiene actualizado en cada tecla**: leer
    /// `NSTextView.string` materializa un `String` nuevo del `NSTextStorage`, así que
    /// hacerlo por pulsación cuesta O(n) sobre un archivo que puede tener 5 MB. El editor
    /// solo marca la caché como vieja, y acá se relee cuando alguien pide el texto:
    /// guardar, ejecutar SQL, guardar una copia o recargar desde disco. Todos son eventos
    /// puntuales del usuario. Ver docs/specs/C11-rendimiento-editor.md.
    var text: String {
        get {
            if textIsStale, let surface = editorStorage as? EditorSurface {
                cachedText = surface.textView.string
                textIsStale = false
            }
            return cachedText
        }
        set {
            cachedText = newValue
            textIsStale = false
        }
    }

    @ObservationIgnored private var cachedText: String
    @ObservationIgnored private var textIsStale = false
    @ObservationIgnored var originalData: Data
    @ObservationIgnored var editorStorage: AnyObject?
    @ObservationIgnored var selectedRange = NSRange(location: 0, length: 0)
    let sqlExecution = SQLExecution()

    var sqlToExecute: (text: String, startingLine: Int) {
        let source = text as NSString
        guard selectedRange.length > 0, NSMaxRange(selectedRange) <= source.length else { return (text, 1) }
        let prefix = source.substring(to: selectedRange.location)
        return (source.substring(with: selectedRange), prefix.filter { $0 == "\n" }.count + 1)
    }

    var language: String { SyntaxLanguage.name(url) }

    init(url: URL, data: Data) throws {
        guard data.count <= 5 * 1024 * 1024 else { throw WorkspaceError.largeFile }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw WorkspaceError.binaryFile }
        self.id = url.standardizedFileURL
        self.cachedText = text
        self.originalData = data
    }

    init(url: URL, previewData: Data) throws {
        guard let image = NSImage(data: previewData), image.isValid else { throw WorkspaceError.invalidImage }
        self.id = url.standardizedFileURL
        self.cachedText = ""
        self.originalData = Data()
        self.previewImage = image
    }

    init(relocating document: EditorDocument, to url: URL) {
        self.id = url.standardizedFileURL
        self.cachedText = document.text
        self.originalData = document.originalData
        self.previewImage = document.previewImage
        self.isDirty = document.isDirty
        self.hasExternalChange = document.hasExternalChange
        self.line = document.line
        self.column = document.column
        self.selectedRange = document.selectedRange
    }

    /// La llama el editor en cada cambio: O(1). El texto se relee cuando alguien lo pida.
    func markTextStale() { textIsStale = true }

    /// Suelta la vista nativa del documento. Se llama al cerrar el documento o el proyecto.
    /// Lee el texto antes de soltarla: después ya no hay de dónde releerlo.
    func releaseEditor() {
        _ = text
        (editorStorage as? EditorSurface)?.teardown()
        editorStorage = nil
    }

    func acceptExternalData(_ data: Data, discardEdits: Bool = false) {
        guard data != originalData || discardEdits else { return }
        guard (!isDirty && !isSaving) || discardEdits, data.count <= 5 * 1024 * 1024,
              !data.contains(0), let value = String(data: data, encoding: .utf8) else {
                  hasExternalChange = true
                  return
              }
        text = value
        originalData = data
        isDirty = false
        hasExternalChange = false
        (editorStorage as? EditorSurface)?.reloadFromDocument()
    }

    func acceptExternalPreviewData(_ data: Data) throws {
        guard let image = NSImage(data: data), image.isValid else { throw WorkspaceError.invalidImage }
        previewImage = image
        hasExternalChange = false
    }
}

/// Leer y escribir archivos del editor, con los dos límites que importan: 5 MB de
/// tamaño y la comprobación de que el archivo en disco sigue siendo el que se leyó.
enum DocumentIO {
    private static let imageExtensions: Set<String> = ["png", "apng", "jpg", "jpeg", "gif", "webp", "heic", "heif",
                                                       "bmp", "tif", "tiff", "ico", "icns", "avif", "jp2", "j2k",
                                                       "psd", "svg"]

    static func isPreviewableImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// ImageIO lee desde la URL y reduce la imagen antes de llevarla al editor.
    /// El límite de 5 MB corresponde únicamente a documentos de texto.
    static func preview(_ url: URL) throws -> Data {
        if url.pathExtension.lowercased() == "svg" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 10 * 1024 * 1024 else {
                throw WorkspaceError.invalidImage
            }
            let data = try Data(contentsOf: url)
            guard FileIcons.safeSVG(data) else { throw WorkspaceError.invalidImage }
            return data
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2600
              ] as CFDictionary) else { throw WorkspaceError.invalidImage }
        guard let output = CFDataCreateMutable(nil, 0) else { throw WorkspaceError.invalidImage }
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw WorkspaceError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WorkspaceError.invalidImage }
        return output as Data
    }

    static func read(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 5 * 1024 * 1024 else { throw WorkspaceError.largeFile }
        return try Data(contentsOf: url)
    }

    static func save(_ data: Data, to url: URL, expected: Data) throws {
        // A missing or externally modified file must never be silently replaced.
        let current = try Data(contentsOf: url)
        guard current == expected else { throw WorkspaceError.externalChange }
        try data.write(to: url, options: .atomic)
    }
}
