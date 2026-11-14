import SwiftUI

struct AgentSessionsSidebar: View {
    let controller: WorkspaceController
    @State private var filter = ""
    @State private var renaming: AgentSessionRecord?
    @State private var title = ""

    private var sessions: [AgentSessionRecord] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return controller.agent.sessions.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SESIONES DE CODEX").font(.system(size: Theme.zoom(10), weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { controller.openAgent(newSession: true) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("Nueva sesión").accessibilityLabel("Nueva sesión")
                    .disabled(controller.isReadOnly || controller.agent.isBusy)
            }.padding(14)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filtrar sesiones", text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Limpiar filtro")
                }
            }
            .font(.system(size: Theme.zoom(11))).padding(7)
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 12).padding(.bottom, 10)
            ScrollView {
                SidebarTree(nodes: sessions.map { SidebarTreeNode(id: $0.id.uuidString, value: $0) },
                            name: { $0.title }, activate: { controller.openAgent(sessionID: $0.id) },
                            selectedID: controller.agent.selectedSessionID?.uuidString, activateOnSingleClick: true) { session in
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .frame(width: Theme.zoom(SidebarTreeStyle.iconSize)).foregroundStyle(.secondary)
                        Text(ModelText.display(session.title, limit: 100)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        if controller.agent.selectedSessionID == session.id && controller.agent.isRunning {
                            ProgressView().controlSize(.mini).padding(.trailing, 10)
                        }
                    }
                    .font(.system(size: Theme.zoom(12)))
                    .help(session.title + " · " + session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .contextMenu {
                        Button("Renombrar…") {
                            title = session.title
                            renaming = session
                        }
                    }
                }
                .disabled(controller.isReadOnly || controller.agent.isBusy)
                if sessions.isEmpty {
                    Text(filter.isEmpty ? "Creá una sesión con + para trabajar con Codex." : "No hay sesiones que coincidan.")
                        .font(.caption).foregroundStyle(.secondary).padding(15)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
        .sheet(item: $renaming) { session in
            VStack(alignment: .leading, spacing: 20) {
                Text("Renombrar sesión").font(.headline)
                TextField("Nombre", text: $title).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancelar") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Guardar") {
                        controller.agent.renameSession(session.id, title: title)
                        renaming = nil
                    }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 380)
        }
    }
}
