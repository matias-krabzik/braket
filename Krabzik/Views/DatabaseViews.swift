import AppKit
import SwiftUI

struct ConnectionsSettingsView: View {
    let controller: WorkspaceController
    var showsDone = false
    @Environment(\.dismiss) private var dismiss
    @State private var editing: DatabaseConnection?
    @State private var removing: DatabaseConnection?
    @State private var selectionHost = UUID()
    @State private var showingShared = false
    @State private var sharedSearch = ""

    private var connectedCount: Int {
        controller.connections.profiles.filter { controller.database.states[$0.id]?.status == .connected }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Conexiones").font(.title2.weight(.semibold))
                    Text(controller.connections.hasProject ? "Conexiones de este proyecto" : "Catálogo de conexiones compartidas")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.connections.hasProject {
                    Button { showingShared.toggle() } label: { Label("Compartidas", systemImage: "person.2") }
                        .help("Buscar y agregar una conexión compartida a este proyecto")
                        .qaControl("connections.shared", title: "Compartidas") { showingShared.toggle() }
                }
                Button { editing = DatabaseConnection() } label: {
                    Label("Nueva conexión", systemImage: "plus")
                }
                .qaControl("connections.new", title: "Nueva conexión") { editing = DatabaseConnection() }
            }.padding(20)
            HStack(spacing: 6) {
                Circle().fill(connectedCount > 0 ? Color.green : .secondary).frame(width: 6, height: 6)
                Text("\(connectedCount) abiertas · \(controller.connections.profiles.count) guardadas")
                Spacer()
                Text("MySQL · TCP/IP")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 16)
            Divider()
            if showingShared {
                sharedCatalog
            } else { ScrollView {
                LazyVStack(spacing: 12) {
                    if controller.connections.profiles.isEmpty {
                        ContentUnavailableView("Tus bases de datos, en un solo lugar", systemImage: "externaldrive",
                                               description: Text("Creá una conexión o agregá una desde Compartidas."))
                    }
                    ForEach(controller.connections.profiles) { connection in
                        connectionCard(connection)
                    }
                }.padding(20)
            } }
            Divider()
            HStack {
                Text("Cada proyecto elige sus conexiones. Las contraseñas se conservan en el llavero.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if showsDone { Button("Listo") { dismiss() }.keyboardShortcut(.cancelAction) }
            }.padding(20)
        }
        .background(Theme.background)
        .qaScreen("connections")
        .sheet(item: $editing) { ConnectionSheet(connection: $0, controller: controller) }
        .onAppear {
            if !controller.database.schema.selectionHosts.contains(selectionHost) {
                controller.database.schema.selectionHosts.append(selectionHost)
            }
        }
        .onDisappear { controller.database.schema.selectionHosts.removeAll { $0 == selectionHost } }
        .sheet(item: Binding(get: {
            controller.database.schema.selectionHosts.last == selectionHost ? controller.database.schema.choosing : nil
        }, set: { controller.database.schema.choosing = $0 })) { connection in
            DatabaseSelectionSheet(connection: connection, database: controller.database)
        }
        .confirmationDialog("¿Quitar la conexión guardada?", isPresented: Binding(get: { removing != nil },
                                                                                  set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
                if let removing {
                    Button("Quitar " + removing.name, role: .destructive) {
                        controller.connections.remove(removing)
                        self.removing = nil
                    }
                }
        } message: {
            Text(controller.connections.hasProject
                 ? "Se quitará de este proyecto. Las conexiones compartidas seguirán disponibles para los demás."
                 : "Se eliminará del catálogo y de todos los proyectos que la usan.")
        }
    }

