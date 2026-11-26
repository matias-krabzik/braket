import SwiftUI

struct SQLResultsPanel: View {
    @Bindable var execution: SQLExecution
    let controller: WorkspaceController
    let hide: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var showingLogs: Bool { controller.outputVisible }

    private func selectResult(_ result: SQLResult) {
        controller.outputVisible = false
        execution.selectedResultID = result.id
    }

    private func closeResult(_ result: SQLResult) {
        execution.closeTabs(.current, relativeTo: result.id)
    }

    @ViewBuilder private func tabMenu(_ result: SQLResult) -> some View {
        Button(execution.pinned.contains(result.id) ? "Desfijar pestaña" : "Fijar pestaña") {
            togglePin(result)
        }.disabled(result.isLoading)
        Divider()
        ForEach(SQLResultTabAction.allCases, id: \.self) { action in
            Button(action.rawValue) { execution.closeTabs(action, relativeTo: result.id) }
                .disabled(!execution.canCloseTabs(action, relativeTo: result.id))
        }
    }

    private func togglePin(_ result: SQLResult) {
        if execution.pinned.contains(result.id) { execution.pinned.remove(result.id) }
        else { execution.pinned.insert(result.id) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        Button(action: controller.showOutput) {
                            Label("Logs", systemImage: "text.alignleft")
                                .padding(.vertical, 5).padding(.horizontal, 10)
                        }
                        .buttonStyle(.fullArea)
                        .background(Theme.surfaceInk.opacity(showingLogs ? 0.1 : 0.025),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityAddTraits(showingLogs ? .isSelected : [])
                        .help("Historial SQL del proyecto")
                        .qaControl("sql.logs.tab", title: "Logs", action: controller.showOutput)
                        ForEach(Array(execution.results.enumerated()), id: \.element.id) { index, result in
                            let draft = execution.draft(for: result)
                            HStack(spacing: 3) {
                                Button { selectResult(result) } label: {
                                    HStack(spacing: 6) {
                                        if result.isLoading { WorkspaceProgress().controlSize(.mini) }
                                        else { Image(systemName: "tablecells") }
                                        Text("Consulta \(index + 1)" + (draft.hasChanges ? " •" : ""))
                                    }.padding(.vertical, 5).padding(.leading, 9)
                                }.buttonStyle(.fullArea)
                                    .help("Consulta \(index + 1) · \(result.connection?.name ?? "Sin conexión") · "
                                          + "\(result.database)\n\(result.sql)")
                                SQLResultTabIcon(symbol: execution.pinned.contains(result.id) ? "pin.fill" : "pin",
                                                 selected: execution.pinned.contains(result.id)) { togglePin(result) }
                                    .disabled(result.isLoading)
                                    .help(execution.pinned
                                        .contains(result.id) ? "Desfijar pestaña" : "Fijar pestaña: conservar este resultado")
                                    .accessibilityLabel(execution.pinned.contains(result.id) ? "Desfijar pestaña" : "Fijar pestaña")
                                    .qaControl("sql.result.pin.\(index)", title: "Fijar o desfijar resultado",
                                               enabled: !result.isLoading) { togglePin(result) }
                                SQLResultTabIcon(symbol: "xmark") { closeResult(result) }
                                    .help("Cerrar resultado: Consulta \(index + 1)")
                                    .disabled(!execution.canCloseTabs(.current, relativeTo: result.id))
                                    .qaControl("sql.result.close.\(index)", title: "Cerrar resultado",
                                               enabled: execution.canCloseTabs(.current, relativeTo: result.id)) { closeResult(result) }
                            }
                            .tabSelectionBackground { selectResult(result) }
                            .background(Theme.surfaceInk.opacity(!showingLogs && execution.selectedResult?.id == result.id ? 0.1 : 0.025),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .transition(reduceMotion ? .opacity : .offset(y: 4).combined(with: .opacity))
                            .contextMenu { tabMenu(result) }
                            .qaControl("sql.result.tab.\(index)", title: "Consulta \(index + 1)",
                                       enabled: !result.isLoading) { selectResult(result) }
                        }
                    }.animation(.easeOut(duration: reduceMotion ? 0.08 : 0.15), value: execution.results.map(\.id))
                        .padding(.horizontal, 5).padding(.vertical, 3)
                }.scrollIndicators(.hidden)
                Menu {
                    ForEach(SQLResultTabAction.allCases, id: \.self) { action in
                        Button(action.rawValue) { execution.closeTabs(action, relativeTo: execution.selectedResult?.id) }
                            .disabled(!execution.canCloseTabs(action, relativeTo: execution.selectedResult?.id))
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Acciones de las pestañas de resultados")
                if !showingLogs { SQLTimeoutControl(execution: execution) }
                Button(action: hide) { Image(systemName: "chevron.down") }.buttonStyle(.fullArea)
                    .padding(.horizontal, 12).help("Ocultar resultados").accessibilityLabel("Ocultar resultados")
            }.font(Theme.interfaceFont(13)).background(Theme.bar).qaScreen("sql.results")
            if showingLogs {
                SQLOutputView(output: controller.database.output).id(controller.workspaceURL)
            } else if let result = execution.selectedResult {
                if result.isLoading {
                    VStack(spacing: 12) {
                        WorkspaceProgress().controlSize(.regular)
                        Text("Ejecutando consulta…").font(Theme.interfaceFont(13))
                        Text("Límite: \(execution.timeoutSeconds) segundos").foregroundStyle(.secondary)
                        Button("Cancelar") { controller.database.cancel(execution) }.disabled(execution.isCancelling)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SQLResultToolbar(execution: execution, draft: execution.draft(for: result), controller: controller)
                    SQLResultContent(draft: execution.draft(for: result), controller: controller)
                        .id(ObjectIdentifier(execution.draft(for: result)))
                        .workspaceReveal(result.id)
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
            .workspaceReveal(showingLogs)
    }
}

private struct SQLResultTabIcon: View {
    let symbol: String
    var selected = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: Theme.zoom(10), weight: .medium))
                .foregroundStyle(selected ? Theme.accent : .secondary)
                .frame(width: Theme.zoom(22), height: Theme.zoom(22))
                .contentShape(Rectangle())
                .background(Theme.surfaceInk.opacity(hovering && enabled ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.fullArea).onHover { hovering = $0 }
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
                SQLResultGrid(draft: draft, scale: controller.settings.resultFontScale, theme: controller.settings.resolvedTheme,
                              typography: controller.settings.resultTypography,
                              openRelated: { target in
                                  guard let connection = draft.result.connection else { return }
                                  controller.openRelatedRecord(target, connection: connection)
                              }, serverNow: { column in
                                  guard let connection = draft.result.connection else { throw DatabaseFailure("Sin conexión MySQL.") }
                                  return try await controller.database.serverNow(column: column, connection: connection)
                              })
            }
            if let connection = draft.result.connection, let error = controller.database.schema.errors[connection.id] {
                Text("Estructura: " + error).font(Theme.interfaceFont(12)).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                    .qaLabel("sql.result.schemaError", error)
            }
            if let error = draft.relations.error {
                HStack {
                    Text(error).font(Theme.interfaceFont(12)).foregroundStyle(.orange)
                    Spacer()
                    Button("Reintentar") { Task { await loadRelations() } }
                }.padding(8)
            }
            if let error = draft.result.error {
                Text(error).font(Theme.interfaceFont(12)).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .task { await loadRelations() }
        .onAppear { draft.configure(schemaTable) }
        .onChange(of: schemaTable) { _, table in draft.configure(table) }
        .sheet(isPresented: $draft.showingReview) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Revisar cambios antes de enviar").font(.headline)
                Text((draft.result.connection?.destination ?? "") + " · " + (draft.table?.qualified ?? ""))
                    .foregroundStyle(.secondary)
                Text("Se enviarán juntos en una transacción. Si una fila cambió o un valor falla, se revierten todos.")
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SQLChangesReview(rows: draft.reviewChanges)
                        DisclosureGroup("Ver SQL que se ejecutará") {
                            Text("La lectura FOR UPDATE bloquea la fila por su clave. Braket compara todos los valores "
                                 + "originales de la grilla antes de ejecutar cada cambio.")
                                .font(Theme.interfaceFont(12)).foregroundStyle(.secondary)
                            ScrollView(.horizontal) {
                                Text(preview).font(Theme.codeFont()).textSelection(.enabled).padding(12)
                            }.background(Theme.bar)
                        }
                    }
                }
                if let error = draft.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    if draft.sending { WorkspaceProgress().controlSize(.small) }
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
            }.padding(24).frame(width: 900, height: 620).interactiveDismissDisabled(draft.sending)
                .qaScreen("grid.review")
        }
    }
    private func loadRelations() async {
        guard let connection = draft.result.connection else { return }
        let relations = draft.relations
        let client = controller.database.client
        let connections = controller.connections
        relations.load = { target in
            guard connections.profiles.contains(where: {
                $0.id == connection.id && $0.configurationWithoutTint == connection.configurationWithoutTint
            }) else { throw DatabaseFailure("La conexión del resultado cambió o se quitó. Volvé a ejecutar la consulta de origen.") }
            let password = try CredentialStore.read(for: connection)
            return try await client.metadataQuery(target.previewQuery, configuration: connection,
                                                  password: password)
        }
        let sources = Set(draft.result.origins.filter { !$0.database.isEmpty && !$0.table.isEmpty }
            .map { SQLTableIdentity(database: $0.database, table: $0.table) })
        var errors: [String] = []
        for source in sources where relations.keys[source] == nil {
            guard connections.profiles.contains(where: {
                $0.id == connection.id && $0.configurationWithoutTint == connection.configurationWithoutTint
            }) else { relations.error = "La conexión del resultado cambió o se quitó. Volvé a ejecutar la consulta de origen."
            return }
            if let cached = controller.database.schema.snapshot(connection)?.tables.first(where: {
                $0.database == source.database && $0.name == source.table
            })?.foreignKeys { relations.keys[source] = cached
            continue }
            do {
                let password = try CredentialStore.read(for: connection)
                let result = try await controller.database.client.metadataQuery(SQLForeignKey.query(database: source.database,
                                                                                                    table: source.table),
                                                                                configuration: connection, password: password)
                try Task.checkCancellation()
                relations.keys[source] = SQLForeignKey.grouped(result.rows)[source.table] ?? []
            } catch {
                if !Task.isCancelled { errors.append("No se pudieron leer las relaciones: " + MySQLClient.message(error)) }
            }
        }
        if !Task.isCancelled { relations.error = errors.isEmpty ? nil : errors.joined(separator: "\n") }
    }

    private func submit() {
        controller.database.submit(draft, profiles: controller.connections.profiles, document: controller.sqlResultsDocument)
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
        .buttonStyle(.fullArea)
        .font(Theme.interfaceFont(12))
        .disabled(execution.isRunning)
        .help("Timeout por sentencia · \(execution.timeoutSource). El ajuste de este archivo se recuerda.")
        .accessibilityLabel("Tiempo máximo por sentencia: \(execution.timeoutSeconds) segundos")
        .popover(isPresented: $showingEditor, arrowEdge: .bottom) {
            SQLTimeoutEditor(initialSeconds: execution.timeoutSeconds,
                             inheritedSeconds: execution.inheritedTimeoutSeconds,
                             inheritedSource: execution.inheritedTimeoutSource(),
                             onReset: { execution.resetTimeout()
                             showingEditor = false },
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
    let onReset: () -> Void
    let inheritedSeconds: Int
    let inheritedSource: String
    @State private var proposedSeconds: String

    init(initialSeconds: Int, inheritedSeconds: Int, inheritedSource: String,
         onReset: @escaping () -> Void, onSave: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.inheritedSeconds = inheritedSeconds
        self.inheritedSource = inheritedSource
        self.onReset = onReset
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
            Text("Se recuerda para este archivo y se aplica a cada sentencia por separado. Entre 1 y 3600 segundos.")
                .font(Theme.interfaceFont(11)).foregroundStyle(.secondary)
            Button("Heredar de \(inheritedSource.lowercased()): \(inheritedSeconds) s", action: onReset)
                .help("Quitar el ajuste del archivo y usar el timeout del proyecto o de la aplicación")
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
            || result.connection.map { connection in
                controller.database.state(connection.id).busy
                    || !controller.connections.profiles.contains { $0.id == connection.id }
            } != false
    }

    private func run(page: Int? = nil) {
        guard let document = controller.sqlResultsDocument, let id = result.connection?.id,
              let connection = controller.connections.profiles.first(where: { $0.id == id }) else { return }
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
                    WorkspaceProgress().controlSize(.mini).help("Cargando estructura…")
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
        }.buttonStyle(.fullArea).disabled(!enabled)
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
