import AppKit
import SwiftUI

struct ProjectWizard: View {
    let controller: WorkspaceController
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProjectDraft()
    @State private var step = 0
    @State private var busy = false
    @State private var detecting = false
    @State private var error: String?
    @State private var dropTarget = false
    private let steps = ["Proyecto", "Subproyectos", "Resumen"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                navigation
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ScrollView {
                        Group {
                            switch step {
                            case 0: ProjectWizardIdentity(draft: $draft)
                            case 1: subprojects
                            default: summary
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(26)
            }
            Divider()
            footer.padding(18)
        }
        .frame(width: 780, height: 570)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .disabled(busy)
        .interactiveDismissDisabled(busy || detecting)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nuevo proyecto").font(.headline).padding(.bottom, 16)
            ForEach(steps.indices, id: \.self) { index in
                Button {
                    error = nil
                    step = index
                } label: {
                    HStack(spacing: 10) {
                        Text(index < step ? "✓" : String(index + 1))
                            .frame(width: 25, height: 25)
                            .background(.white.opacity(0.08), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(steps[index]).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.85)
                            if index > 0 { Text("Opcional").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(index == step ? Theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(detecting || (index > 0 && draft.validationMessage != nil))
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 180)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(["Creá tu proyecto", "Agregá tus subproyectos", "Todo listo para crear"][step])
                .font(.title2.weight(.semibold))
            Text(["Elegí un nombre y dónde guardarlo.",
                  "Arrastrá carpetas o elegilas desde tu Mac.",
                  "Revisá los datos de tu proyecto."][step])
                .foregroundStyle(.secondary)
        }
    }

    private var subprojects: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(detecting ? "Detectando tecnologías…" : "Soltá carpetas acá", systemImage: "folder.badge.plus")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Agregar carpetas…") { addFolders(WorkspacePrompts.chooseFolders()) }.disabled(detecting)
            }
            .padding(16)
            .background(dropTarget ? Theme.accent.opacity(0.12) : .clear)
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, style: StrokeStyle(dash: [5])) }
            .dropDestination(for: URL.self) { urls, _ in
                guard !detecting else { return false }
                addFolders(urls)
                return true
            } isTargeted: { dropTarget = $0 }
            if draft.projects.isEmpty {
                Text("Podés crear el proyecto vacío y agregar carpetas después.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach($draft.projects) { $project in
                ProjectWizardSubproject(project: $project) {
                    draft.projects.removeAll { $0.id == project.id }
                }
            }
            if !draft.projects.isEmpty {
                Text("Podés corregir la tecnología y el comando. Los archivos permanecen en sus carpetas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                ProjectIcon(name: draft.trimmedName, style: draft.icon, size: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Text(draft.trimmedName).font(.title3.weight(.semibold))
                    Text(draft.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Divider()
            Text("Subproyectos · \(draft.projects.count)").font(.headline)
            if draft.projects.isEmpty { Text("Sin subproyectos. Podés agregarlos después.").foregroundStyle(.secondary) }
            ForEach(draft.projects) { project in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                        Text(project.command.isEmpty ? "Sin comando de inicio" : project.command)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(project.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("Abrir el proyecto al terminar", isOn: $draft.openWhenCreated)
            Text("Los procesos se iniciarán cuando vos lo elijas.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(detecting)
            Spacer()
            if detecting || busy { ProgressView().controlSize(.small) }
            if step > 0 {
                Button("Atrás") { error = nil
                step -= 1 }.disabled(detecting)
            }
            if step < 2 {
                Button(step == 0 ? "Continuar" : "Ver resumen") { error = nil
                step += 1 }
                    .disabled(draft.validationMessage != nil || detecting)
            }
            Button(step < 2 ? "Crear ahora" : "Crear proyecto", action: create)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validationMessage != nil || detecting)
        }
    }

    private func addFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        detecting = true
        error = nil
        Task {
            defer { detecting = false }
            do {
                let detected = try await Task.detached(priority: .userInitiated) { try ProjectDraft.detect(urls) }.value
                let existing = Set(draft.projects.map(\.path))
                let additions = detected.filter { !existing.contains($0.path) }
                guard draft.projects.count + additions.count <= WorkspaceLimits.projects else {
                    throw ProjectDraftError.invalid("Podés agregar hasta \(WorkspaceLimits.projects) subproyectos.")
                }
                draft.projects.append(contentsOf: additions)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func create() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                if try await controller.createWorkspace(from: draft) { dismiss() }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ProjectWizardSubproject: View {
    @Binding var project: CodeProject
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(project.name).fontWeight(.medium)
                Spacer()
                Picker("Tecnología", selection: $project.kind) {
                    ForEach(ProjectKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 115)
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Quitar " + project.name)
            }
            Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            TextField("Comando de inicio (opcional)", text: $project.command)
                .textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
        }
        .padding(14)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
    }
}
