import SwiftUI

struct TerminalPanel: View {
    let controller: WorkspaceController
    let projectURL: URL
    @State private var editing: TerminalTabConfiguration?
    private var manager: TerminalManager { controller.terminals }
    private var config: TerminalProjectConfiguration { manager.configuration(for: projectURL) }
    private var selected: TerminalTabConfiguration? {
        config.tabs.first { $0.id == config.selectedID } ?? config.tabs.first
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(config.tabs) { tab in terminalTab(tab) }
                        Button { manager.addTab(projectURL) } label: {
                            Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.fullArea).help("Nueva terminal")
                            .disabled(controller.isReadOnly)
                    }.padding(6)
                }
                Button { manager.setVisible(false, for: projectURL) } label: {
                    Image(systemName: "minus").frame(width: 30, height: 28).contentShape(Rectangle())
                }.buttonStyle(.fullArea).help("Minimizar terminal · mantener sesiones activas").padding(.trailing, 8)
            }.background(Theme.bar)
            Divider()
            if let selected {
                if controller.isReadOnly {
                    ContentUnavailableView("Terminal deshabilitada", systemImage: "lock",
                                           description: Text("Confiá en este proyecto para iniciar una sesión de shell."))
                } else if let session = manager.sessions[selected.id], session.view != nil {
                    NativeTerminal(session: session, theme: controller.settings.theme,
                                   typography: controller.settings.codeTypography, size: controller.settings.codeFontSize)
                        .id(session.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 8) {
                        Text("zsh · \(session.currentDirectory)").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if session.hasWork {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("\(max(1, session.children.count)) procesos activos")
                        } else { Text(session.running ? "Lista" : "Sesión finalizada") }
                    }.font(Theme.interfaceFont(11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task(id: selected.id) { _ = manager.activate(selected, project: projectURL, trusted: !controller.isReadOnly) }
                }
            } else {
                ContentUnavailableView {
                    Label("Terminal", systemImage: "terminal")
                } description: { Text("Creá una pestaña para abrir un shell en la carpeta del proyecto.") }
                actions: { Button("Nueva terminal") { manager.addTab(projectURL) }.disabled(controller.isReadOnly) }
            }
        }
        .background(Theme.background)
        .sheet(item: $editing) { tab in
            TerminalEnvironmentEditor(manager: manager, projectURL: projectURL, tab: tab)
        }
        .alert("Terminal", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.error = nil } })) {
            Button("Aceptar") { manager.error = nil }
        } message: { Text(manager.error ?? "") }
    }
    private func terminalTab(_ tab: TerminalTabConfiguration) -> some View {
        TerminalTabItem(name: tab.name, selected: selected?.id == tab.id,
                        busy: manager.sessions[tab.id]?.hasWork == true, editable: !controller.isReadOnly,
                        select: { manager.select(tab.id, for: projectURL) }, configure: { editing = tab },
                        close: { Task { await manager.close(tab, project: projectURL) } })
        .contextMenu {
            Button("Configurar terminal…") { editing = tab }.disabled(controller.isReadOnly)
            Button("Reiniciar sesión") { Task { await manager.restart(tab, project: projectURL) } }.disabled(controller.isReadOnly)
            Divider()
            Button("Cerrar terminal") { Task { await manager.close(tab, project: projectURL) } }
        }
    }
}

private struct NativeTerminal: NSViewRepresentable {
    let session: TerminalSession
    let theme: AppTheme
    let typography: CodeTypography
    let size: Double
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ host: NSView, context: Context) {
        session.applyAppearance()
        guard let terminal = session.view, terminal.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        terminal.removeFromSuperview()
        host.addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: host.topAnchor), terminal.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        DispatchQueue.main.async { host.window?.makeFirstResponder(terminal) }
    }
}
