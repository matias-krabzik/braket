import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let controller: WorkspaceController
    var showsDone = false
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GeneralDraft

    init(settings: AppSettings, controller: WorkspaceController, showsDone: Bool = false) {
        self.settings = settings
        self.controller = controller
        self.showsDone = showsDone
        _draft = State(initialValue: GeneralDraft(settings: settings))
    }

    @MainActor private struct GeneralDraft: Equatable {
        var defaultSQLTimeoutSeconds: Int
        var theme: AppTheme
        var uiScale: Double
        var codeFontSize: Double
        var resultFontSize: Double
        var editorOptions: EditorOptions
        var restoreLastState: Bool

        init(settings: AppSettings) {
            defaultSQLTimeoutSeconds = settings.defaultSQLTimeoutSeconds
            editorOptions = settings.editorOptions
            theme = settings.theme
            uiScale = settings.uiScale
            codeFontSize = settings.codeFontSize
            resultFontSize = settings.resultFontSize
            restoreLastState = settings.restoreLastState
        }
    }

    private var hasChanges: Bool { draft != GeneralDraft(settings: settings) }

    private func apply() {
        settings.defaultSQLTimeoutSeconds = min(3600, max(1, draft.defaultSQLTimeoutSeconds))
        settings.editorOptions = draft.editorOptions
        settings.theme = draft.theme
        settings.uiScale = draft.uiScale
        settings.codeFontSize = draft.codeFontSize
        settings.resultFontSize = draft.resultFontSize
        settings.restoreLastState = draft.restoreLastState
    }

    private func cancel() {
        draft = GeneralDraft(settings: settings)
        dismiss()
    }

    private enum Page: String, CaseIterable, Identifiable {
        case general = "Apariencia"
        case connections = "Conexiones"
        case updates = "Actualizaciones"

        var id: Self { self }
        var icon: String {
            switch self {
            case .general: "paintpalette"
            case .connections: "externaldrive"
            case .updates: "arrow.triangle.2.circlepath"
            }
        }
        var searchTerms: String {
            switch self {
            case .general:
                "apariencia tema grafito fuente código resultados zoom iniciar diagnóstico mysql "
                    + "editor paréntesis guías formato cierre sql timeout tiempo consultas"
            case .connections: "conexiones base datos mysql"
            case .updates: "actualizaciones versión"
            }
        }
    }

    @State private var page: Page = .general
    @State private var search = ""

    private var filteredPages: [Page] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? Page.allCases : Page.allCases.filter { $0.searchTerms.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Configuración").font(.headline).padding(.horizontal, 8)
                TextField("Buscar ajustes", text: $search)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GENERAL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.top, 4)
                        ForEach(filteredPages) { item in
                            Button { page = item } label: {
                                Label(item.rawValue, systemImage: item.icon)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9).padding(.vertical, 7)
                                    .background(page == item ? Theme.accent.opacity(0.22) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(page == item ? .isSelected : [])
                        }
                        if filteredPages.isEmpty {
                            Text("Sin resultados").font(.callout).foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(width: 210).background(Theme.sidebar)
            Divider()
            Group {
                switch page {
                case .general: general
                case .connections: ConnectionsSettingsView(controller: controller)
                case .updates: UpdatesSettingsView()
                }
            }
            .workspaceReveal(page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancelar", action: cancel).keyboardShortcut(.cancelAction)
                Button("Aplicar", action: apply)
                    .disabled(!hasChanges)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Guardar") {
                    apply()
                    dismiss()
                }
                .disabled(!hasChanges)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.bar)
        }
        .frame(width: 930, height: 700)
        .background(Theme.background)
        .background(SettingsTerminationBridge(coordinator: controller.settingsClose,
                                              hasChanges: { hasChanges }, save: apply,
                                              discard: { draft = GeneralDraft(settings: settings) },
                                              dismiss: { dismiss() }))
        .tint(Theme.accent)
        .preferredColorScheme(Theme.colorScheme)
    }

    private var general: some View {
        Form {
            Section {
                Text("Apariencia").font(.title2.weight(.semibold))
                    .listRowBackground(Color.clear)
            }
            Section("Apariencia") {
                Picker("Tema", selection: $draft.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Text(draft.theme.detail)
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Slider(value: $draft.uiScale, in: AppSettings.uiScaleRange, step: 0.1) {
                        Text("Zoom de interfaz")
                    }
                    Text("\(Int((draft.uiScale * 100).rounded())) %")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                    Button("Restablecer") { draft.uiScale = 1 }
                        .disabled(draft.uiScale == 1)
                }
            }
            Section("Tamaño de fuente") {
                HStack {
                    Slider(value: $draft.codeFontSize, in: AppSettings.fontSizeRange, step: 1) {
                        Text("Código")
                    }
                    Text("\(Int(draft.codeFontSize)) pt").frame(width: 52, alignment: .trailing)
                    Button("Restablecer") { draft.codeFontSize = 14 }.disabled(draft.codeFontSize == 14)
                }
                HStack {
                    Slider(value: $draft.resultFontSize, in: AppSettings.fontSizeRange, step: 1) {
                        Text("Resultados")
                    }
                    Text("\(Int(draft.resultFontSize)) pt").frame(width: 52, alignment: .trailing)
                    Button("Restablecer") { draft.resultFontSize = 14 }.disabled(draft.resultFontSize == 14)
                }
            }
            Section("SQL") {
                HStack {
                    Text("Timeout predeterminado por sentencia")
                    Spacer()
                    TextField("Segundos", value: $draft.defaultSQLTimeoutSeconds, format: .number.grouping(.never))
                        .frame(width: 80).accessibilityLabel("Timeout SQL de la aplicación en segundos")
                    Text("segundos")
                }
                Text("1–3600 segundos. Cada sentencia tiene su propio límite, incluso al ejecutar un archivo completo. "
                     + "Se usa cuando el proyecto y el archivo no tienen un timeout propio.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Editor") {
                Toggle("Resaltar pares y delimitadores sin pareja", isOn: $draft.editorOptions.matchBrackets)
                Toggle("Colorear paréntesis por profundidad", isOn: $draft.editorOptions.rainbowBrackets)
                Toggle("Mostrar guías de indentación", isOn: $draft.editorOptions.indentationGuides)
                Toggle("Cerrar paréntesis y comillas automáticamente", isOn: $draft.editorOptions.autoClose)
                Toggle("Resaltar referencias de variables SQL", isOn: $draft.editorOptions.variableReferences)
                Toggle("Marcar la sentencia SQL activa", isOn: $draft.editorOptions.activeStatement)
                Picker("Indentación", selection: $draft.editorOptions.indentWidth) {
                    Text("2 espacios").tag(2)
                    Text("4 espacios").tag(4)
                }
                Picker("Palabras clave SQL", selection: $draft.editorOptions.keywordCase) {
                    Text("MAYÚSCULAS").tag("upper")
                    Text("minúsculas").tag("lower")
                    Text("Conservar").tag("preserve")
                }
                Text("Formatear selección o archivo SQL: ⌥⌘L").font(.callout).foregroundStyle(.secondary)
            }
            Section("Vista previa") {
                typographyPreview
            }
            Section("Al iniciar") {
                Toggle("Abrir último estado", isOn: $draft.restoreLastState)
                Text("Recupera el proyecto y las pestañas que dejaste abiertos al salir.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Diagnóstico MySQL") {
                Button("Exportar diagnóstico MySQL…") {
                    Task {
                        do { try await WorkspacePrompts.exportMySQLDiagnostics() }
                        catch { controller.errors.report(error) }
                    }
                }
                Text("Los intentos de conexión se registran en esta Mac. No se guardan contraseñas ni consultas SQL.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(12)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(Theme.colorScheme)
    }
    private var typographyPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("consulta.sql", systemImage: "doc.text")
                .font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading).background(Theme.bar)
            VStack(alignment: .leading, spacing: 4) {
                Text("SELECT id, nombre").foregroundStyle(Color(nsColor: EditorPalette.blue))
                Text("FROM clientes")
                Text("WHERE activo = 1;")
            }
            .font(.system(size: draft.codeFontSize, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
            Label("Resultados", systemImage: "tablecells")
                .font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading).background(Theme.bar)
            VStack(alignment: .leading, spacing: 5) {
                Text("id     nombre").fontWeight(.medium)
                Text("1      María Pérez")
                Text("2      Martín López")
            }
            .font(.system(size: draft.resultFontSize, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Theme.border) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vista previa de código y resultados")
    }

}
