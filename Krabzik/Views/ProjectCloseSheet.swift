import SwiftUI

struct ProjectCloseSheet: View {
    @State private var closing: ProjectClosing
    @State private var started = false
    @State private var forceID: UUID?
    @State private var forceConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(controller: WorkspaceController, url: URL) {
        _closing = State(initialValue: ProjectClosing(controller: controller, url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(closing.phase == .confirmation ? "¿Cerrar \(closing.name)?" : "Cerrando \(closing.name)")
                .font(.title2.weight(.semibold))
            Text("Se detendrán los procesos de este proyecto. Los archivos se conservan y la app sigue abierta.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !closing.processes.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(closing.processes) { process in
                            processRow(process)
                            Divider()
                        }
                    }
                }
                .frame(height: min(CGFloat(closing.processes.count) * 54, 270))
            }
            if closing.phase == .stopping {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(closing
                        .canForce ? "Hay procesos que siguen activos. Podés esperar o forzar su detención." : "Deteniendo procesos…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if closing.phase == .failed { Text(closing.failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(started ? "Dejar abierto" : "Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(closing.phase == .closing)
                if !started {
                    Button(closing.hasActiveProcesses ? "Detener y cerrar" : "Cerrar proyecto") { started = true }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28).frame(width: 480)
        .background(Theme.background)
        .interactiveDismissDisabled(started)
        .task(id: started) {
            guard started else { return }
            await closing.confirm()
            if closing.phase == .closed || closing.phase == .cancelled { dismiss() }
        }
        .alert("¿Forzar la detención?", isPresented: $forceConfirmation, presenting: forceID) { id in
            Button("Cancelar", role: .cancel) { forceID = nil }
            Button("Forzar detención", role: .destructive) {
                closing.force(id)
                forceID = nil
            }
        } message: { _ in
            Text("El proceso y sus procesos hijos se terminarán inmediatamente. Puede perderse su trabajo pendiente.")
        }
    }

    private func processRow(_ process: CodeProject) -> some View {
        let run = closing.run(for: process.id)
        return HStack(spacing: 12) {
            Image(systemName: run?.status.active == true ? "circle.dotted" : "checkmark.circle")
                .foregroundStyle(run?.status.active == true ? Color.orange : Color.secondary)
            Text(process.name).lineLimit(1)
            Spacer()
            Text(run?.status.label ?? "Detenido").font(.callout).foregroundStyle(.secondary)
            if closing.canForce, run?.status.active == true {
                Button("Forzar…") {
                    forceID = process.id
                    forceConfirmation = true
                }.controlSize(.small)
            }
        }
        .frame(height: 53)
    }
}
