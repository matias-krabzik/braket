import AppKit

extension CodeTextView {
    @objc func formatSQL(_ sender: Any?) {
        guard isEditable, editorSurface?.document?.language == "SQL", !formattingSQL else { return }
        let original = string
        let selection = selectedRange()
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: (original as NSString).length)
        let sql = (original as NSString).substring(with: range)
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let options = Theme.settings.editorOptions
        formattingSQL = true
        Task { [weak self] in
            defer { self?.formattingSQL = false }
            do {
                let formatted = try await SQLFormatterEngine.shared.format(sql, options: options)
                guard let self, self.isEditable else { return }
                guard self.string == original, self.selectedRange() == selection else {
                    self.showFormattingError("El archivo o la selección cambió durante el formato. Volvé a intentarlo.")
                    return
                }
                guard formatted != sql else { return }
                self.breakUndoCoalescing()
                self.insertText(formatted, replacementRange: range)
                self.breakUndoCoalescing()
                self.undoManager?.setActionName("Formatear SQL")
                let updated = selection.length > 0 ? NSRange(location: range.location, length: formatted.utf16.count)
                    : NSRange(location: min(selection.location, self.string.utf16.count), length: 0)
                self.setSelectedRange(updated)
                self.scrollRangeToVisible(updated)
            } catch { self?.showFormattingError(error.localizedDescription) }
        }
    }

    private func showFormattingError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "No se pudo formatear el SQL"
        alert.informativeText = message
        alert.addButton(withTitle: "Aceptar")
        alert.beginSheetModal(for: window)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if editorSurface?.document?.language == "SQL" {
            menu?.addItem(.separator())
            let item = NSMenuItem(title: "Formatear SQL", action: #selector(formatSQL(_:)), keyEquivalent: "l")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.isEnabled = isEditable && !formattingSQL
            menu?.addItem(item)
        }
        return menu
    }
}
