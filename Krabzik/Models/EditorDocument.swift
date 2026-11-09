import Foundation
import Observation

@MainActor @Observable
final class EditorDocument: Identifiable {
    let id: URL
    var url: URL { id }
    var isDirty = false
    var isSaving = false
    var hasExternalChange = false
    var line = 1
    var column = 1
    @ObservationIgnored var text: String
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

    var language: String {
        switch url.pathExtension.lowercased() {
        case "php": return "PHP"
        case "ts", "tsx": return "TypeScript"
        case "js", "jsx", "mjs", "cjs": return "JavaScript"
        case "sql": return "SQL"
        case "swift": return "Swift"
        case "html", "astro": return "HTML"
        case "css", "scss": return "CSS"
        case "json": return "JSON"
        case "md": return "Markdown"
        default: return "Texto"
        }
    }

    init(url: URL, data: Data) throws {
        guard data.count <= 5 * 1024 * 1024 else { throw WorkspaceError.largeFile }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw WorkspaceError.binaryFile }
        self.id = url.standardizedFileURL
        self.text = text
        self.originalData = data
    }

    func acceptExternalData(_ data: Data, discardEdits: Bool = false) {
        guard data != originalData || discardEdits else { return }
        guard (!isDirty && !isSaving) || discardEdits, data.count <= 5 * 1024 * 1024,
              !data.contains(0), let value = String(data: data, encoding: .utf8) else { hasExternalChange = true; return }
        text = value; originalData = data; isDirty = false; hasExternalChange = false
        (editorStorage as? EditorSurface)?.reloadFromDocument()
    }
}

enum DocumentIO {
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
