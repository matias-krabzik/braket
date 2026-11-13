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
                                    HStack(spacing: 6) {
                                        if result.isLoading { ProgressView().controlSize(.mini) }
                                        else { Image(systemName: "tablecells") }
                                        Text("Consulta \(index + 1)" + (draft.hasChanges ? " •" : ""))
                                    }.padding(.vertical, 8).padding(.leading, 10)
                                }.buttonStyle(.plain).help(result.sql)
                                Button {
                                    if execution.pinned.contains(result.id) { execution.pinned.remove(result.id) }
                                    else { execution.pinned.insert(result.id) }
                                } label: {
                                    Image(systemName: execution.pinned.contains(result.id) ? "pin.fill" : "pin")
                                        .foregroundStyle(execution.pinned.contains(result.id) ? Theme.accent : .secondary)
                                        .padding(5)
                                }.buttonStyle(.plain).disabled(result.isLoading)
                                    .help(execution.pinned
                                        .contains(result.id) ? "Desfijar pestaña" : "Fijar pestaña: conservar este resultado")
                                    .accessibilityLabel(execution.pinned.contains(result.id) ? "Desfijar pestaña" : "Fijar pestaña")
                                Button {
                                    guard !draft.sending, draft.confirmDiscard() else { return }
                                    execution.results.removeAll { $0.id == result.id }
                                    execution.drafts.removeValue(forKey: result.id)
                                    execution.pinned.remove(result.id)
                                    if execution.selectedResultID == result.id { execution.selectedResultID = execution.results.last?.id }
                                } label: { Image(systemName: "xmark").font(.system(size: Theme.zoom(9))).padding(6) }
                                    .buttonStyle(.plain).help("Cerrar resultado").disabled(result.isLoading)
                            }
                            .background(Theme.surfaceInk.opacity(execution.selectedResult?.id == result.id ? 0.1 : 0.025),
                                        in: RoundedRectangle(cornerRadius: 5))
                        }
                    }.padding(5)
                }.scrollIndicators(.hidden)
                SQLTimeoutControl(execution: execution)
                Button(action: hide) { Image(systemName: "chevron.down") }.buttonStyle(.plain).padding(.horizontal, 12)
            }.font(.system(size: Theme.zoom(12))).background(Theme.bar)
            if let result = execution.selectedResult {
                if result.isLoading {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        Text("Ejecutando consulta…").font(.system(size: Theme.zoom(13)))
                        Text("Límite: \(execution.timeoutSeconds) segundos").foregroundStyle(.secondary)
                        Button("Cancelar") { controller.database.cancel(execution) }.disabled(execution.isCancelling)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SQLResultToolbar(execution: execution, draft: execution.draft(for: result), controller: controller)
                    SQLResultContent(draft: execution.draft(for: result), controller: controller).id(result.id)
                }
            }
            if let error = execution.error, error != execution.selectedResult?.error {
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
                if let connection = draft.result.connection, draft.result.origins.contains(where: { !$0.table.isEmpty }),
                   !draft.canEdit, !draft.sent {
                    if controller.database.schema.loading.contains(connection.id) {
                        ProgressView().controlSize(.mini)
                        Text("Cargando estructura…").foregroundStyle(.secondary)
                    } else {
                        Button("Cargar estructura") {
                            let store = controller.database.schema
                            let origin = draft.result.origins.first?.database ?? ""
                            Task {
                                await store.discover(connection, client: controller.database.client,
                                                     choose: !store.preference(connection).visible.contains(origin))
                            }
                        }.disabled(controller.isReadOnly)
                    }
                }
            }.font(.system(size: Theme.zoom(11))).padding(.horizontal, 12).padding(.vertical, 7)
            if draft.result.columns.isEmpty {
                Text(draft.result.error ?? draft.result.summary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            } else {
                SQLResultGrid(draft: draft, scale: controller.settings.uiScale, theme: controller.settings.theme)
            }
            if let connection = draft.result.connection, let error = controller.database.schema.errors[connection.id] {
                Text("Estructura: " + error).font(.system(size: Theme.zoom(11))).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            HStack {
                if draft.result.error == nil { Text(draft.result.summary) }
                Spacer()
                Text(draft.result.error != nil ? "" : draft.reason
                    .isEmpty ? "Doble clic: editar · Enter: guardar campo · ⌘Enter: revisar cambios" : draft.reason)
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

struct SQLTimeoutControl: View {
    @Bindable var execution: SQLExecution
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
            TextField("Timeout", value: $execution.timeoutSeconds, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: Theme.zoom(48))
                .accessibilityLabel("Timeout de consulta en segundos")
            Text("s")
        }
        .font(.system(size: Theme.zoom(11)))
        .disabled(execution.isRunning)
        .help("Tiempo máximo por sentencia (1–3600 segundos). Cambialo y pulsá Reintentar.")
    }
}

private struct SQLResultToolbar: View {
    @Bindable var execution: SQLExecution
    @Bindable var draft: SQLResultDraft
    let controller: WorkspaceController
    private var result: SQLResult { draft.result }
    private var busy: Bool {
        execution.isRunning || draft.sending || controller.isReadOnly
            || result.connection.map { controller.database.state($0.id).busy } == true
    }

    private func run(page: Int? = nil) {
        guard let document = controller.selectedDocument, let connection = result.connection else { return }
        controller.database.execute(document, connection: connection, queryOverride: result.sql, databaseOverride: result.database,
                                    pageIndex: page ?? 0, targetResultID: page == nil ? nil : result.id)
    }

    var body: some View {
        HStack(spacing: 6) {
            action("Actualizar", icon: "arrow.clockwise", enabled: !busy && result.connection != nil) { run() }
            Divider().frame(height: Theme.zoom(18))
            action("Agregar fila", icon: "plus", enabled: !busy && draft.canInsert) { draft.addRow() }
            action("Eliminar fila seleccionada", icon: "minus", enabled: !busy && draft.canDeleteSelected) {
                if let cell = draft.selectedCell { draft.deleteRow(cell.row) }
            }
            action("Restablecer campo seleccionado", icon: "arrow.uturn.backward", enabled: !busy && draft.canResetSelected) {
                draft.resetSelected()
            }
            action("Guardar cambios", icon: "square.and.arrow.down",
                   enabled: !busy && draft.canEdit && draft.hasChanges && !draft.isEditingCell) { draft.showingReview = true }
            Spacer(minLength: 6)
            if !result.columns.isEmpty {
                if let page = result.page {
                    Text("100 filas · \(page.index + 1) de \(page.count.map(String.init) ?? "?")")
                        .help(page.totalRows
                            .map { "\($0) filas en total" } ?? "Total no disponible; podés navegar mientras haya más filas.")
                    action("Página anterior", icon: "chevron.left", enabled: !busy && page.index > 0) { run(page: page.index - 1) }
                    action("Página siguiente", icon: "chevron.right", enabled: !busy && page.hasNext) { run(page: page.index + 1) }
                } else {
                    Text("\(result.rowCount) filas · 1 de 1").help("Se respeta el límite definido en tu consulta.")
                    action("Página anterior", icon: "chevron.left", enabled: false) {}
                    action("Página siguiente", icon: "chevron.right", enabled: false) {}
                }
            }
        }
        .font(.system(size: Theme.zoom(11)))
        .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.bar)
    }

    private func action(_ title: String, icon: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon).font(.system(size: Theme.zoom(14)))
                .frame(width: Theme.zoom(26), height: Theme.zoom(24)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).help(title).accessibilityLabel(title)
    }
}
