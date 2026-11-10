import AppKit
import SwiftUI

struct DatabaseSidebar: View {
    @Bindable var controller: WorkspaceController
    var filter = ""

    private var query: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var connections: [DatabaseConnection] {
        (controller.workspace?.connections ?? []).filter {
            query.isEmpty || ($0.name + " " + $0.destination).localizedStandardContains(query)
        }
    }
    private var scripts: [String] {
        (controller.workspace?.scripts ?? []).filter { query.isEmpty || $0.localizedStandardContains(query) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("CONEXIONES").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { controller.database.editingConnection = DatabaseConnection() } label: {
                        Image(systemName: "plus").font(.system(size: 11)) }
                        .buttonStyle(.plain).help("Agregar conexión MySQL").accessibilityLabel("Agregar conexión MySQL")
                }.padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 5)
                ForEach(connections) { connection in
                    if let state = controller.database.states[connection.id] {
                        DatabaseRow(connection: connection, state: state,
                                    selected: controller.database.selectedConnectionID == connection.id,
                                    connect: { controller.database.connect(connection) })
                        .contextMenu {
                            Button(state.status == .connected ? "Desconectar" : "Conectar") {
                                if state.status == .connected { Task { _ = await controller.database.disconnect(connection) } }
                                else { controller.database.connect(connection) }
                            }.disabled(state.busy || state.status == .connecting)
                            Button("Editar…") { controller.database.editingConnection = connection }
                                .disabled(state.busy || state.status == .connecting)
                            Divider()
                            Button("Quitar conexión") { controller.connections.remove(connection) }
                                .disabled(state.busy || state.status == .connecting)
                        }
                    }
                }
                if connections.isEmpty {
                    Text(query.isEmpty ? "Todavía no hay conexiones." : "No hay conexiones que coincidan.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15).padding(.vertical, 8)
                }
                Divider().padding(.horizontal, 15).padding(.top, 16)
                HStack {
                    Text("CONSULTAS SQL").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Nuevo script…") {
                            controller.files.create(in: controller.workspaceURL?.deletingLastPathComponent())
                        }.disabled(controller.isReadOnly)
                        Button("Abrir script…", action: controller.files.importScripts)
                    } label: { Image(systemName: "plus").font(.system(size: 11)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Agregar script SQL")
                }.padding(.horizontal, 15).padding(.top, 12).padding(.bottom, 4)
                scriptRows
                if scripts.isEmpty {
                    Text(query.isEmpty ? "Agregá una consulta desde el botón +." : "No hay consultas que coincidan.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15).padding(.vertical, 8)
                }
            }.padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    @ViewBuilder private var scriptRows: some View {
        ForEach(scripts, id: \.self) { path in
            if let url = controller.files.scriptURL(path) {
                Button { controller.files.open(url) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Text(url.lastPathComponent).lineLimit(1)
                        Spacer()
                    }.font(.system(size: 12)).padding(.horizontal, 17).frame(height: 28)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(url.path)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundStyle(.tertiary)
                    Text((path as NSString).lastPathComponent).lineLimit(1).foregroundStyle(.tertiary)
                    Spacer()
                    }
                    .font(.system(size: 12)).padding(.horizontal, 17).frame(height: 28)
                    .help("Fuera de la carpeta del proyecto: no disponible en solo lectura.")
                }
        }
    }
}

private struct DatabaseRow: View {
    let connection: DatabaseConnection
    let state: DatabaseState
    let selected: Bool
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: connect) {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text(connection.name).lineLimit(1)
                    Spacer()
                    if state.status == .connecting { ProgressView().controlSize(.mini) }
                    else { Circle().fill(state.status == .connected ? Color.green.opacity(0.75) : .secondary.opacity(0.4)).frame(width: 6,
                                                                                                                                 height: 6)
                                                                                                                                 }
                }
                .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 30)
                .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help(connection.destination)
            if let error = state.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.red.opacity(0.85))
                    .lineLimit(3).textSelection(.enabled).padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 3)
        .background(Color(nsColor: FileIcons.groupTint(hex: connection.tintHex, strength: connection.tintStrength) ?? .clear),
                    in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 7)
    }
}

