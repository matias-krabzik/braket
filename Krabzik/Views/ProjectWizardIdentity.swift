import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectWizardIdentity: View {
    @Binding var draft: ProjectDraft
    @State private var choosingLocation = false
    private let presets = ["687080", "4589E8", "8863D7", "D662AD", "DB8746", "4B9F83"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                ProjectIcon(name: draft.name, style: draft.icon, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nombre").font(.callout)
                    TextField("Mi proyecto", text: $draft.name).textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Ubicación").font(.callout)
                HStack {
                    Text((draft.location.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Elegir…") { choosingLocation = true }
                }
                if !draft.usesDefaultLocation {
                    Button("Usar BraketProjects") { draft.useDefaultLocation() }
                } else {
                    Text("La carpeta se creará automáticamente, organizada por año.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Nombre de la carpeta").font(.callout)
                TextField("Nombre de la carpeta", text: $draft.folderName).textFieldStyle(.roundedBorder)
                Text((draft.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary)
                if !draft.name.isEmpty, let message = draft.validationMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            Divider()
            Text("Icono").font(.headline)
            ProjectIconLettersField(letters: $draft.icon.letters)
            HStack(spacing: 12) {
                Text("Tonos")
                Spacer()
                ForEach(presets, id: \.self) { hex in
                    Button { draft.icon.hex = hex } label: {
                        Circle().fill(ProjectIconStyle(hex: hex).color).frame(width: 24, height: 24)
                            .overlay { Circle().strokeBorder(.white.opacity(draft.icon.hex == hex ? 0.9 : 0), lineWidth: 2) }
                    }
                    .buttonStyle(.plain).accessibilityLabel("Color " + hex)
                }
            }
            ColorPicker("Color personalizado", selection: Binding(get: { draft.icon.color }, set: { draft.icon.setColor($0) }),
                        supportsOpacity: false)
            Toggle("Efecto glass", isOn: $draft.icon.glass)
            Text("Podés crear ahora o continuar para agregar subproyectos y revisar el resumen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosingLocation, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { draft.location = url }
        }
    }

}
