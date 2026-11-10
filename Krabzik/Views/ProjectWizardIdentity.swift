import AppKit
import SwiftUI

struct ProjectWizardIdentity: View {
    @Binding var draft: ProjectDraft
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
                    Text((draft.folder.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Elegir…", action: chooseLocation)
                }
                Text(draft.trimmedName.isEmpty ? "Se guardará un archivo .krabzik en esta carpeta." : draft.url.lastPathComponent)
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
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.title = "Ubicación del proyecto"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = draft.folder
        panel.prompt = "Elegir"
        if panel.runModal() == .OK, let url = panel.url { draft.folder = url }
    }
}
