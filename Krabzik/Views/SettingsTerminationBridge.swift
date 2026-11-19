import AppKit
import SwiftUI

/// Solo Configuración permite que el delegado resuelva el cierre; los demás modales
/// siguen impidiéndolo hasta que la persona termine sus ediciones.
struct SettingsTerminationBridge: NSViewRepresentable {
    let coordinator: SettingsCloseCoordinator
    let hasChanges: () -> Bool
    let save: () -> Void
    let discard: () -> Void
    let dismiss: () -> Void

    func makeNSView(context: Context) -> BridgeView { BridgeView() }
    func updateNSView(_ view: BridgeView, context: Context) {
        view.presentation = self
        view.register()
    }
    static func dismantleNSView(_ view: BridgeView, coordinator: ()) {
        view.presentation?.coordinator.detach()
        view.presentation = nil
    }

    final class BridgeView: NSView {
        var presentation: SettingsTerminationBridge?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register()
        }
        func register() {
            guard let window, let presentation else { return }
            presentation.coordinator.attach(window, hasChanges: presentation.hasChanges,
                                            save: presentation.save, discard: presentation.discard,
                                            dismiss: presentation.dismiss)
        }
    }
}
