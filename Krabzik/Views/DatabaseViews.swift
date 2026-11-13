import AppKit
import SwiftUI

struct ConnectionsSettingsView: View {
    let controller: WorkspaceController
    var showsDone = false
    @Environment(\.dismiss) private var dismiss
    @State private var editing: DatabaseConnection?
    @State private var removing: DatabaseConnection?
    @State private var selectionHost = UUID()

    private var connectedCount: Int {
        controller.connections.profiles.filter { controller.database.states[$0.id]?.status == .connected }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Conexiones").font(.title2.weight(.semibold))
                    Text("Compartidas entre todos tus proyectos")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = DatabaseConnection() } label: {
                    Label("Nueva conexión", systemImage: "plus")
                }
            }.padding(20)
            HStack(spacing: 6) {
                Circle().fill(connectedCount > 0 ? Color.green : .secondary).frame(width: 6, height: 6)
                Text("\(connectedCount) abiertas · \(controller.connections.profiles.count) guardadas")
                Spacer()
                Text("MySQL · TCP/IP")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 16)
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    if controller.connections.profiles.isEmpty {
                        ContentUnavailableView("Tus bases de datos, en un solo lugar", systemImage: "externaldrive",
                                               description: Text("Agregá una conexión y elegila desde cualquier script SQL."))
                    }
                    ForEach(controller.connections.profiles) { connection in
                        connectionCard(connection)
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                Text("Cada script elige su conexión. Abrir otra no cierra las demás.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if showsDone { Button("Listo") { dismiss() }.keyboardShortcut(.cancelAction) }
            }.padding(20)
        }
        .background(Theme.background)
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
            Text("Se quitará de todos los proyectos. Los scripts que la usan quedarán sin conexión asignada.")
        }
    }

    private func connectionCard(_ connection: DatabaseConnection) -> some View {
        let state = controller.database.state(connection.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive").font(.title2).foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38).background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.name).font(.headline)
                    Text(state.destination(for: connection)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(state.destination(for: connection))
                }
                Spacer()
                Label(state.connectionLabel, systemImage: state.status == .connected ? "circle.fill" : "circle")
                    .font(.caption).foregroundStyle(state.status == .connected ? Color.green : .secondary)
            }
            HStack {
                Text(connection.username + " · " + connection.tls.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Editar") { editing = connection }
                Button(state.status == .connected ? "Desconectar" : "Conectar") {
                    if state.status == .connected { Task { _ = await controller.database.disconnect(connection) } }
                    else { controller.database.connect(connection) }
                }
                Menu {
                    Button("Quitar conexión…", role: .destructive) { removing = connection }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.disabled(state.busy || state.status == .connecting)
            if state.inTransaction {
                Label("Transacción abierta", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let progress = controller.database.schema.progress[connection.id] {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancelar carga") { controller.database.schema.cancel(connection.id) }
                }
            }
            if let error = state.error ?? controller.database.schema.errors[connection.id] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if state.status == .connected {
                Button("Elegir bases de datos…") {
                    Task { await controller.database.schema.discover(connection, client: controller.database.client, choose: true) }
                }
            }
        }
        .padding(16)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1) }
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
    let controller: WorkspaceController

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
                if !succeeded {
                    Button("Exportar diagnóstico MySQL…") {
                        Task {
                            do { try await WorkspacePrompts.exportMySQLDiagnostics() }
                            catch { self.message = AppError.describe(error) }
                        }
                    }.disabled(busy)
                }
            }
            HStack {
                Button("Probar") { test() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Guardar") { save() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(24).frame(width: 580)
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

    private var connection: DatabaseConnection? { controller.connections.selected(for: document) }
    private var canExecute: Bool {
        guard let connection, !controller.isReadOnly else { return false }
        let state = controller.database.states[connection.id]
        return state?.busy != true && state?.status != .connecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive").foregroundStyle(Theme.accent)
                Picker("Conexión del script", selection: Binding(get: { connection?.id },
                                                                 set: { controller.connections.select($0, for: document) })) {
                        Text("Elegir conexión…").tag(nil as UUID?)
                        ForEach(controller.connections.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 240)
                    .disabled(document.sqlExecution.isRunning)
                Button { controller.database.showingConnections = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }.help("Administrar conexiones globales").accessibilityLabel("Administrar conexiones")
                if let connection {
                    let state = controller.database.state(connection.id)
                    let names = controller.database.schema.preference(connection).visible
                    Picker("Base de datos", selection: Binding(get: { state.currentDatabase }, set: {
                        controller.database.selectDatabase($0, connection: connection)
                    })) {
                        Text(state.currentDatabase.isEmpty ? "Base…" : state.currentDatabase).tag(state.currentDatabase)
                        ForEach(names.filter { $0 != state.currentDatabase }, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 190).disabled(!canExecute)
                }
                Spacer(minLength: 4)
                SQLTimeoutControl(execution: document.sqlExecution)
                if let connection {
                    let state = controller.database.state(connection.id)
                    Button(state.status == .connected ? "Desconectar" : "Conectar") {
                        if state.status == .connected { Task { _ = await controller.database.disconnect(connection) } }
                        else { controller.database.connect(connection) }
                    }.disabled(state.busy || state.status == .connecting || document.sqlExecution.isRunning || controller.isReadOnly)
                }
                if document.sqlExecution.isRunning {
                    Button { controller.database.cancel(document.sqlExecution) } label: {
                        Label("Cancelar", systemImage: "stop.fill")
                    }.disabled(document.sqlExecution.isCancelling)
                } else {
                    Button(action: controller.executeSQL) { Label("Ejecutar", systemImage: "play.fill") }
                        .disabled(!canExecute).help("Ejecutar selección o sentencia bajo el cursor (⌘↩)")
                        .accessibilityLabel("Ejecutar SQL")
                }
            }
            HStack(spacing: 8) {
                if let connection {
                    let state = controller.database.state(connection.id)
                    Circle().fill(state.status == .connected ? Color.green : .secondary).frame(width: 6, height: 6)
                    Text(state.connectionLabel)
                    Text("·")
                    Text(state.destination(for: connection)).lineLimit(1).truncationMode(.middle).help(state.destination(for: connection))
                    if state.inTransaction { Text("· Transacción abierta").foregroundStyle(.orange) }
                } else {
                    Text("Elegí una conexión para ejecutar este archivo.")
                }
                Spacer(minLength: 0)
                Text("Por archivo").foregroundStyle(.tertiary)
            }.font(.system(size: Theme.zoom(11))).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.bar)
    }
}
