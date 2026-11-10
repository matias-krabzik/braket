import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SubprojectIconEditor: View {
    @Binding var project: CodeProject
    let workspaceURL: URL
    let monochrome: Bool
    @State private var automaticImage: NSImage?
    @State private var error: String?

    private var options: Binding<CodeProjectIcon> {
        Binding(get: { project.icon ?? CodeProjectIcon() }, set: { project.icon = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Image(nsImage: FileIcons.project(project, automatic: automaticImage, monochrome: monochrome))
                    .resizable().scaledToFit().frame(width: 38, height: 38)
                    .padding(12)
                    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Icono", selection: options.source) {
                        ForEach(CodeProjectIcon.Source.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Apariencia", selection: options.rendering) {
                        ForEach(CodeProjectIcon.Rendering.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            switch options.wrappedValue.source {
            case .automatic:
                Text("Usa el favicon local; si no hay uno válido, el logo de la tecnología.")
                    .font(.caption).foregroundStyle(.secondary)
            case .technology:
                Picker("Logo", selection: options.asset) {
                    ForEach(CodeProjectIcon.assets, id: \.self) { name in Text(name).tag(name) }
                }
            case .image:
                Button("Elegir imagen…", action: chooseImage)
                Text("Se guarda una copia dentro del proyecto. PNG, JPEG, ICO o SVG, hasta 1 MB.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SubprojectIconTintEditor(options: options)
            if options.wrappedValue.tintHex != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label(project.name, systemImage: "folder")
                    Label("archivo de ejemplo", systemImage: "doc").padding(.leading, 18)
                }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color(nsColor: FileIcons.groupTint(project) ?? .clear), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Vista previa del bloque del subproyecto")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: project.path + project.kind.rawValue) {
            let directory = project.directory(relativeTo: workspaceURL), kind = project.kind
            let files = await Task.detached(priority: .utility) { ProjectIconFiles.read(at: directory, kind: kind) }.value
            guard !Task.isCancelled else { return }
            automaticImage = files.favicons.lazy.compactMap { FileIcons.favicon($0) }.first
                ?? files.technology.flatMap { FileIcons.asset($0) }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .ico, .svg]
        panel.prompt = "Usar imagen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var updated = options.wrappedValue
            updated.imageData = try FileIcons.importedImage(url)
            project.icon = updated
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
