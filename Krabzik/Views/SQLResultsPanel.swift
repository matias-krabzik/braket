import SwiftUI

struct SQLResultsPanel: View {
    @Bindable var execution: SQLExecution
    let controller: WorkspaceController
    let hide: () -> Void
    private var showingLogs: Bool { controller.outputVisible }

    private func selectResult(_ result: SQLResult) {
        controller.outputVisible = false
        execution.selectedResultID = result.id
    }

    private func closeResult(_ result: SQLResult) {
        let draft = execution.draft(for: result)
        guard !draft.sending, draft.confirmDiscard() else { return }
        execution.results.removeAll { $0.id == result.id }
        execution.drafts.removeValue(forKey: result.id)
        execution.pinned.remove(result.id)
        if execution.selectedResultID == result.id { execution.selectedResultID = execution.results.last?.id }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        Button(action: controller.showOutput) {
                            Label("Logs", systemImage: "text.alignleft")
                                .padding(.vertical, 8).padding(.horizontal, 10)
                        }
                        .buttonStyle(.plain)
                        .background(Theme.surfaceInk.opacity(showingLogs ? 0.1 : 0.025),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityAddTraits(showingLogs ? .isSelected : [])
                        .help("Historial SQL del proyecto")
                        .qaControl("sql.logs.tab", title: "Logs", action: controller.showOutput)
                        ForEach(Array(execution.results.enumerated()), id: \.element.id) { index, result in
                            let draft = execution.draft(for: result)
                            HStack(spacing: 6) {
                                Button { selectResult(result) } label: {
                                    HStack(spacing: 6) {
                                        if result.isLoading { ProgressView().controlSize(.mini) }
                                        else { Image(systemName: "tablecells") }
                                        Text("Consulta \(index + 1)" + (draft.hasChanges ? " •" : ""))
                                    }.padding(.vertical, 8).padding(.leading, 10)
                                }.buttonStyle(.plain)
                                    .help("Consulta \(index + 1) · \(result.connection?.name ?? "Sin conexión") · "
                                          + "\(result.database)\n\(result.sql)")
                                Button {
                                    if execution.pinned.contains(result.id) { execution.pinned.remove(result.id) }
                                    else { execution.pinned.insert(result.id) }
                                } label: {
                                    Image(systemName: execution.pinned.contains(result.id) ? "pin.fill" : "pin")
                                        .foregroundStyle(execution.pinned.contains(result.id) ? Theme.accent : .secondary)
                                        .frame(width: Theme.zoom(28), height: Theme.zoom(28))
                                }.buttonStyle(.plain).disabled(result.isLoading)
                                    .help(execution.pinned
                                        .contains(result.id) ? "Desfijar pestaña" : "Fijar pestaña: conservar este resultado")
                                    .accessibilityLabel(execution.pinned.contains(result.id) ? "Desfijar pestaña" : "Fijar pestaña")
                                Button {
                                    closeResult(result)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: Theme.zoom(9)))
                                        .frame(width: Theme.zoom(28), height: Theme.zoom(28))
                                        .contentShape(Rectangle())
                                }
                                    .buttonStyle(.plain).help("Cerrar resultado: Consulta \(index + 1)")
                                    .disabled(result.isLoading)
                                    .qaControl("sql.result.close.\(index)", title: "Cerrar resultado",
                                               enabled: !result.isLoading) { closeResult(result) }
                            }
                            .background(Theme.surfaceInk.opacity(!showingLogs && execution.selectedResult?.id == result.id ? 0.1 : 0.025),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .qaControl("sql.result.tab.\(index)", title: "Consulta \(index + 1)",
                                       enabled: !result.isLoading) { selectResult(result) }
                        }
                    }.padding(5)
                }.scrollIndicators(.hidden)
                if !showingLogs { SQLTimeoutControl(execution: execution) }
                Button(action: hide) { Image(systemName: "chevron.down") }.buttonStyle(.plain)
                    .padding(.horizontal, 12).help("Ocultar resultados").accessibilityLabel("Ocultar resultados")
            }.font(Theme.interfaceFont(13)).background(Theme.bar).qaScreen("sql.results")
            if showingLogs {
                SQLOutputView(output: controller.database.output).id(controller.workspaceURL)
            } else if let result = execution.selectedResult {
                if result.isLoading {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        Text("Ejecutando consulta…").font(Theme.interfaceFont(13))
                        Text("Límite: \(execution.timeoutSeconds) segundos").foregroundStyle(.secondary)
                        Button("Cancelar") { controller.database.cancel(execution) }.disabled(execution.isCancelling)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SQLResultToolbar(execution: execution, draft: execution.draft(for: result), controller: controller)
                    SQLResultContent(draft: execution.draft(for: result), controller: controller).id(result.id)
                }
            } else {
                Text("Todavía no hay resultados. Ejecutá una consulta para verlos aquí.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = execution.error, error != execution.selectedResult?.error {
                Text(error).font(Theme.interfaceFont(12)).foregroundStyle(.orange).textSelection(.enabled)
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
            if draft.result.columns.isEmpty {
                Text(draft.result.error ?? draft.result.summary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            } else {
                SQLResultGrid(draft: draft, scale: controller.settings.resultFontScale, theme: controller.settings.theme)
            }
            if let connection = draft.result.connection, let error = controller.database.schema.errors[connection.id] {
                Text("Estructura: " + error).font(Theme.interfaceFont(12)).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                    .qaLabel("sql.result.schemaError", error)
            }
            if let error = draft.result.error {
                Text(error).font(Theme.interfaceFont(12)).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
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
                    Text(preview).font(Theme.codeFont()).textSelection(.enabled).padding(12)
                }.background(Theme.bar)
                if let error = draft.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    if draft.sending { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancelar") { draft.showingReview = false }.keyboardShortcut(.cancelAction).disabled(draft.sending)
                        .qaControl("grid.review.cancel", title: "Cancelar", enabled: !draft.sending) {
                            draft.showingReview = false
                        }
                    let canSubmit = !draft.sending && draft.canEdit && draft.hasChanges && !controller.isReadOnly
                    Button("Enviar cambios") { submit() }
                        .disabled(!canSubmit)
                        .qaControl("grid.review.submit", title: "Enviar cambios", enabled: canSubmit, action: submit)
                }
            }.padding(24).frame(width: 820, height: 540).interactiveDismissDisabled(draft.sending)
                .qaScreen("grid.review")
        }
    }
    private func submit() {
        controller.database.submit(draft, profiles: controller.connections.profiles)
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
    @State private var showingEditor = false
    @State private var editorIdentity = UUID()

    var body: some View {
        Button {
            editorIdentity = UUID()
            showingEditor = true
        } label: {
            HStack(spacing: Theme.zoom(5)) {
                Image(systemName: "timer")
                Text("\(execution.timeoutSeconds) s")
                Image(systemName: "chevron.down")
                    .font(.system(size: Theme.zoom(9)))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .font(Theme.interfaceFont(12))
        .disabled(execution.isRunning)
        .help("Ajustar tiempo máximo por sentencia (1–3600 segundos)")
        .accessibilityLabel("Tiempo máximo por sentencia: \(execution.timeoutSeconds) segundos")
        .popover(isPresented: $showingEditor, arrowEdge: .bottom) {
            SQLTimeoutEditor(initialSeconds: execution.timeoutSeconds,
                             onSave: { execution.timeoutSeconds = $0
                             showingEditor = false },
                             onCancel: { showingEditor = false })
                .id(editorIdentity)
        }
    }
}

private struct SQLTimeoutEditor: View {
    let onSave: (Int) -> Void
    let onCancel: () -> Void
    @State private var proposedSeconds: String

    init(initialSeconds: Int, onSave: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _proposedSeconds = State(initialValue: String(initialSeconds))
    }

    private var validSeconds: Int? {
        guard let seconds = Int(proposedSeconds), (1...3600).contains(seconds) else { return nil }
        return seconds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tiempo máximo por sentencia")
                .font(Theme.interfaceFont(13, weight: .semibold))
            HStack(spacing: 8) {
                TextField("Segundos", text: $proposedSeconds)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Theme.zoom(76))
                    .accessibilityLabel("Tiempo máximo en segundos")
                    .onSubmit(apply)
                Text("segundos").foregroundStyle(.secondary)
            }
            Text("Entre 1 y 3600 segundos.")
                .font(Theme.interfaceFont(11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel)
                Button("Guardar", action: apply)
                    .disabled(validSeconds == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.zoom(16))
        .frame(width: Theme.zoom(250))
    }

    private func apply() {
        guard let seconds = validSeconds else { return }
        onSave(seconds)
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
        guard let document = controller.sqlResultsDocument, let connection = result.connection else { return }
        controller.database.execute(document, connection: connection, queryOverride: result.sql, databaseOverride: result.database,
                                    pageIndex: page ?? 0, targetResultID: page == nil ? nil : result.id,
                                    startingLineOverride: result.line)
    }

    var body: some View {
        HStack(spacing: 6) {
            action("Actualizar", icon: "arrow.clockwise", enabled: !busy && result.connection != nil,
                   id: "grid.refresh") { run() }
            Divider().frame(height: Theme.zoom(18))
            action("Agregar fila", icon: "plus", enabled: !busy && draft.canInsert,
                   id: "grid.addRow") { draft.addRow() }
            action("Eliminar fila seleccionada", icon: "minus", enabled: !busy && draft.canDeleteSelected,
                   id: "grid.deleteRow") {
                if let cell = draft.selectedCell { draft.deleteRow(cell.row) }
            }
            action("Restablecer campo seleccionado", icon: "arrow.uturn.backward",
                   enabled: !busy && draft.canResetSelected, id: "grid.reset") {
                draft.resetSelected()
            }
            action("Guardar cambios", icon: "floppy",
                   enabled: !busy && draft.canEdit && draft.hasChanges && !draft.isEditingCell,
                   id: "grid.save") { draft.showingReview = true }
            if let connection = result.connection, result.origins.contains(where: { !$0.table.isEmpty }),
               !draft.canEdit, !draft.sent {
                if controller.database.schema.loading.contains(connection.id) {
                    ProgressView().controlSize(.mini).help("Cargando estructura…")
                } else {
                    action("Cargar estructura", icon: "arrow.down.doc", enabled: !controller.isReadOnly,
                           id: "grid.loadSchema") {
                        let store = controller.database.schema
                        let origin = result.origins.first?.database ?? ""
                        Task { await store.discover(connection, client: controller.database.client,
                                                    choose: !store.preference(connection).visible.contains(origin)) }
                    }
                }
            }
            Spacer(minLength: 6)
            Text("\(Int(result.elapsed * 1000)) ms").help("Tiempo de ejecución de este resultado")
            if !result.columns.isEmpty {
                if let page = result.page {
                    Text("\(result.rows.count) filas · \(page.index + 1) de \(page.count.map(String.init) ?? "?")")
                        .help(page.totalRows
                            .map { "\($0) filas en total" } ?? "Total no disponible; podés navegar mientras haya más filas.")
                    action("Página anterior", icon: "chevron.left", enabled: !busy && page.index > 0,
                           id: "grid.page.previous") { run(page: page.index - 1) }
                    action("Página siguiente", icon: "chevron.right", enabled: !busy && page.hasNext,
                           id: "grid.page.next") { run(page: page.index + 1) }
                } else {
                    Text("\(result.rowCount) filas · 1 de 1").help("Se respeta el límite definido en tu consulta.")
                    action("Página anterior", icon: "chevron.left", enabled: false, id: "grid.page.previous") {}
                    action("Página siguiente", icon: "chevron.right", enabled: false, id: "grid.page.next") {}
                }
            }
        }
        .font(Theme.interfaceFont(12))
        .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.bar)
        .qaScreen("grid.toolbar")
    }

    private func action(_ title: String, icon: String, enabled: Bool, id: String,
                        perform: @escaping () -> Void) -> some View {
        let tooltip: String = switch id {
        case "grid.refresh": "Volver a ejecutar esta consulta"
        case "grid.deleteRow": "Marcar fila seleccionada para eliminar"
        case "grid.reset": "Descartar el cambio del campo seleccionado"
        case "grid.save": "Revisar y guardar cambios (⌘Enter desde la grilla)"
        default: title
        }
        return Button(action: perform) {
            Group {
                if icon == "floppy" { FloppyDiskIcon() }
                else { Image(systemName: icon).font(.system(size: Theme.zoom(14))) }
            }
                .frame(width: Theme.zoom(26), height: Theme.zoom(24)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled)
            .help(enabled ? tooltip : tooltip + " · No disponible")
            .accessibilityLabel(title)
            .qaControl(id, title: title, enabled: enabled, action: perform)
    }
}

private struct FloppyDiskIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 1.5)
            Rectangle().strokeBorder(lineWidth: 1).frame(width: 7, height: 4).offset(y: -4)
            Rectangle().strokeBorder(lineWidth: 1).frame(width: 9, height: 5).offset(y: 3)
        }
        .frame(width: Theme.zoom(14), height: Theme.zoom(14))
    }
}
