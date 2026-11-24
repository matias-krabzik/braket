import AppKit

/// Texto plano para otras apps y un tipo privado para distinguir NULL/DEFAULT de
/// las cadenas literales «NULL»/«DEFAULT» al copiar entre celdas de Braket.
enum SQLCellClipboard {
    enum Action { case copy, paste }
    static let valueType = NSPasteboard.PasteboardType("com.krabzik.ide.sql-cell-value")

    static func action(for event: NSEvent) -> Action? {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let key = characters.isEmpty ? [UInt16(8): "c", 9: "v"][event.keyCode] : characters
        switch key {
        case "c": return .copy
        case "v": return .paste
        default: return nil
        }
    }

    static func write(_ value: SQLCellValue, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(value.display, forType: .string)
        let kind: String
        switch value {
        case .text: kind = "text"
        case .null: kind = "null"
        case .serverDefault: kind = "default"
        }
        item.setString(kind, forType: valueType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    static func read(from pasteboard: NSPasteboard) -> SQLCellValue? {
        guard let text = pasteboard.string(forType: .string) else { return nil }
        switch pasteboard.string(forType: valueType) {
        case "null" where text == "NULL": return .null
        case "default" where text == "DEFAULT": return .serverDefault
        default: return .text(text)
        }
    }
}
