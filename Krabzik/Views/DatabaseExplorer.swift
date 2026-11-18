import SwiftUI

struct DatabaseExplorer: View {
    let controller: WorkspaceController
    @State private var ddl: String?
    @State private var removing: DatabaseConnection?
    var body: some View {
        let widestCount = controller.connections.profiles.map(countText).max { $0.count < $1.count } ?? ""
        VStack(spacing: 0) {
            HStack {
                Text("BASES DE DATOS").font(Theme.interfaceFont(12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { controller.database.showingConnections = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("Administrar conexiones")
            }.padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.connections.profiles) { connection in
                        if connection.id != controller.connections.profiles.first?.id {
                            Divider().padding(.leading, 8)
                        }
                        connectionTree(connection, widestCount: widestCount)
                            .id((controller.workspaceURL?.standardizedFileURL.path ?? "") + connection.id.uuidString)
                    }
                    if controller.connections.profiles.isEmpty {
                        Text("Agregá una conexión global con +.").foregroundStyle(.secondary).padding()
                    }
                }.padding(.bottom, 14)
            }
        }
        .font(Theme.interfaceFont(13)).background(Theme.background)
        .qaScreen("explorer.databases")
        .confirmationDialog("¿Eliminar la conexión guardada?", isPresented: Binding(get: { removing != nil },
                                                                                    set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            if let removing {
                Button("Eliminar " + removing.name, role: .destructive) {
                    controller.connections.remove(removing)
                    self.removing = nil
                }
            }
            Button("Cancelar", role: .cancel) { removing = nil }
        } message: {
            Text("Se quitará de todos los proyectos. Los scripts que la usan quedarán sin conexión asignada.")
        }
        .sheet(isPresented: Binding(get: { ddl != nil }, set: { if !$0 { ddl = nil } })) {
            VStack(alignment: .leading) {
                Text("Definición de la tabla").font(.headline)
                ScrollView([.horizontal, .vertical]) {
                    Text(ddl ?? "").font(Theme.codeFont()).textSelection(.enabled).padding()
                }
                HStack { Spacer()
                Button("Cerrar") { ddl = nil }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 760, height: 520)
        }
    }

    private func connectionTree(_ connection: DatabaseConnection, widestCount: String) -> some View {
        SidebarTree(nodes: nodes(connection), name: { $0.name },
                    menu: { AnyView(contextMenu($0, connection: connection)) },
                    persistenceKey: "explorer.databases.expansion.v1."
                        + (controller.workspaceURL?.standardizedFileURL.path ?? "") + "." + connection.id.uuidString) { item in
            treeLabel(item, connection: connection, widestCount: widestCount)
        }
        .padding(.trailing, 10)
        .background {
            if let tint = FileIcons.groupTint(hex: connection.tintHex, strength: connection.tintStrength) {
                Rectangle().fill(Color(nsColor: tint))
                    .allowsHitTesting(false)
            }
        }
    }

    private func countText(_ connection: DatabaseConnection) -> String {
        let schema = controller.database.schema
        let visible = schema.snapshot(connection)?.databases.count ?? 0
        let total = schema.catalog(for: connection).map { String($0.count) } ?? "—"
        return "\(visible)/\(total)"
    }

    @ViewBuilder private func connectionControls(_ connection: DatabaseConnection, widestCount: String) -> some View {
        let database = controller.database
        let store = database.schema
        let state = database.state(connection.id)
        let connected = state.status == .connected
        let connecting = state.status == .connecting
        if store.loading.contains(connection.id) {
            ProgressView().controlSize(.mini).help(store.progress[connection.id] ?? "Cargando estructura")
        } else if let error = store.errors[connection.id] ?? state.error {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(error)
                .qaLabel("explorer.schema.error." + connection.name, error)
        }

        Group {
            if connecting { ProgressView().controlSize(.mini) }
            else { ConnectionPlug(connected: connected) }
        }
        .frame(width: Theme.zoom(32), height: Theme.zoom(24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connecting ? "Conectando" : connected ? "Conectada" : "Desconectada")
        .help("Clic derecho para conectar o desconectar")

        let count = countText(connection)
        Text(widestCount).hidden().overlay { Text(count) }
            .font(Theme.interfaceFont(12, weight: .medium).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.bar, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Bases visibles / total disponible: " + count)
            .help("Bases visibles / total disponible: " + count + "\nClic derecho para elegir bases")
    }

    private enum Item {
        case connection(DatabaseConnection)
        case database(String, preferred: Bool)
        case table(SQLSchemaTable)
        case column(SQLSchemaColumn, key: Bool)
        case pending

        var name: String {
            switch self {
            case .connection(let connection): connection.name
            case .database(let name, _): name
            case .table(let table): table.name
            case .column(let column, _): column.name
            case .pending: "Columnas pendientes de cargar"
            }
        }

        var icon: String {
            switch self {
            case .connection, .database: "externaldrive"
            case .table(let table): table.kind == "VIEW" ? "eye" : "tablecells"
            case .column(_, let key): key ? "key" : "text.alignleft"
            case .pending: "ellipsis"
            }
        }
    }

    private func nodes(_ connection: DatabaseConnection) -> [SidebarTreeNode<Item>] {
        let store = controller.database.schema
        let root = connection.id.uuidString
        let databases: [SidebarTreeNode<Item>] = store.snapshot(connection).map { snapshot in
            snapshot.databases.map { database in
                let id = root + "/" + database
                let tables = snapshot.tables.filter { $0.database == database }.map { table in
                    let tableID = id + "/" + table.name
                    var columns = table.columns.map { column in
                        SidebarTreeNode(id: tableID + "/" + column.name,
                                        value: Item.column(column, key: table.uniqueKeys.contains { $0.contains(column.name) }))
                    }
                    if columns.isEmpty { columns = [.init(id: tableID + "/pending", value: .pending)] }
                    return SidebarTreeNode(id: tableID, value: Item.table(table), children: columns, expandable: true)
                }
                return SidebarTreeNode(id: id,
                                       value: Item.database(database, preferred: store.preference(connection).defaultDatabase == database),
                                       children: tables, expandable: true)
            }
        } ?? []
        return [.init(id: root, value: .connection(connection), children: databases, expandable: true)]
    }

    @ViewBuilder private func treeLabel(_ item: Item, connection: DatabaseConnection, widestCount: String) -> some View {
        HStack(spacing: Theme.zoom(7)) {
            Image(systemName: item.icon)
                .font(.system(size: Theme.zoom(SidebarTreeStyle.iconSize)))
                .foregroundStyle(.secondary)
                .frame(width: Theme.zoom(24), height: Theme.zoom(24))
            Text(item.name).lineLimit(1).truncationMode(.middle)
                .help({
                    if case .column(let column, _) = item { return column.type + (column.nullable ? " · NULL" : " · NOT NULL") }
                    return item.name
                }())
            if case .database(_, let preferred) = item, preferred { Text("★").foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            if case .column(let column, _) = item {
                Text(column.type).foregroundStyle(.tertiary).lineLimit(1)
            }
            if case .connection = item {
                connectionControls(connection, widestCount: widestCount)
            }
        }
    }

    @ViewBuilder private func contextMenu(_ item: Item, connection: DatabaseConnection) -> some View {
        let store = controller.database.schema
        let state = controller.database.state(connection.id)
        switch item {
            case .connection:
                Button {
                    if state.status == .connected { Task { _ = await controller.database.disconnect(connection) } }
                    else { controller.database.connect(connection) }
                } label: {
                    Label {
                        Text(state.status == .connecting ? "Conectando…" :
                             state.status == .connected ? "Desconectar" : "Conectar")
                    } icon: { ConnectionPlug(connected: state.status == .connected) }
                }
                .disabled(state.status == .connecting || state.busy ||
                          (state.status != .connected && controller.isReadOnly))
                Button("Nueva consulta", systemImage: "doc.badge.plus") { controller.newQuery(connection: connection) }
                    .disabled(controller.isReadOnly || controller.isSwitchingWorkspace)
                Divider()
                Button("Elegir bases visibles…", systemImage: "cylinder.split.1x2") {
                    Task { await store.discover(connection, client: controller.database.client, choose: true) }
                }.disabled(controller.isReadOnly)
                if store.loading.contains(connection.id) {
                    Button("Cancelar carga de estructura", systemImage: "stop.circle") { store.cancel(connection.id) }
                } else {
                    Button("Actualizar estructura", systemImage: "arrow.clockwise") {
                        Task { await store.discover(connection, client: controller.database.client) }
                    }.disabled(controller.isReadOnly)
                }
                Divider()
                Button("Editar conexión…", systemImage: "pencil") { controller.database.editingConnection = connection }
                    .disabled(controller.isReadOnly)
                Button("Duplicar conexión…", systemImage: "plus.square.on.square") {
                    var copy = connection
                    copy.id = UUID()
                    copy.name += " (copia)"
                    controller.database.editingConnection = copy
                }.disabled(controller.isReadOnly)
                Button("Copiar dirección del servidor", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connection.host + ":" + String(connection.port), forType: .string)
                }
                Divider()
                Button("Eliminar conexión…", systemImage: "trash", role: .destructive) { removing = connection }
                    .disabled(controller.isReadOnly || state.busy || state.status == .connecting)
            case .database(let database, _):
                Button("Usar en la sesión") { controller.database.selectDatabase(database, connection: connection) }
                Button("Base predeterminada") {
                    var preference = store.preference(connection)
                    preference.defaultDatabase = database
                    store.save(preference, for: connection)
                    controller.database.selectDatabase(database, connection: connection)
                }
            case .table(let table):
                Button("Abrir consulta", systemImage: "doc.badge.plus") {
                    controller.openTableQuery(table, connection: connection)
                }.disabled(controller.isReadOnly)
                Button("Copiar nombre SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(table.qualified, forType: .string)
                }
                Button("Ver CREATE TABLE") {
                    Task {
                        do {
                            let password = try CredentialStore.read(for: connection)
                            ddl = try await controller.database.client.createTable(table, config: connection, password: password)
                        } catch { store.errors[connection.id] = MySQLClient.message(error) }
                    }
                }
            case .column, .pending:
                Button("Copiar nombre", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.name, forType: .string)
                }
        }
    }

}

private struct ConnectionPlug: View {
    let connected: Bool

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 28, y: size.height / 14)
            let ink: GraphicsContext.Shading = .color(connected ? .green : .secondary)
            let left: CGFloat = connected ? 13.5 : 10
            let right: CGFloat = connected ? 14.5 : 18
            var wires = Path()
            wires.move(to: CGPoint(x: 1, y: 7))
            wires.addLine(to: CGPoint(x: left - 4, y: 7))
            wires.move(to: CGPoint(x: right + 4, y: 7))
            wires.addLine(to: CGPoint(x: 27, y: 7))
            if !connected {
                for y in [4.75, 9.25] {
                    wires.move(to: CGPoint(x: left, y: y))
                    wires.addLine(to: CGPoint(x: left + 3, y: y))
                }
            }
            context.stroke(wires, with: ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            var halves = Path()
            halves.addArc(center: CGPoint(x: left, y: 7), radius: 5,
                          startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            halves.closeSubpath()
            halves.move(to: CGPoint(x: right, y: 2))
            halves.addArc(center: CGPoint(x: right, y: 7), radius: 5,
                          startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            halves.closeSubpath()
            context.fill(halves, with: ink)
        }
        .frame(width: Theme.zoom(26), height: Theme.zoom(13))
        .accessibilityHidden(true)
    }
}

struct DatabaseSelectionSheet: View {
    let connection: DatabaseConnection
    let database: DatabaseController
    @Environment(\.dismiss) private var dismiss
    @State private var visible: Set<String> = []
    @State private var preferred = ""
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bases de datos · " + connection.name).font(.headline)
            Text("Elegí las bases que aparecen en el explorador. La predeterminada se usa al conectar.")
                .foregroundStyle(.secondary)
            TextField("Filtrar bases", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach((database.schema.catalog(for: connection) ?? []).filter {
                        search.isEmpty || $0.localizedCaseInsensitiveContains(search)
                    }, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { visible.contains(name) }, set: {
                            if $0 { visible.insert(name) } else { visible.remove(name)
                            if preferred == name { preferred = "" } }
                        }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("Predeterminada", selection: $preferred) {
                Text("Ninguna").tag("")
                ForEach(visible.sorted(), id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Text("\(visible.count) seleccionadas").foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aplicar") {
                    database.schema.save(.init(visible: visible.sorted(), defaultDatabase: preferred), for: connection)
                    if !preferred.isEmpty { database.selectDatabase(preferred, connection: connection) }
                    Task { await database.schema.discover(connection, client: database.client) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(database.schema.loading.contains(connection.id))
            }
        }.padding(24).frame(width: 480, height: 500)
            .onAppear {
                let preference = database.schema.preference(connection)
                visible = Set(preference.visible)
                preferred = preference.defaultDatabase
            }
    }
}
