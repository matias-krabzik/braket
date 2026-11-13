import SwiftUI

enum WorkspaceSidebarTab: String, Codable, CaseIterable {
    case code, database
    var title: String { self == .code ? "Código" : "Base de datos" }
}

struct WorkspaceSidebar: View {
    @Bindable var controller: WorkspaceController
    let workspace: Workspace
    let url: URL
    @State private var codeFilter = ""
    @State private var databaseFilter = ""
    @State private var search = SidebarFileSearch()
    @State private var searching = false
    @State private var searchError: String?

    private var code: Bool { controller.sidebarTab == .code }
    private var query: String { codeFilter.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(workspace.name).font(.system(size: Theme.zoom(13), weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(workspace.name)
                Picker("Explorador", selection: $controller.sidebarTab) {
                    ForEach(WorkspaceSidebarTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.regular)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(code ? "Filtrar archivos" : "Filtrar conexiones y SQL",
                                  text: code ? $codeFilter : $databaseFilter)
                            .textFieldStyle(.plain).font(.system(size: Theme.zoom(11)))
                        if !(code ? codeFilter : databaseFilter).isEmpty {
                            Button {
                                if code { codeFilter = "" } else { databaseFilter = "" }
                            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Limpiar filtro")
                        }
                    }
                    .padding(7).background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                    if code {
                        Button(action: controller.projects.addFolders) { Image(systemName: "folder.badge.plus") }
                            .buttonStyle(.plain).help("Agregar subproyecto").accessibilityLabel("Agregar subproyecto")
                            .disabled(controller.isReadOnly || controller.isSwitchingWorkspace)
                    }
                }
            }
            .padding(12)
            Divider()
            ZStack {
                // Mantener el árbol montado preserva las expansiones y el scroll al cambiar de pestaña.
                codeContent.opacity(code ? 1 : 0).allowsHitTesting(code).accessibilityHidden(!code)
                DatabaseSidebar(controller: controller, filter: databaseFilter)
                    .opacity(code ? 0 : 1).allowsHitTesting(!code).accessibilityHidden(code)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.sidebar)
        .task(id: query + "|" + String(controller.session.revision)) { await filterFiles() }
    }

    private var codeContent: some View {
        ZStack {
            FileTree(workspace: workspace, workspaceURL: url, revision: controller.session.revision, controller: controller)
                .opacity(query.isEmpty ? 1 : 0).allowsHitTesting(query.isEmpty).accessibilityHidden(!query.isEmpty)
            if !query.isEmpty {
                results
            } else if workspace.projects.isEmpty {
                VStack(spacing: 12) {
                    Text("Todavía no hay subproyectos.").foregroundStyle(.secondary)
                    Button("Agregar carpeta…", action: controller.projects.addFolders).disabled(controller.isReadOnly)
                    Spacer()
                }.font(.callout).padding(.top, 24)
            }
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if searching {
                    ProgressView().controlSize(.small).padding()
                } else if let searchError {
                    Text(searchError).foregroundStyle(.secondary).padding()
                } else if search.matches.isEmpty {
                    Text("No se encontraron archivos.").foregroundStyle(.secondary).padding()
                }
                ForEach(controller.mountedProjects) { project in
                    let root = project.directory(relativeTo: url).resolvingSymlinksInPath().standardizedFileURL
                    let matches = search.matches.filter { $0.root == root }
                    if !matches.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matches) { match in
                                Button { if match.url.lastPathComponent.hasSuffix(".flow.json") { controller.openWorkflowFile(match.url) }
                                else { controller.files.open(match.url) } } label: {
                                    HStack(spacing: 8) {
                                        Image(nsImage: FileIcons.display(FileIcons.file(match.url),
                                                                         monochrome: workspace.codeIconMonochrome))
                                            .resizable().scaledToFit().frame(width: 18,
                                                                             height: 18)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(match.url.lastPathComponent).lineLimit(1)
                                            Text(match.path).font(.system(size: Theme.zoom(10))).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(match.url.path)
                            }
                        }
                        .background(Color(nsColor: FileIcons.groupTint(project) ?? .clear),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                    }
                }
                if search.truncated { Text("Hay más archivos. Refiná el filtro.").foregroundStyle(.secondary).padding() }
            }.font(.system(size: Theme.zoom(12)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private func filterFiles() async {
        search = SidebarFileSearch()
        searchError = nil
        searching = !query.isEmpty
        guard !query.isEmpty else { return }
        let text = query
        let roots = controller.mountedProjects.map { ($0.name, $0.directory(relativeTo: url)) }
        do {
            try await Task.sleep(for: .milliseconds(180))
            let task = Task.detached(priority: .userInitiated) { try SidebarFileSearch.find(text, roots: roots) }
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            search = result
            searching = false
        } catch is CancellationError {
            // La consulta nueva se encarga de actualizar la vista.
        } catch {
            guard !Task.isCancelled else { return }
            searchError = error.localizedDescription
            searching = false
        }
    }
}