struct ConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var connection: DatabaseConnection
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var succeeded = false
    let controller: WorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MySQL").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                row("Nombre") { TextField("Mi base", text: $connection.name) }
                row("Servidor") {
                    HStack {
                        TextField("127.0.0.1", text: $connection.host)
                        TextField("3306", value: $connection.port, format: .number.grouping(.never)).frame(width: 70)
                    }
                }
                row("Usuario") { TextField("root", text: $connection.username) }
                row("Contraseña") { SecureField("", text: $password) }
                row("Base de datos") { TextField("Opcional", text: $connection.database) }
                row("TLS") {
                    Picker("TLS", selection: $connection.tls) {
                        ForEach(DatabaseConnection.TLSMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                    }.labelsHidden()
                }
                if connection.tls == .disabled {
                    GridRow {
                        Text("")
                        Text(insecureRemote
                             ? "Sin TLS solo se permite para conexiones locales."
                             : "Sin cifrado. Aceptable solo porque el servidor es local.")
                            .font(.system(size: 10))
                            .foregroundStyle(insecureRemote ? Color.orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.textFieldStyle(.roundedBorder).disabled(busy)
            SidebarTintEditor(hex: $connection.tintHex, strength: $connection.tintStrength,
                              detail: "Identificá esta conexión por color: producción, beta, desarrollo, etc.")
                .disabled(busy)
            if connection.tintHex != nil {
                Label(connection.name, systemImage: "externaldrive")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Color(nsColor: FileIcons.groupTint(hex: connection.tintHex, strength: connection.tintStrength) ?? .clear),
                                in: RoundedRectangle(cornerRadius: 7))
            }
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(succeeded ? Color.green : .red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Probar") { test() }.disabled(busy || insecureRemote)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Guardar") { save() }.keyboardShortcut(.defaultAction).disabled(busy || insecureRemote)
            }
        }
        .padding(24).frame(width: 470)
        .task {
            do { password = try CredentialStore.read(for: connection) }
            catch { message = error.localizedDescription }
        }
        .onChange(of: connection) { _, _ in message = nil }
        .onChange(of: password) { _, _ in message = nil }
        .interactiveDismissDisabled(busy)
    }

    /// Sin TLS contra un extremo que no es local: se avisa y se bloquea antes de
    /// intentar nada. Se deriva del estado para que cambie en vivo al escribir el host.
    private var insecureRemote: Bool { connection.tls == .disabled && !connection.isLoopbackHost }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            content()
        }
    }

    private func test() {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let value = try connection.validated()
                try await controller.database.client.test(value, password: password)
                succeeded = true
                message = "Conexión correcta"
            } catch {
                succeeded = false
                message = MySQLClient.message(error)
            }
        }
    }

    private func save() {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await controller.connections.save(connection, password: password)
                dismiss()
            }
            catch {
                succeeded = false
                message = MySQLClient.message(error)
            }
        }
    }
}

struct SQLToolbar: View {
    let document: EditorDocument
    @Bindable var controller: WorkspaceController

    /// Se puede ejecutar si hay una conexión elegida y no está ocupada ni conectándose.
    /// Estaba escrito como una condición de tres líneas dentro del `.disabled`, donde
    /// había que leerla al revés.
    private var canExecute: Bool {
        guard let connection = controller.connections.selected else { return false }
        let state = controller.database.states[connection.id]
        return state?.busy != true && state?.status != .connecting
    }

