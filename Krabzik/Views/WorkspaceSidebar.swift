import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var controller: WorkspaceController
    let workspace: Workspace
    let url: URL
    @State private var codeFilter = ""
    @State private var search = SidebarFileSearch()
    @State private var searching = false
    @State private var searchError: String?

    private var query: String { codeFilter.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(workspace.name).font(.system(size: Theme.zoom(13), weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(workspace.name)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filtrar archivos", text: $codeFilter)
                            .textFieldStyle(.plain).font(.system(size: Theme.zoom(11)))
                        if !codeFilter.isEmpty {
                            Button {
                                codeFilter = ""
                            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Limpiar filtro")
                        }
                    }
                    .padding(7).background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                    Menu {
                        Button("Agregar carpeta…", action: controller.projects.addFolders)
                        Button("Agregar archivo SQL…", action: controller.files.importScripts)
                        Button("Nuevo archivo SQL…") { controller.files.create() }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Agregar archivos y carpetas").accessibilityLabel("Agregar archivos y carpetas")
                        .disabled(controller.isReadOnly || controller.isSwitchingWorkspace)
                }
            }
            .padding(12)
            Divider()
            codeContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Button { controller.database.showingConnections = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Conexiones")
                    Spacer()
                    let count = controller.database.states.values.filter { $0.status == .connected }.count
                    if count > 0 {
                        Text("\(count) abiertas").foregroundStyle(.green)
                    }
                    Image(systemName: "chevron.right").font(.caption2)
                }.font(.system(size: Theme.zoom(11))).padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Configurar conexiones globales")

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
            } else if workspace.projects.isEmpty && controller.files.standaloneScripts.isEmpty {
                VStack(spacing: 12) {
                    Text("Agregá archivos y carpetas a tu proyecto.").foregroundStyle(.secondary)
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
                } else if search.matches.isEmpty && !controller.files.standaloneScripts.contains(where: {
                    $0.lastPathComponent.localizedStandardContains(query)
                }) {
                    Text("No se encontraron archivos.").foregroundStyle(.secondary).padding()
                }
                ForEach(controller.files.standaloneScripts.filter {
                    $0.lastPathComponent.localizedStandardContains(query)
                }, id: \.self) { script in
                    Button { controller.files.open(script) } label: {
                        Label(script.lastPathComponent, systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(script.path)
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
