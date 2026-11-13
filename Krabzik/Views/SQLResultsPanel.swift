import SwiftUI

struct SQLResultsPanel: View {
    @Bindable var execution: SQLExecution
    let controller: WorkspaceController
    let hide: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(execution.results.enumerated()), id: \.element.id) { index, result in
                            let draft = execution.draft(for: result)
                            HStack(spacing: 6) {
                                Button { execution.selectedResultID = result.id } label: {
                                    Label("Consulta \(index + 1)" + (draft.hasChanges ? " •" : ""), systemImage: "tablecells")
                                        .padding(.vertical, 8).padding(.leading, 10)
                                }.buttonStyle(.plain).help(result.sql)
                                Button {
                                    guard !draft.sending, draft.confirmDiscard() else { return }
                                    execution.results.removeAll { $0.id == result.id }
                                    execution.drafts.removeValue(forKey: result.id)
                                    if execution.selectedResultID == result.id { execution.selectedResultID = execution.results.last?.id }
                                } label: { Image(systemName: "xmark").font(.system(size: Theme.zoom(9))).padding(6) }
                                    .buttonStyle(.plain).help("Cerrar resultado")
                            }
                            .background(Theme.surfaceInk.opacity(execution.selectedResult?.id == result.id ? 0.1 : 0.025),
                                        in: RoundedRectangle(cornerRadius: 5))
                        }
                    }.padding(5)
                }.scrollIndicators(.hidden)
                if execution.isRunning { ProgressView().controlSize(.small) }
                Button(action: hide) { Image(systemName: "chevron.down") }.buttonStyle(.plain).padding(.horizontal, 12)
            }.font(.system(size: Theme.zoom(12))).background(Theme.bar)
            if let result = execution.selectedResult {
                SQLResultContent(draft: execution.draft(for: result), controller: controller).id(result.id)
            }
            if let error = execution.error {
                Text(error).font(.system(size: Theme.zoom(11))).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }.background(Theme.background)
    }
}

private struct SQLResultContent: View {
    @Bindable var draft: SQLResultDraft
    let controller: WorkspaceController
    private var schemaTable: SQLSchemaTable? {
        guard let connection = draft.result.connection, let origin = draft.result.origins.first else { return nil }
        return controller.database.schema.snapshot(connection)?.tables.first { $0.database == origin.database && $0.name == origin.table }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(draft.result.connection?.name ?? "").fontWeight(.medium)
                Text(draft.result.database).foregroundStyle(.secondary)
                Spacer()
                if draft.canInsert { Button("Agregar fila") { draft.addRow() } }
                if draft.hasChanges {
                    Button("Descartar") { if draft.confirmDiscard() { draft.discard() } }.disabled(draft.sending)
                    Button("Revisar cambios (⌘↩)") { draft.showingReview = true }.disabled(draft.sending)
                }
            }.font(.system(size: Theme.zoom(11))).padding(.horizontal, 12).padding(.vertical, 7)
            if draft.result.columns.isEmpty {
                Text(draft.result.error ?? draft.result.summary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            } else {
                SQLResultGrid(draft: draft, scale: controller.settings.uiScale, theme: controller.settings.theme)
            }
            HStack {
                Text(draft.result.summary)
                Spacer()
                Text(draft.reason.isEmpty ? "Doble clic: editar · Enter: guardar campo · ⌘Enter: revisar cambios" : draft.reason)
                    .lineLimit(1).help(draft.reason)
            }.font(.system(size: Theme.zoom(10))).foregroundStyle(.secondary).padding(8)
        }
        .onAppear { draft.configure(schemaTable) }
        .onChange(of: schemaTable) { _, table in draft.configure(table) }
        .sheet(isPresented: $draft.showingReview) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Revisar cambios antes de enviar").font(.headline)
                Text((draft.result.connection?.destination ?? "") + " · " + (draft.table?.qualified ?? ""))
                    .foregroundStyle(.secondary)
                Text("Se enviarán juntos en una transacción. Si una fila cambió o un valor falla, se revierten todos.")
                ScrollView([.horizontal, .vertical]) {
                    Text(preview).font(.system(size: Theme.zoom(12), design: .monospaced)).textSelection(.enabled).padding(12)
                }.background(Theme.bar)
                if let error = draft.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    if draft.sending { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancelar") { draft.showingReview = false }.keyboardShortcut(.cancelAction).disabled(draft.sending)
                    Button("Enviar cambios") { controller.database.submit(draft, profiles: controller.connections.profiles) }
                        .disabled(draft.sending || !draft.canEdit || !draft.hasChanges || controller.isReadOnly)
                }
            }.padding(24).frame(width: 820, height: 540).interactiveDismissDisabled(draft.sending)
        }
    }
    private var preview: String {
        do {
            return "START TRANSACTION;\n\n" + (try draft.mutations()).map { ($0.verificationSQL.map { $0 + ";\n" } ?? "") + $0.sql + ";" }
            .joined(separator: "\n\n") + "\n\nCOMMIT;" }
        catch { return MySQLClient.message(error) }
    }
}
