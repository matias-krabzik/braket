import SwiftUI
import UniformTypeIdentifiers

struct ProjectRail: View {
    let controller: WorkspaceController
    @State private var hoveredProject: URL?
    @State private var draggedProject: URL?
    @State private var showingActions = false
    @State private var pendingAction: ProjectAction?

    private enum ProjectAction { case create, open }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(controller.openWorkspaceURLs, id: \.self) { url in
                        ZStack(alignment: .topTrailing) {
                            projectButton(url)
                                .onDrag {
                                    draggedProject = url
                                    return NSItemProvider(item: Data(url.absoluteString.utf8) as NSData,
                                                          typeIdentifier: "com.krabzik.open-project")
                                }
                                .onDrop(of: [UTType(importedAs: "com.krabzik.open-project")],
                                        delegate: ProjectOrderDrop(target: url, controller: controller,
                                                                   dragged: $draggedProject))
                            if hoveredProject == url {
                                Button { controller.requestCloseWorkspace(url) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                        .frame(width: 20, height: 20)
                                        .background(Theme.sidebar, in: Circle())
                                        .overlay { Circle().strokeBorder(Theme.border) }
                                }
                                .buttonStyle(.plain)
                                .offset(x: 6, y: -6)
                                .help("Cerrar proyecto")
                                .accessibilityLabel("Cerrar " + url.deletingPathExtension().lastPathComponent)
                            }
                        }
                        .padding(6)
                        .onHover { hoveredProject = $0 ? url : nil }
                        .accessibilityAction(named: "Cerrar proyecto") { controller.requestCloseWorkspace(url) }
                    }
                }
                .padding(.vertical, 14)
            }
            Spacer(minLength: 12)
            Button { showingActions = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 42, height: 42)
                    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Crear o abrir un proyecto")
            .accessibilityLabel("Crear o abrir un proyecto")
            .padding(.bottom, 14)
        }
        .frame(width: 64)
        .background(Theme.bar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .disabled(controller.isSwitchingWorkspace)
        .sheet(isPresented: $showingActions, onDismiss: performPendingAction) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Agregar proyecto").font(.title2.weight(.semibold))
                Text("Creá un proyecto nuevo o abrí uno existente.").foregroundStyle(.secondary)
                VStack(spacing: 12) {
                    actionButton("Crear proyecto…", icon: "plus", action: .create)
                    actionButton("Abrir proyecto…", icon: "folder", action: .open)
                }
                HStack {
                    Spacer()
                    Button("Cancelar") { showingActions = false }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(28)
            .frame(width: 400)
            .background(Theme.background)
            .preferredColorScheme(.dark)
        }
    }

    private func projectButton(_ url: URL) -> some View {
        let model = controller.projectModel(for: url)
        let name = model?.name ?? url.deletingPathExtension().lastPathComponent
        let selected = controller.workspaceURL == url
        return Button { Task { await controller.openWorkspace(url) } } label: {
            ProjectIcon(name: name, style: model?.iconStyle ?? ProjectIconStyle(), selected: selected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name + "\n" + (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        .accessibilityLabel("Abrir " + name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func actionButton(_ title: String, icon: String, action: ProjectAction) -> some View {
        Button {
            pendingAction = action
            showingActions = false
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .buttonStyle(.bordered)
    }

    private func performPendingAction() {
        let action = pendingAction
        pendingAction = nil
        switch action {
        case .create: controller.createWorkspace()
        case .open: controller.chooseWorkspace()
        case nil: break
        }
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
