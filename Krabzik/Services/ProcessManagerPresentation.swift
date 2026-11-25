import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class ProcessManagerPresentation: NSObject, NSWindowDelegate {
    var isDetached: Bool
    var wasVisible: Bool {
        didSet { defaults.set(wasVisible, forKey: "processManager.visible") }
    }
    var staysOnTop: Bool {
        didSet {
            defaults.set(staysOnTop, forKey: "processManager.onTop")
            windowController?.window?.level = staysOnTop ? .floating : .normal
        }
    }
    @ObservationIgnored var reopenWorkspace: (() -> Void)?
    var selectedID: UUID?
    var query = ""
    var currentProjectOnly = false
    var listeners: [ProcessInspection.Listener] = []
    let inspection = ProcessInspection()
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Each IDE session starts with the manager integrated; detaching is an explicit action.
        isDetached = false
        wasVisible = defaults.bool(forKey: "processManager.visible")
        staysOnTop = defaults.bool(forKey: "processManager.onTop")
        super.init()
    }
    @ObservationIgnored private var windowController: NSWindowController?

    func detach(_ controller: WorkspaceController, remember: Bool = true) {
        wasVisible = true
        defaults.set(true, forKey: "processManager.visible")
        isDetached = true
        if remember { defaults.set(true, forKey: "processManager.detached") }
        if let windowController { windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Procesos · Braket"
        window.level = staysOnTop ? .floating : .normal
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 650, height: 450)
        window.delegate = self
        window.appearance = NSAppearance(named: controller.settings.theme == .light ? .aqua : .darkAqua)
        window.backgroundColor = EditorPalette.background
        window.contentView = NSHostingView(rootView: ProcessManagerView(controller: controller, detached: true))
        if !window.setFrameUsingName("BraketProcessManager") { window.center() }
        window.setFrameAutosaveName("BraketProcessManager")
        let host = NSWindowController(window: window)
        windowController = host
        host.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
    /// Closing the workspace keeps its processes supervised without changing the preferred presentation.
    @discardableResult
    func keepProcessesVisible(_ controller: WorkspaceController) -> Bool {
        guard controller.runner.hasActiveProcesses else { return false }
        detach(controller, remember: false)
        return true
    }
    func updateTheme(_ theme: AppTheme) {
        windowController?.window?.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        windowController?.window?.backgroundColor = EditorPalette.background
    }
    func dock(_ controller: WorkspaceController) {
        isDetached = false
        defaults.set(false, forKey: "processManager.detached")
        windowController?.close()
        windowController = nil
        wasVisible = true
        defaults.set(true, forKey: "processManager.visible")
        controller.processesVisible = true
        controller.pixelProcessesVisible = true
        reopenWorkspace?()
    }
    func windowWillClose(_ notification: Notification) {
        wasVisible = false
        defaults.set(false, forKey: "processManager.visible")
        windowController = nil
    }
    func show(_ controller: WorkspaceController) {
        if isDetached { detach(controller) }
        else { wasVisible = true
            controller.processesVisible = true
            controller.pixelProcessesVisible = true
        }
    }
}
