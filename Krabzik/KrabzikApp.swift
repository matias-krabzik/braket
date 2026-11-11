import AppKit
import SwiftUI

@main
struct KrabzikApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller = WorkspaceController.forApp()

    var body: some Scene {
        Window("Braket", id: "workspace") {
            WorkspaceView(controller: controller)
                .background(WindowBridge(delegate: delegate, projectURL: controller.workspaceURL, theme: controller.settings.theme))
                .onAppear {
                    delegate.controller = controller
                    _ = AppUpdater.shared
                }
        }
        .defaultSize(width: 760, height: 420)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            CommandGroup(replacing: .newItem) {
                Button("Nuevo proyecto…", action: controller.createWorkspace).keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Abrir proyecto…", action: controller.chooseWorkspace).keyboardShortcut("o")
                Button("Cerrar proyecto") { controller.requestCloseWorkspace() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(controller.workspace == nil || controller.isSwitchingWorkspace)
                Divider()
                Button("Agregar subproyecto…", action: controller.projects.addFolders)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(controller.workspace == nil)
                Button("Nuevo archivo…") { controller.files.create() }.keyboardShortcut("n").disabled(controller.workspace == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Guardar") { if let document = controller.selectedDocument { Task { await controller.files.save(document) } } }
                    .keyboardShortcut("s").disabled(controller.selectedDocument == nil)
                Button("Guardar copia…", action: controller.files.saveCopy).keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(controller.selectedDocument == nil)
            }
            CommandGroup(replacing: .windowSize) {
                Button("Mostrar explorador") { controller.sidebarVisible.toggle() }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Mostrar panel inferior") { controller.processesVisible.toggle() }.keyboardShortcut("j")
                Button("Mostrar Codex") { controller.agent.visible.toggle() }.keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(controller.workspace == nil || controller.isReadOnly)
            }
            CommandMenu("Proyecto") {
                Button("Iniciar", action: controller.startAll).keyboardShortcut("r").disabled(controller.runnableProjects.isEmpty)
                Button("Detener") {
                    controller.runner.stopAll()
                }.keyboardShortcut(".").disabled(!controller.runner.hasActiveProcesses)
            }
            CommandMenu("SQL") {
                Button("Abrir script…", action: controller.files.importScripts).disabled(controller.workspace == nil)
                Button("Ejecutar selección o script", action: controller.executeSQL)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(controller.selectedDocument?.language != "SQL" || controller.connections.selected == nil || controller
                        .selectedDocument?.sqlExecution.isRunning == true)
                Button("Nueva conexión…") { controller.database.editingConnection = DatabaseConnection() }
                    .disabled(controller.workspace == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Buscar en el archivo") {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
                }.keyboardShortcut("f").disabled(controller.selectedDocument == nil)
            }
        }
        Settings {
            SettingsView(settings: controller.settings, controller: controller)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var controller: WorkspaceController? {
        didSet { openPendingProject() }
    }
    private var pendingProjectURL: URL?
    private var requestingInitialWindow = false
    private var checkingTermination = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A single SwiftUI Window cannot create external-event scenes. Handle
        // Finder documents directly so the home screen and editor keep one window.
        NSAppleEventManager.shared().setEventHandler(self,
                                                     andSelector: #selector(openDocuments(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func openDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let documents = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
              let url = documents.atIndex(1)?.fileURLValue else { return }
        pendingProjectURL = url
        openPendingProject()
        if controller == nil && !requestingInitialWindow {
            // A document launch skips the normal untitled-window event. Reopen
            // this same application so SwiftUI creates its single Window, then
            // onAppear installs the controller and consumes the pending file.
            requestingInitialWindow = true
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        }
    }

    private func openPendingProject() {
        guard let controller, let url = pendingProjectURL else { return }
        pendingProjectURL = nil
        controller.requestWorkspace(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        guard !checkingTermination else { return .terminateCancel }
        checkingTermination = true
        let lastState = controller.captureSessionState()
        Task {
            let allowed = await controller.prepareToLeave()
            if allowed {
                controller.saveSessionState(lastState)
                controller.runner.terminateImmediately()
                await controller.database.client.shutdown()
            }
            checkingTermination = false
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !checkingTermination else { return false }
        if let controller {
            guard !controller.isSwitchingWorkspace else { return false }
            if controller.workspace != nil {
                controller.requestCloseWorkspace()
                return false
            }
        }
        NSApp.terminate(nil)
        return false
    }
}

private struct WindowBridge: NSViewRepresentable {
    let delegate: AppDelegate
    let projectURL: URL?
    let theme: AppTheme

    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context: Context) {
        view.window?.backgroundColor = EditorPalette.background
        view.appDelegate = delegate
        view.projectURL = projectURL
        view.scheduleLayout()
    }

    final class WindowView: NSView {
        weak var appDelegate: AppDelegate?
        var projectURL: URL?
        private weak var configuredWindow: NSWindow?
        private var appliedProjectIsOpen = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleLayout()
        }

        func scheduleLayout() {
            // Wait for SwiftUI to update the toolbar before measuring its height.
            DispatchQueue.main.async { [weak self] in self?.applyLayout() }
        }

        private func applyLayout() {
            guard let window, let appDelegate, let screen = window.screen ?? NSScreen.main else { return }
            let isNewWindow = configuredWindow !== window
            if isNewWindow {
                window.delegate = appDelegate
                window.titlebarAppearsTransparent = true
                window.backgroundColor = EditorPalette.background
                window.isReleasedWhenClosed = false
                window.isRestorable = false
            }

            // Only resize between welcome and workspace; preserve the frame when switching projects.
            let projectIsOpen = projectURL != nil
            guard isNewWindow || appliedProjectIsOpen != projectIsOpen else { return }
            configuredWindow = window
            appliedProjectIsOpen = projectIsOpen
            guard !window.styleMask.contains(.fullScreen) else { return }

            window.layoutIfNeeded()
            let available = screen.visibleFrame
            let chromeWidth = window.frame.width - window.contentLayoutRect.width
            let chromeHeight = window.frame.height - window.contentLayoutRect.height
            let compact = NSSize(width: 760 + chromeWidth, height: 420 + chromeHeight)
            let size: NSSize
            if projectURL != nil {
                // Use one scale for both axes to retain the screen's aspect ratio.
                let display = screen.frame.size
                let minimumScale = max((900 + chromeWidth) / display.width, (580 + chromeHeight) / display.height)
                let maximumScale = min(available.width / display.width, available.height / display.height)
                let scale = min(max(0.75, minimumScale), maximumScale)
                size = NSSize(width: display.width * scale, height: display.height * scale)
            } else {
                size = NSSize(width: min(compact.width, available.width), height: min(compact.height, available.height))
            }
            let frame = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                               width: size.width, height: size.height)
            window.setFrame(frame, display: true, animate: window.isVisible && !isNewWindow)
        }
    }
}
