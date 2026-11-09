import SwiftUI

struct ProcessPanel: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Procesos").font(.system(size: 11, weight: .medium))
                Spacer()
                Button { controller.processesVisible = false } label: { Image(systemName: "chevron.down").font(.system(size: 10)) }
                    .buttonStyle(.plain).help("Ocultar procesos")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).frame(height: 32)
            .background(Theme.bar)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(controller.runnableProjects) { project in
                            if let run = controller.runner.runs[project.id] {
                                ProcessRow(project: project, run: run, selected: controller.selectedProject?.id == project.id,
                                           select: { controller.selectedProjectID = project.id },
                                           toggle: { controller.toggleRun(project) })
                                .contextMenu { Button("Comando…") { controller.commandProject = project } }
                            }
                        }
                    }.padding(7)
                }
                .frame(width: 210).background(Theme.bar)
                Rectangle().fill(Theme.border).frame(width: 1)
                if let project = controller.selectedProject, let run = controller.runner.runs[project.id] {
                    ConsoleView(run: run).id(project.id)
                } else { Theme.background }
            }
        }
        .background(Theme.background)
    }
}

private struct ProcessRow: View {
    let project: CodeProject
    let run: ProjectRun
    let selected: Bool
    let select: () -> Void
    let toggle: () -> Void

    private var color: Color {
        switch run.status {
        case .running: return Color(red: 0.43, green: 0.75, blue: 0.51)
        case .stopping: return .orange
        case .failed: return .red
        case .exited(let status) where status != 0: return .orange
        default: return .secondary.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(project.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: toggle) {
                Image(systemName: run.status.active ? "stop.fill" : "play.fill")
                    .font(.system(size: 10)).frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(run.status == .stopping)
            .help(run.status.active ? "Detener \(project.name)" : "Iniciar \(project.name)")
            .accessibilityLabel(run.status.active ? "Detener \(project.name)" : "Iniciar \(project.name)")
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(selected ? Theme.blue.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .help(run.status.label)
    }
}
