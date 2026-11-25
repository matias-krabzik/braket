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
        var codeTypography: CodeTypography
        var resultTypography: CodeTypography
        var codeFontSize: Double
        var resultFontSize: Double
        var editorOptions: EditorOptions
        var restoreLastState: Bool

        init(settings: AppSettings) {
            defaultSQLTimeoutSeconds = settings.defaultSQLTimeoutSeconds
            editorOptions = settings.editorOptions
            theme = settings.theme
            uiScale = settings.uiScale
            codeTypography = settings.codeTypography
            resultTypography = settings.resultTypography
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
        settings.codeTypography = draft.codeTypography
        settings.resultTypography = draft.resultTypography
        settings.codeFontSize = draft.codeFontSize
        settings.resultFontSize = draft.resultFontSize
        settings.restoreLastState = draft.restoreLastState
    }

    private func cancel() {
        draft = GeneralDraft(settings: settings)
        dismiss()
    }

    private enum Page: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Apariencia"
        case texts = "Textos"
        case editor = "Editor"
        case sql = "SQL"
        case connections = "Conexiones"
        case updates = "Actualizaciones"

        var id: Self { self }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .editor: "curlybraces"
            case .sql: "terminal"
            case .texts: "textformat"
            case .connections: "externaldrive"
            case .updates: "arrow.triangle.2.circlepath"
            }
        }
        var searchTerms: String {
            switch self {
            case .general: "general al iniciar abrir último estado recuperar proyecto pestañas sesión"
            case .appearance: "apariencia tema grafito claro oscuro zoom interfaz"
            case .editor: "editor paréntesis comillas guías indentación formato cierre variables sentencia palabras clave SQL"
            case .sql: "sql ejecución timeout tiempo consultas diagnóstico mysql exportar"
            case .texts: "apariencia textos tipografía fuentes código resultados tamaño negrita SF Mono Menlo JetBrains Fira Source"
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
                        ForEach(filteredPages) { item in
                            Button { page = item } label: {
                                Label(item.rawValue, systemImage: item.icon)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9).padding(.vertical, 7)
                                    .padding(.leading, item == .texts ? 18 : 0)
                                    .background(page == item ? Theme.accent.opacity(0.22) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.fullArea)
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
                case .appearance: appearance
                case .editor: editor
                case .sql: sql
                case .texts:
                    TextAppearanceSettings(code: $draft.codeTypography, results: $draft.resultTypography,
                                           codeSize: $draft.codeFontSize, resultSize: $draft.resultFontSize, theme: draft.theme)
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
        settingsForm("General") {
            Section("Al iniciar") {
                Toggle("Abrir último estado", isOn: $draft.restoreLastState)
                Text("Recupera el proyecto y las pestañas que dejaste abiertos al salir.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var appearance: some View {
        settingsForm("Apariencia") {
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
        }
    }

    private var editor: some View {
        settingsForm("Editor") {
            Section("Asistencia al editar") {
                Toggle("Resaltar pares y delimitadores sin pareja", isOn: $draft.editorOptions.matchBrackets)
                Toggle("Colorear paréntesis por profundidad", isOn: $draft.editorOptions.rainbowBrackets)
                Toggle("Mostrar guías de indentación", isOn: $draft.editorOptions.indentationGuides)
                Toggle("Cerrar paréntesis y comillas automáticamente", isOn: $draft.editorOptions.autoClose)
                Toggle("Resaltar referencias de variables SQL", isOn: $draft.editorOptions.variableReferences)
                Toggle("Marcar la sentencia SQL activa", isOn: $draft.editorOptions.activeStatement)
            }
            Section("Formato SQL") {
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
        }
    }

    private var sql: some View {
        settingsForm("SQL") {
            Section("Ejecución") {
                HStack {
                    Text("Timeout predeterminado por sentencia")
                    Spacer()
                    TextField("Segundos", value: $draft.defaultSQLTimeoutSeconds, format: .number.grouping(.never))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .frame(width: 80).accessibilityLabel("Timeout SQL de la aplicación en segundos")
                    Text("segundos")
                }
                Text("1–3600 segundos. Cada sentencia tiene su propio límite, incluso al ejecutar un archivo completo. "
                     + "Se usa cuando el proyecto y el archivo no tienen un timeout propio.")
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
    }

    private func settingsForm<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form {
            Section {
                Text(title).font(.title2.weight(.semibold))
                    .listRowBackground(Color.clear)
            }
            content()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(12)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(Theme.colorScheme)
    }
}
