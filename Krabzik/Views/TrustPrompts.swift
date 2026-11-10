import AppKit

/// Diálogos de confianza. Usan `NSAlert` con una vista accesoria de texto
/// seleccionable: hay que poder leer y copiar rutas y comandos completos antes de
/// decidir. Ver docs/specs/S1-proyecto-no-confiable.md.
@MainActor enum TrustPrompts {
    static func ask(_ prompt: TrustPrompt) -> TrustDecision {
        let alert = NSAlert()
        alert.messageText = "¿Confiar en «\(prompt.name)»?"
        alert.informativeText = """
        Este proyecto no se abrió antes en esta Mac. Puede traer comandos de shell y \
        carpetas de cualquier parte del disco. Abrirlo solo lectura permite ver los \
        archivos sin poder ejecutar nada.
        """
        alert.accessoryView = details(prompt)
        alert.addButton(withTitle: "Confiar y abrir")
        alert.addButton(withTitle: "Abrir solo lectura")
        alert.addButton(withTitle: "Cancelar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .trust
        case .alertSecondButtonReturn: return .readOnly
        default: return .cancel
        }
    }

    static func askCommand(_ prompt: CommandPrompt) -> CommandDecision {
        let alert = NSAlert()
        alert.messageText = "¿Ejecutar el comando de «\(prompt.project)»?"
        alert.informativeText = "Se ejecuta con tu usuario y tu entorno completo."
        alert.accessoryView = textBox("""
        Carpeta:
        \(prompt.directory)

        Comando:
        \(prompt.command)
        """)
        alert.addButton(withTitle: "Ejecutar una vez")
        alert.addButton(withTitle: "Ejecutar siempre este comando")
        alert.addButton(withTitle: "Cancelar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .once
        case .alertSecondButtonReturn: return .always
        default: return .cancel
        }
    }

    private static func details(_ prompt: TrustPrompt) -> NSView {
        var lines = ["Archivo:", prompt.path, ""]
        if prompt.externalFolders.isEmpty {
            lines += ["Carpetas: todas dentro de la carpeta del proyecto.", ""]
        } else {
            lines.append("Carpetas FUERA de la carpeta del proyecto:")
            lines += prompt.externalFolders.map { "  \($0)" }
            lines.append("")
        }
        if prompt.commands.isEmpty {
            lines += ["Comandos: ninguno.", ""]
        } else {
            lines.append("Comandos que podría ejecutar:")
            lines += prompt.commands.map { "  \($0)" }
            lines.append("")
        }
        lines.append("Conexiones MySQL declaradas: \(prompt.connectionCount) (sin contraseñas).")
        return textBox(lines.joined(separator: "\n"))
    }

    private static func textBox(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 190))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = text
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
}

extension WorkspaceController {
    /// El controlador de la app, con los diálogos reales enganchados. Es el único sitio que los
    /// engancha: ver el comentario de `confirmTrust` en `WorkspaceController`.
    @MainActor static func forApp() -> WorkspaceController {
        let controller = WorkspaceController()
        controller.confirmTrust = TrustPrompts.ask
        controller.confirmCommand = TrustPrompts.askCommand
        return controller
    }
}
