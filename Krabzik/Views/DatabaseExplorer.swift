import SwiftUI

struct WorkspaceModeRail: View {
    let controller: WorkspaceController
    var body: some View {
        VStack(spacing: 12) {
            mode("Archivos", icon: "folder", databases: false)
            mode("Bases de datos", icon: "externaldrive", databases: true)
            Spacer()
        }
        .padding(.top, 14).frame(width: Theme.zoom(38)).background(Theme.bar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }
    private func mode(_ label: String, icon: String, databases: Bool) -> some View {
        Button {
            controller.database.browserShowsDatabases = databases
            controller.sidebarVisible = true
        } label: {
            Image(systemName: icon).font(.system(size: Theme.zoom(15)))
                .foregroundStyle(controller.database.browserShowsDatabases == databases ? Theme.accent : .secondary)
                .frame(width: Theme.zoom(30), height: Theme.zoom(30))
                .background(controller.database.browserShowsDatabases == databases ? Theme.accent.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct DatabaseExplorer: View {
    let controller: WorkspaceController
    @State private var ddl: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("BASES DE DATOS").font(.system(size: Theme.zoom(10), weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { controller.database.showingConnections = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("Administrar conexiones")
            }.padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.connections.profiles) { connection in connectionTree(connection) }
                    if controller.connections.profiles.isEmpty {
                        Text("Agregá una conexión global con +.").foregroundStyle(.secondary).padding()
                    }
                }.padding(.trailing, 10).padding(.bottom, 14)
            }
        }
        .font(.system(size: Theme.zoom(12))).background(Theme.background)
        .sheet(isPresented: Binding(get: { ddl != nil }, set: { if !$0 { ddl = nil } })) {
            VStack(alignment: .leading) {
                Text("Definición de la tabla").font(.headline)
                ScrollView([.horizontal, .vertical]) {
                    Text(ddl ?? "").font(.system(size: Theme.zoom(12), design: .monospaced)).textSelection(.enabled).padding()
                }
                HStack { Spacer()
                Button("Cerrar") { ddl = nil }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 760, height: 520)
        }
    }

    private func connectionTree(_ connection: DatabaseConnection) -> some View {
        let store = controller.database.schema
        let state = controller.database.state(connection.id)
        return VStack(alignment: .leading, spacing: 6) {
            SidebarTree(nodes: nodes(connection), name: { $0.name }) { item in
                treeLabel(item, connection: connection)
            }
            if let snapshot = store.snapshot(connection) {
                Text(snapshot.isPartial == true ? "Estructura parcial: la carga todavía no terminó."
                     : "Estructura: " + snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: Theme.zoom(9))).foregroundStyle(.tertiary)
                    .padding(.leading, Theme.zoom(SidebarTreeStyle.iconLeading))
            }
            if state.status == .disconnected {
                Button("Conectar") { controller.database.connect(connection) }.disabled(controller.isReadOnly)
                    .padding(.leading, Theme.zoom(SidebarTreeStyle.iconLeading))
            }
            if let progress = store.progress[connection.id] {
                Text(progress).font(.system(size: Theme.zoom(10))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.errors[connection.id] ?? state.error {
                Text(error).font(.system(size: Theme.zoom(10))).foregroundStyle(.orange).textSelection(.enabled)
                Button("Reintentar carga") { Task { await store.discover(connection, client: controller.database.client) } }
                    .disabled(store.loading.contains(connection.id) || controller.isReadOnly)
            } else if !store.loading.contains(connection.id), store.preference(connection).visible.isEmpty {
                Text("Elegí las bases con el selector de la derecha.").font(.system(size: Theme.zoom(10))).foregroundStyle(.secondary)
            }
        }
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

    @ViewBuilder private func treeLabel(_ item: Item, connection: DatabaseConnection) -> some View {
        let store = controller.database.schema
        let state = controller.database.state(connection.id)
        HStack(spacing: Theme.zoom(7)) {
            Image(systemName: item.icon)
                .font(.system(size: Theme.zoom(SidebarTreeStyle.iconSize)))
                .foregroundStyle(.secondary)
                .frame(width: Theme.zoom(24), height: Theme.zoom(24))
                .overlay(alignment: .bottomTrailing) {
                    if case .connection = item {
                        Circle().fill(state.status == .connected ? .green : .secondary).frame(width: 6, height: 6)
                    }
                }
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
                if store.loading.contains(connection.id) {
                    ProgressView().controlSize(.mini)
                    Button { store.cancel(connection.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).help("Cancelar carga de estructura").accessibilityLabel("Cancelar carga de estructura")
                }
                Button {
                    Task { await store.discover(connection, client: controller.database.client, choose: true) }
                } label: {
                    Text(store.available[connection.id].map { "\(store.preference(connection).visible.count)/\($0.count)" }
                         ?? "\(store.preference(connection).visible.count) bases")
                        .font(.system(size: Theme.zoom(10))).padding(3).background(Theme.bar, in: RoundedRectangle(cornerRadius: 3))
                }.buttonStyle(.plain).help("Elegir bases visibles y predeterminada").disabled(controller.isReadOnly)
            }
        }
        .contextMenu {
            switch item {
            case .connection:
                Button("Conectar") { controller.database.connect(connection) }
                    .disabled(controller.isReadOnly || state.status != .disconnected)
                Button("Actualizar estructura") { Task { await store.discover(connection, client: controller.database.client) } }
                Button("Desconectar") { Task { _ = await controller.database.disconnect(connection) } }.disabled(state.busy)
                Button("Configurar") { controller.database.editingConnection = connection }
            case .database(let database, _):
                Button("Usar en la sesión") { controller.database.selectDatabase(database, connection: connection) }
                Button("Base predeterminada") {
                    var preference = store.preference(connection)
                    preference.defaultDatabase = database
                    store.save(preference, for: connection)
                    controller.database.selectDatabase(database, connection: connection)
                }
            case .table(let table):
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
            case .column, .pending: EmptyView()
            }
        }
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
                    ForEach((database.schema.available[connection.id] ?? []).filter {
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