    var body: some View {
        HStack(spacing: 12) {
            Picker("Conexión",
                   selection: Binding(get: { controller.database.selectedConnectionID },
                                      set: { controller.database.selectedConnectionID = $0 })) {
                Text("Conexión").tag(nil as UUID?)
                ForEach(controller.workspace?.connections ?? []) { connection in
                    Text(connection.name).tag(Optional(connection.id))
                }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(document.sqlExecution.isRunning)
            if let connection = controller.connections.selected {
                let state = controller.database.states[connection.id]
                let database = state?.status == .connected ? state?.currentDatabase ?? "" : connection.database
                Text("\(connection.host):\(connection.port)" + (database.isEmpty ? "" : " / \(database)"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if state?.inTransaction == true { Text("Transacción").font(.system(size: 10)).foregroundStyle(.orange) }
            }
            Spacer(minLength: 4)
            if document.sqlExecution.isRunning {
                Button { controller.database.cancel(document.sqlExecution) } label: { Image(systemName: "stop.fill") }
                    .disabled(document.sqlExecution.isCancelling).help("Cancelar consulta").accessibilityLabel("Cancelar consulta")
            } else {
                Button(action: controller.executeSQL) { Image(systemName: "play.fill") }
                    .disabled(!canExecute)
                    .help("Ejecutar selección o script (⌘↩)").accessibilityLabel("Ejecutar SQL")
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 18).frame(height: 33)
        .background(Theme.bar)
    }
}

struct SQLResultsPanel: View {
    @Bindable var execution: SQLExecution
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Resultados").font(.system(size: 11, weight: .medium))
                if execution.isRunning { ProgressView().controlSize(.mini) }
                if execution.results.count > 1 {
                    Picker("Resultado", selection: $execution.selectedResultID) {
                        ForEach(execution.results) { result in
                            Text("\(result.statement) · línea \(result.line)").tag(Optional(result.id))
                        }
                    }.labelsHidden().fixedSize()
                }
                Spacer()
                Text(execution.connectionName).font(.system(size: 10)).foregroundStyle(.secondary).help(execution.destination)
                Button(action: hide) { Image(systemName: "chevron.down").font(.system(size: 10)) }.buttonStyle(.plain)
                    .help("Ocultar resultados")
            }.padding(.horizontal, 15).frame(height: 32).background(Theme.bar)
            Rectangle().fill(Theme.border).frame(height: 1)
            if let result = execution.selectedResult {
                if !result.columns.isEmpty { SQLResultTable(result: result, theme: AppSettings.shared.theme) }
                else {
                    Text(result.error ?? "\(result.affectedRows) filas afectadas")
                        .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(result.error == nil ? Color.secondary : .red.opacity(0.9))
                        .textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
                }
                HStack {
                    Text(result.error == nil ? result.summary : "Línea \(result.line)").lineLimit(1)
                    Spacer()
                    if let note = execution.cancelNote {
                        Text(note).foregroundStyle(.orange).lineLimit(1).help(note)
                    }
                    if let error = execution.error { Text(error).foregroundStyle(.red.opacity(0.9)).lineLimit(1).help(error) }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 15).frame(height: 25)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(execution.error ?? (execution.isCancelling ? "Cancelando…" : execution.isRunning ? "Ejecutando…" : ""))
                        .foregroundStyle(execution.error == nil ? Color.secondary : .red)
                    if let note = execution.cancelNote { Text(note).foregroundStyle(.orange) }
                }
                .font(.system(size: 12))
                .textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            }
        }.background(Theme.background)
    }
}

private struct SQLResultTable: NSViewRepresentable {
    let result: SQLResult
    let theme: AppTheme
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.backgroundColor = EditorPalette.background(for: theme)
        table.style = .plain
        table.rowHeight = 25
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = .separatorColor.withAlphaComponent(0.25)
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        table.backgroundColor = EditorPalette.background(for: theme)
        guard context.coordinator.result?.id != result.id else { return }
        context.coordinator.result = result
        for column in table.tableColumns { table.removeTableColumn(column) }
        for (index, name) in result.columns.enumerated() {
            let column = NSTableColumn(identifier: .init("\(index)"))
            column.title = name
            let length = max(name.count, result.rows.prefix(25).map { $0[index]?.count ?? 4 }.max() ?? 0)
            column.width = CGFloat(min(380, max(95, length * 7 + 24)))
            column.minWidth = 60
            column.maxWidth = 1600
            table.addTableColumn(column)
        }
        table.reloadData()
        if !result.rows.isEmpty { table.scrollRowToVisible(0) }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var result: SQLResult?
        func numberOfRows(in tableView: NSTableView) -> Int { result?.rows.count ?? 0 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let result, let index = Int(tableColumn?.identifier.rawValue ?? ""), result.rows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("value")
            let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? NSTextField(labelWithString: "")
            let value = result.rows[row][index]
            field.identifier = identifier
            field.stringValue = value ?? "NULL"
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.textColor = value == nil ? .tertiaryLabelColor : EditorPalette.text
            field.lineBreakMode = .byTruncatingTail
            field.isSelectable = true
            field.toolTip = value ?? "NULL"
            return field
        }
    }
}
