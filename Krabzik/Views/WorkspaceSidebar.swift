import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var controller: WorkspaceController
    let workspace: Workspace
    let url: URL
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(workspace.name).font(Theme.interfaceFont(13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(workspace.name)
                Spacer(minLength: 4)
                Menu {
                    Button("Agregar carpeta…", action: controller.projects.addFolders)
                    Button("Agregar archivo SQL…", action: controller.files.importScripts)
                    Button("Nuevo archivo") { controller.files.create() }
                    Button("Nueva imagen pixel art…") { controller.files.createPixelArt() }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Agregar archivos y carpetas").accessibilityLabel("Agregar archivos y carpetas")
                    .disabled(controller.isReadOnly || controller.isSwitchingWorkspace)
                Button { controller.showingProjectSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.fullArea)
                .help("Configuración del proyecto")
                .accessibilityLabel("Configuración del proyecto")
                .disabled(controller.isSwitchingWorkspace)
            }
            .padding(12)
            Divider()
            codeContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let operation = controller.fileOperation {
                Divider()
                HStack(spacing: 8) {
                    WorkspaceProgress().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(operation.action) · \(operation.completed) de \(operation.total)")
                        Text(operation.filename).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }.font(Theme.interfaceFont(12)).padding(12)
                    .accessibilityElement(children: .combine)
            }
        }
        .background(Theme.sidebar)
        .qaScreen("explorer.files")
    }

    private var codeContent: some View {
        ZStack {
            FileTree(workspace: workspace, workspaceURL: url, revision: controller.session.revision, controller: controller)
            if workspace.projects.isEmpty && controller.files.standaloneScripts.isEmpty {
                VStack(spacing: 12) {
                    Text("Agregá archivos y carpetas a tu proyecto.").foregroundStyle(.secondary)
                    Button("Agregar carpeta…", action: controller.projects.addFolders).disabled(controller.isReadOnly)
                    Spacer()
                }.font(.callout).padding(.top, 24)
            }
        }
    }

}