    private var sharedCatalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agregar desde Compartidas").font(.headline)
                Spacer()
                Button("Volver") { showingShared = false }
            }
            TextField("Buscar por nombre, servidor o usuario…", text: $sharedSearch).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Buscar conexiones compartidas")
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(controller.connections.sharedProfiles.filter {
                        sharedSearch.isEmpty || $0.name.localizedStandardContains(sharedSearch)
                            || $0.host.localizedStandardContains(sharedSearch) || $0.username.localizedStandardContains(sharedSearch)
                    }) { connection in
                        HStack {
                            Image(systemName: "externaldrive")
                            VStack(alignment: .leading) {
                                Text(connection.name).fontWeight(.medium)
                                Text(connection.destination).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let added = controller.connections.profiles.contains { $0.id == connection.id }
                            Button(added ? "Agregada" : "Agregar") {
                                do { try controller.connections.addShared(connection) }
                                catch { controller.errors.report(error) }
                            }.disabled(added || controller.isReadOnly)
                                .help("Usar esta conexión en el proyecto; conserva la contraseña del llavero")
                                .qaControl("connections.shared.add." + connection.name, title: added ? "Agregada" : "Agregar",
                                           enabled: !added && !controller.isReadOnly) {
                                    do { try controller.connections.addShared(connection) }
                                    catch { controller.errors.report(error) }
                                }
                        }.padding(12).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if controller.connections.sharedProfiles.isEmpty {
                        Text("No hay conexiones compartidas. Podés compartir una desde su edición.").foregroundStyle(.secondary)
                    }
                }
            }
            Text("Editar una compartida actualiza su perfil en todos los proyectos que la usan.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }

    private func connectionCard(_ connection: DatabaseConnection) -> some View {
        let state = controller.database.state(connection.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive").font(.title2).foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38).background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.name).font(.headline)
                    Text(controller.connections.isShared(connection) ? "Compartida" : "Solo este proyecto")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(state.destination(for: connection)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(state.destination(for: connection))
                }
                Spacer()
                Label(state.connectionLabel, systemImage: state.status == .connected ? "circle.fill" : "circle")
                    .font(.caption).foregroundStyle(state.status == .connected ? Color.green : .secondary)
            }
            HStack {
                Text(connection.username + " · " + connection.tls.label
                    + (connection.effectiveWritePolicy.badge.map { " · " + $0 } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Editar") { editing = connection }
                    .qaControl("connections.card.edit." + connection.name, title: "Editar",
                               enabled: !state.busy && state.status != .connecting) { editing = connection }
                Button(state.status == .connected ? "Desconectar" : "Conectar") {
                    toggle(connection, state: state)
                }
                .qaControl("connections.card.toggle." + connection.name,
                           title: state.status == .connected ? "Desconectar" : "Conectar",
                           enabled: !state.busy && state.status != .connecting) { toggle(connection, state: state) }
                Menu {
                    Button("Quitar conexión…", role: .destructive) { removing = connection }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .qaControl("connections.card.remove." + connection.name, title: "Quitar conexión…",
                               enabled: !state.busy && state.status != .connecting) { removing = connection }
            }.disabled(state.busy || state.status == .connecting)
            if state.inTransaction {
                Label("Transacción abierta", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let progress = controller.database.schema.progress[connection.id] {
                HStack {
                    WorkspaceProgress().controlSize(.mini)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancelar carga") { controller.database.schema.cancel(connection.id) }
                }
            }
            if let error = state.error ?? controller.database.schema.errors[connection.id] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if state.status == .connected {
                Button("Elegir bases de datos…") { chooseDatabases(connection) }
                    .qaControl("connections.card.databases." + connection.name, title: "Elegir bases de datos…") {
                        chooseDatabases(connection)
                    }
            }
        }
        .padding(16)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1) }
    }
}

private extension ConnectionsSettingsView {
    /// Conectar o desconectar, en un solo sitio: el botón cambia de título, no de acción.
    func toggle(_ connection: DatabaseConnection, state: DatabaseState) {
        if state.status == .connected { Task { _ = await controller.database.disconnect(connection) } }
        else { controller.database.connect(connection) }
    }

    func chooseDatabases(_ connection: DatabaseConnection) {
        Task { await controller.database.schema.discover(connection, client: controller.database.client, choose: true) }
    }
}

extension DatabaseState {
    var connectionLabel: String {
        if busy { return "En uso" }
        switch status {
        case .connected: return "Conectada"
        case .connecting: return "Conectando…"
        case .disconnected: return "Desconectada"
        }
    }
}

struct ConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var connection: DatabaseConnection
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var succeeded = false
    @State private var shared = false
    let controller: WorkspaceController

    init(connection: DatabaseConnection, controller: WorkspaceController) {
        self.controller = controller
        _connection = State(initialValue: connection)
        _shared = State(initialValue: controller.connections.allProfiles.contains { $0.id == connection.id }
            ? controller.connections.isShared(connection) : !controller.connections.hasProject)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MySQL · Standard (TCP/IP)").font(.headline)
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
                row("Usar SSL") {
                    Picker("TLS", selection: $connection.tls) {
                        ForEach(DatabaseConnection.TLSMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                    }.labelsHidden()
                }
                if connection.tls == .disabled {
                    GridRow {
                        Text("")
                        Text(insecureRemote
                             ? "Sin cifrado: usuario, contraseña y consultas viajan en texto plano fuera de esta Mac."
                             : "Sin cifrado. Aceptable solo porque el servidor es local.")
                            .font(.system(size: Theme.zoom(10)))
                            .foregroundStyle(insecureRemote ? Color.orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if connection.tls == .preferred || connection.tls == .required || connection.tls == .verifyCA {
                    GridRow {
                        Text("")
                        Text(tlsExplanation)
                            .font(.system(size: Theme.zoom(10))).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.textFieldStyle(.roundedBorder).disabled(busy)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Compartir con otros proyectos", isOn: $shared)
                    .disabled(busy || !controller.connections.hasProject
                              || controller.connections.otherProjectCount(connection) > 0)
                Text(shared
                     ? "Disponible en Compartidas. Los cambios se reflejan en los proyectos que la agregaron."
                     : "Solo se mostrará en este proyecto.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.connections.otherProjectCount(connection) > 0 {
                    Text("Para crear una versión privada, duplicá la conexión.").font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Parámetros avanzados") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Timeout (segundos)") {
                        TextField("10", value: $connection.connectTimeoutSeconds, format: .number.grouping(.never))
                    }
                    row("CA del servidor (PEM)") { TextField("/ruta/ca.pem", text: optionalText(\.tlsCAPath)) }
                    row("Nombre TLS / SNI") { TextField("Nombre del certificado", text: optionalText(\.tlsServerName)) }
                    row("Certificado cliente") { TextField("/ruta/cliente.pem", text: optionalText(\.tlsClientCertificatePath)) }
                    row("Clave cliente (PEM)") { TextField("/ruta/cliente-key.pem", text: optionalText(\.tlsClientKeyPath)) }
                }.textFieldStyle(.roundedBorder)
                Text("Timeout: 1–300 s para TCP y para autenticación. CA: solo en modos con verificación. "
                     + "Certificado y clave cliente: archivos PEM, clave sin contraseña. Se guardan las rutas, no su contenido.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.disabled(busy)
            VStack(alignment: .leading, spacing: 6) {
                Picker("Escritura", selection: Binding(get: { connection.effectiveWritePolicy },
                                                       set: { connection.writePolicy = $0.rawValue })) {
                        ForEach(DatabaseConnection.WritePolicy.allCases, id: \.self) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }.pickerStyle(.radioGroup)
                Text(connection.effectiveWritePolicy.detail + " La guarda es local: no reemplaza los permisos del servidor.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.disabled(busy)
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
                Text(message).font(.system(size: Theme.zoom(11))).foregroundStyle(succeeded ? Color.green : .red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .qaLabel("connection.sheet.message", message)
                if !succeeded {
                    Button("Exportar diagnóstico MySQL…", action: exportDiagnostics).disabled(busy)
                        .qaControl("connection.sheet.diagnostics", title: "Exportar diagnóstico MySQL…",
                                   enabled: !busy, action: exportDiagnostics)
                }
            }
            HStack {
                Button("Probar") { test() }.disabled(busy)
                    .qaControl("connection.sheet.test", title: "Probar", enabled: !busy, action: test)
                if busy { WorkspaceProgress().controlSize(.small) }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                    .qaControl("connection.sheet.cancel", title: "Cancelar", enabled: !busy) { dismiss() }
                Button("Guardar") { save() }.keyboardShortcut(.defaultAction).disabled(busy)
                    .qaControl("connection.sheet.save", title: "Guardar", enabled: !busy, action: save)
            }
        }
        .padding(24).frame(width: 580)
        .qaScreen("connection.sheet")
        .task {
            do { password = try CredentialStore.read(for: connection) }
            catch { message = error.localizedDescription }
        }
        .onChange(of: connection) { _, _ in message = nil }
        .onChange(of: password) { _, _ in message = nil }
        .interactiveDismissDisabled(busy)
    }

    /// Advierte cuando el usuario elige enviar credenciales en claro a un destino remoto.
    private var insecureRemote: Bool { connection.tls == .disabled && !connection.isLoopbackHost }

    private var tlsExplanation: String {
        switch connection.tls {
        case .preferred: "Usa TLS si está disponible; si no, conecta sin cifrado. No verifica el certificado."
        case .required: "Exige TLS, pero no verifica el certificado ni el nombre del servidor."
        case .verifyCA: "Exige TLS y verifica la CA, pero no el nombre del servidor."
        case .verified, .disabled: ""
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).font(.system(size: Theme.zoom(12))).foregroundStyle(.secondary)
            content()
        }
    }

    private func optionalText(_ keyPath: WritableKeyPath<DatabaseConnection, String?>) -> Binding<String> {
        Binding(get: { connection[keyPath: keyPath] ?? "" },
                set: { connection[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func test() {
        QAProbe.action("connection.test.request", ["name": connection.name,
                                                   "host": connection.host + ":" + String(connection.port),
                                                   "tls": connection.tls.label])
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let value = try connection.validated()
                try await controller.database.client.test(value, password: password)
                succeeded = true
                message = "Conexión correcta"
                QAProbe.sql("connection.test.ok", ["name": connection.name])
            } catch {
                succeeded = false
                message = MySQLClient.message(error)
                QAProbe.failure("connection.test.failed", message ?? "", ["name": connection.name])
            }
        }
    }

    private func exportDiagnostics() {
        QAProbe.action("connection.diagnostics.request", ["name": connection.name])
        Task {
            do { try await WorkspacePrompts.exportMySQLDiagnostics() }
            catch { self.message = AppError.describe(error) }
        }
    }

    private func save() {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await controller.connections.save(connection, password: password, shared: shared)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let document: EditorDocument
    @Bindable var controller: WorkspaceController
    @State private var processingFlash = false
    @State private var showingConnectionMenu = false
    @State private var showingDatabaseMenu = false
    private var selectorWidth: CGFloat { Theme.zoom(220) }

    private var connection: DatabaseConnection? { controller.connections.selected(for: document) }
    private var statusColor: Color {
        guard let connection else { return Color(red: 0.27, green: 0.29, blue: 0.32) }
        if document.sqlExecution.isRunning { return processingFlash ? .orange : .green }
        return controller.database.state(connection.id).status == .connected
            ? .green : Color(red: 0.27, green: 0.29, blue: 0.32)
    }
    private var statusDescription: String {
        guard let connection else { return "Sin conexión seleccionada" }
        if document.sqlExecution.isRunning { return "Procesando consulta" }
        return controller.database.state(connection.id).connectionLabel
    }
    private var canExecute: Bool {
        guard let connection, !controller.isReadOnly else { return false }
        let state = controller.database.states[connection.id]
        return state?.busy != true && state?.status != .connecting
    }

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 12) {
                HStack(spacing: 0) {
                    Button { showingConnectionMenu = true } label: {
                        HStack(spacing: Theme.zoom(8)) {
                            Image(systemName: "externaldrive").foregroundStyle(Theme.accent)
                                .overlay(alignment: .bottomTrailing) {
                                    Circle().fill(statusColor).frame(width: Theme.zoom(8), height: Theme.zoom(8))
                                        .overlay { Circle().strokeBorder(Theme.bar, lineWidth: Theme.zoom(1.5)) }
                                        .offset(x: Theme.zoom(3), y: Theme.zoom(3))
                                }
                            Text(connection?.name ?? "Elegir conexión…")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: Theme.zoom(9)))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, Theme.zoom(10)).padding(.trailing, Theme.zoom(7))
                        .frame(width: selectorWidth - Theme.zoom(27), height: Theme.zoom(28))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(document.sqlExecution.isRunning)
                    .help(connection.map { $0.name + " · " + controller.database.state($0.id).connectionLabel
                        + " · " + controller.database.state($0.id).destination(for: $0) }
                        ?? "Elegir conexión para este archivo")
                    .accessibilityLabel("Conexión del script")
                    .popover(isPresented: $showingConnectionMenu, arrowEdge: .bottom) {
                        SQLConnectionMenu(document: document, controller: controller,
                                          isPresented: $showingConnectionMenu)
                    }
                    Button { controller.database.showingConnections = true } label: {
                        Image(systemName: "gearshape").font(.system(size: Theme.zoom(13)))
                            .frame(width: Theme.zoom(27), height: Theme.zoom(28))
                    }
                    .buttonStyle(.plain).help("Administrar conexiones").accessibilityLabel("Administrar conexiones")
                    .qaControl("sql.toolbar.manageConnections", title: "Administrar conexiones") {
                        controller.database.showingConnections = true
                    }
                }
                .background(Theme.surfaceInk.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                if let connection {
                    let state = controller.database.state(connection.id)
                    let names = controller.database.schema.preference(connection).visible
                    Button { showingDatabaseMenu = true } label: {
                        HStack(spacing: Theme.zoom(8)) {
                            Image(systemName: "cylinder")
                            Text(state.currentDatabase.isEmpty ? "Base…" : state.currentDatabase)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: Theme.zoom(9)))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Theme.zoom(10))
                        .frame(width: selectorWidth, height: Theme.zoom(28))
                    }
                    .buttonStyle(.plain).disabled(!canExecute || names.isEmpty)
                    .background(Theme.surfaceInk.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .help("Base de datos del archivo: " + (state.currentDatabase.isEmpty ? "sin elegir" : state.currentDatabase))
                    .accessibilityLabel("Base de datos del archivo")
                    .popover(isPresented: $showingDatabaseMenu, arrowEdge: .bottom) {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 2) {
                                ForEach(names, id: \.self) { name in
                                    Button {
                                        controller.database.selectDatabase(name, connection: connection)
                                        showingDatabaseMenu = false
                                    } label: {
                                        HStack {
                                            Text(name).lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 0)
                                            if name == state.currentDatabase {
                                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                            }
                                        }
                                        .padding(.horizontal, Theme.zoom(10))
                                        .frame(height: Theme.zoom(32))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(Theme.zoom(4))
                        }
                        .frame(width: selectorWidth,
                               height: Theme.zoom(CGFloat(min(names.count, 6)) * 34 + 8))
                        .scrollIndicators(names.count > 6 ? .visible : .hidden)
                    }
                }
                Spacer(minLength: 4)
                SQLTimeoutControl(execution: document.sqlExecution)
                    .padding(.horizontal, Theme.zoom(7)).frame(height: Theme.zoom(28))
                    .background(Theme.surfaceInk.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                if document.sqlExecution.isRunning {
                    Button { controller.database.cancel(document.sqlExecution) } label: {
                        Image(systemName: "stop.fill")
                    }.disabled(document.sqlExecution.isCancelling)
                        .help("Cancelar ejecución").accessibilityLabel("Cancelar ejecución")
                        .qaControl("sql.toolbar.cancel", title: "Cancelar",
                                   enabled: !document.sqlExecution.isCancelling) {
                            controller.database.cancel(document.sqlExecution)
                        }
                } else {
                    Button(action: controller.executeSQL) {
                        Image(systemName: "play.fill")
                            .foregroundStyle(canExecute ? Color(nsColor: .systemGreen) : Color.secondary)
                    }
                        .disabled(!canExecute)
                        .help(document.selectedRange.length > 0 ? "Ejecutar selección (⌘↩)"
                            : "Ejecutar sentencia actual (⌘↩)")
                        .accessibilityLabel("Ejecutar selección o sentencia")
                        .qaControl("sql.toolbar.execute", title: "Ejecutar", enabled: canExecute,
                                   action: controller.executeSQL)
                    Button(action: controller.executeSQLFile) {
                        Image(systemName: "doc.text")
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "play.fill")
                                    .foregroundStyle(canExecute ? Color(nsColor: .systemGreen) : Color.secondary)
                                    .font(.system(size: Theme.zoom(7)))
                                    .padding(Theme.zoom(1))
                                    .background(Theme.bar, in: RoundedRectangle(cornerRadius: 2))
                                    .offset(x: Theme.zoom(3), y: Theme.zoom(2))
                            }
                    }
                        .disabled(!canExecute).help("Ejecutar archivo completo")
                        .accessibilityLabel("Ejecutar archivo completo")
                        .qaControl("sql.toolbar.executeFile", title: "Ejecutar archivo completo", enabled: canExecute,
                                   action: controller.executeSQLFile)
                }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        if let connection, let error = controller.database.state(connection.id).error {
            Text(error).font(Theme.interfaceFont(12)).foregroundStyle(.orange).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8)
        }
        }
        .background(Theme.bar)
        .qaScreen("sql.toolbar")
        .task(id: "\(document.sqlExecution.isRunning)-\(reduceMotion)") {
            guard document.sqlExecution.isRunning else { processingFlash = false
                return }
            processingFlash = true
            guard !reduceMotion else { return }
            while !Task.isCancelled && document.sqlExecution.isRunning {
                do { try await Task.sleep(for: .milliseconds(Int.random(in: 240...720))) }
                catch { break }
                processingFlash.toggle()
            }
            processingFlash = false
        }
    }

}

private struct SQLConnectionMenu: View {
    let document: EditorDocument
    @Bindable var controller: WorkspaceController
    @Binding var isPresented: Bool
    @State private var search = ""

    private var recent: [DatabaseConnection] {
        let selected = controller.connections.selected(for: document).map { [$0] } ?? []
        var seen = Set<UUID>()
        return (selected + controller.connections.recentProfiles)
            .filter { seen.insert($0.id).inserted && matches($0) }.prefix(3).map { $0 }
    }

    private var all: [DatabaseConnection] {
        let recentIDs = Set(recent.map(\.id))
        return controller.connections.profiles.filter { !recentIDs.contains($0.id) && matches($0) }
    }

    private func matches(_ connection: DatabaseConnection) -> Bool {
        search.isEmpty || connection.name.localizedStandardContains(search)
            || connection.host.localizedStandardContains(search)
            || connection.username.localizedStandardContains(search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar conexión…", text: $search)
                    .textFieldStyle(.plain).accessibilityLabel("Buscar conexión")
            }
            .padding(.horizontal, 10).frame(height: Theme.zoom(30))
            .background(Theme.surfaceInk.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(10)

            if !recent.isEmpty {
                sectionTitle("RECIENTES")
                ForEach(recent) { profile in connectionRow(profile) }
            }
            if !all.isEmpty {
                sectionTitle("TODAS")
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(all) { profile in connectionRow(profile) }
                    }
                }
                .frame(height: Theme.zoom(CGFloat(min(all.count, 4)) * 54))
                .scrollIndicators(all.count > 4 ? .visible : .hidden)
            }
            if recent.isEmpty && all.isEmpty {
                Text(search.isEmpty ? "No hay conexiones guardadas." : "No se encontraron conexiones.")
                    .foregroundStyle(.secondary).font(Theme.interfaceFont(12)).padding(12)
            }
            Divider().padding(.top, 6)
            Button { openConnections() } label: { Label("Administrar", systemImage: "gearshape") }
                .buttonStyle(.plain).font(Theme.interfaceFont(12))
                .help("Administrar conexiones").padding(12)
        }
        .frame(width: Theme.zoom(340))
        .background(Theme.bar)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(Theme.interfaceFont(10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 3)
    }

    private func connectionRow(_ profile: DatabaseConnection) -> some View {
        let state = controller.database.state(profile.id)
        let selected = controller.connections.selected(for: document)?.id == profile.id
        return Button {
            controller.connections.select(profile.id, for: document)
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Circle().fill(state.status == .connected ? .green : Color.gray.opacity(0.55))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(Theme.interfaceFont(13)).lineLimit(1)
                    Text("\(profile.host):\(profile.port)").font(Theme.interfaceFont(11))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 12).frame(height: Theme.zoom(52))
            .background(Theme.surfaceInk.opacity(selected ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Seleccionar \(profile.name) · \(state.connectionLabel)")
        .accessibilityLabel("\(profile.name), \(state.connectionLabel)")
    }

    private func openConnections() {
        isPresented = false
        DispatchQueue.main.async {
            controller.database.showingConnections = true
        }
    }
}
