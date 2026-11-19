import AppKit

/// Deja que AppKit consulte el cierre normal de la app aun con Configuración abierta.
/// Resuelve su borrador antes de cerrar la presentación y no adelanta el reinicio.
@MainActor final class SettingsCloseCoordinator {
    enum Choice { case save, discard, cancel }
    weak var window: NSWindow?
    var choose: () -> Choice = {
        let alert = NSAlert()
        alert.messageText = "¿Guardar los cambios de configuración antes de salir?"
        alert.informativeText = "Podés guardarlos, descartarlos o cancelar el cierre y la actualización."
        alert.addButton(withTitle: "Guardar cambios")
        alert.addButton(withTitle: "Descartar cambios")
        alert.addButton(withTitle: "Cancelar").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
    private var hasChanges: () -> Bool = { false }
    private var save: () -> Void = {}
    private var discard: () -> Void = {}
    private var dismiss: () -> Void = {}
    private var originalPrevention = true
    private var observers: [any NSObjectProtocol] = []
    private weak var closingParent: NSWindow?
    private var completion: CheckedContinuation<Bool, Never>?

    func attach(_ window: NSWindow, hasChanges: @escaping () -> Bool,
                save: @escaping () -> Void, discard: @escaping () -> Void, dismiss: @escaping () -> Void) {
        if self.window !== window {
            detach()
            self.window = window
            originalPrevention = window.preventsApplicationTerminationWhenModal
            window.preventsApplicationTerminationWhenModal = false
            for name in [NSWindow.willCloseNotification, NSWindow.didEndSheetNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    let windowID = notification.object.map { ObjectIdentifier($0 as AnyObject) }
                    let closing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        if (closing && windowID == ObjectIdentifier(window))
                            || (!closing && self.closingParent.map { windowID == ObjectIdentifier($0) } == true) {
                            self.finish()
                        }
                    }
                })
            }
        }
        self.hasChanges = hasChanges
        self.save = save
        self.discard = discard
        self.dismiss = dismiss
    }

    func detach() {
        if let window { window.preventsApplicationTerminationWhenModal = originalPrevention }
        window = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        hasChanges = { false }
        save = {}
        discard = {}
        dismiss = {}
        finish()
    }

    func prepareToClose() async -> Bool {
        guard let window, window.isVisible else { return true }
        // Un editor de conexión u otro diálogo hijo conserva su propio flujo de cambios.
        guard window.attachedSheet == nil, completion == nil else { return false }
        if hasChanges() {
            switch choose() {
            case .save: save()
            case .discard: discard()
            case .cancel: return false
            }
        }
        return await withCheckedContinuation { continuation in
            completion = continuation
            closingParent = window.sheetParent
            if window.sheetParent != nil { dismiss() }
            else { window.close() }
        }
    }

    private func finish() {
        let reply = completion
        completion = nil
        closingParent = nil
        reply?.resume(returning: true)
    }
}
