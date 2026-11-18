import SwiftUI
import UniformTypeIdentifiers

struct ProjectPicker: View {
    let controller: WorkspaceController
    @State private var presented = false

    var body: some View {
        if let project = controller.workspace {
            Button { presented.toggle() } label: {
                HStack(spacing: 7) {
                    ProjectIcon(name: project.name, style: project.iconStyle, size: 20)
                    Text(project.name).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .font(Theme.interfaceFont())
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(.primary.opacity(0.09), in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.border) }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(controller.isSwitchingWorkspace)
            .help("Cambiar de proyecto")
            .accessibilityLabel("Selector de proyectos")
            .accessibilityValue(project.name)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ProjectPickerMenu(controller: controller) { presented = false }
            }
        }
    }
}

private struct ProjectPickerMenu: View {
    let controller: WorkspaceController
    let dismiss: () -> Void
    @State private var query = ""
    @State private var models: [URL: Workspace] = [:]
    @State private var draggedProject: URL?
    @FocusState private var searching: Bool

    private var projects: [URL] {
        let open = Set(controller.openWorkspaceURLs)
        return controller.openWorkspaceURLs + controller.recentProjects.filter { !open.contains($0) }
    }

    private var rowHeight: CGFloat { max(27, Theme.zoom(27)) }

    private func model(_ url: URL) -> Workspace? {
        controller.projectModel(for: url) ?? models[url]
    }

    private func name(_ url: URL) -> String {
        model(url)?.name ?? url.deletingPathExtension().lastPathComponent
    }

    private func matching(_ urls: [URL]) -> [URL] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return urls.filter { term.isEmpty || name($0).localizedStandardContains(term) || $0.path.localizedStandardContains(term) }
    }

    var body: some View {
        let recent = matching(Array(controller.recentProjects.prefix(3)))
        let all = matching(projects)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar proyecto…", text: $query)
                    .textFieldStyle(.plain).focused($searching)
                    .onSubmit { if let first = (recent.first ?? all.first) { select(first) } }
            }
            .padding(7)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            if !recent.isEmpty {
                heading("Recientes")
                VStack(spacing: 0) {
                    ForEach(recent, id: \.self) { url in row(url) }
                }
                Divider()
            }
            heading("Todos")
            if all.isEmpty {
                Text("Sin coincidencias").foregroundStyle(.secondary).padding(6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(all, id: \.self) { url in
                            if controller.openWorkspaceURLs.contains(url) {
                                row(url)
                                    .onDrag {
                                        draggedProject = url
                                        return NSItemProvider(item: Data(url.absoluteString.utf8) as NSData,
                                                              typeIdentifier: "com.krabzik.open-project")
                                    }
                                    .onDrop(of: [UTType(importedAs: "com.krabzik.open-project")],
                                            delegate: ProjectOrderDrop(target: url, controller: controller,
                                                                       dragged: $draggedProject))
                            } else { row(url) }
                        }
                    }
                }
                .frame(height: rowHeight * CGFloat(min(4, all.count)))
            }
            Divider()
            action("Crear proyecto…", icon: "plus.square", perform: controller.createWorkspace)
            action("Abrir proyecto…", icon: "folder", perform: controller.chooseWorkspace)
        }
        .font(Theme.interfaceFont())
        .padding(10)
        .frame(width: max(225, Theme.zoom(225)))
        .preferredColorScheme(Theme.colorScheme)
        .onAppear { searching = true }
        .task(id: controller.recentProjects) {
            for url in controller.recentProjects where controller.projectModel(for: url) == nil {
                let loaded = await Task.detached(priority: .utility) { try? Workspace.read(from: url) }.value
                guard !Task.isCancelled else { return }
                models[url] = loaded
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 5)
    }

    private func select(_ url: URL) {
        dismiss()
        if controller.workspaceURL != url { Task { await controller.openWorkspace(url) } }
    }

    private func row(_ url: URL) -> some View {
        let selected = url == controller.workspaceURL
        return Button { select(url) } label: {
            HStack(spacing: 8) {
                ProjectIcon(name: name(url), style: model(url)?.iconStyle ?? ProjectIconStyle(), size: 17)
                Text(name(url)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.caption) }
            }
            .padding(.horizontal, 6)
            .frame(height: rowHeight)
            .background(.primary.opacity(selected ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if controller.openWorkspaceURLs.contains(url) {
                Button("Cerrar proyecto") { dismiss(); controller.requestCloseWorkspace(url) }
            }
        }
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.async { perform() }
        } label: {
            Label(title, systemImage: icon)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct ProjectOrderDrop: DropDelegate {
    let target: URL
    let controller: WorkspaceController
    @Binding var dragged: URL?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged else { return false }
        controller.moveOpenWorkspace(dragged, to: target)
        self.dragged = nil
        return true
    }
}
