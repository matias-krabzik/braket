import SwiftUI

/// Un control de la interfaz tal como lo ve una prueba: qué dice, si se puede usar, y en
/// qué pantalla está.
struct QAControl: Sendable, Equatable {
    let id: String
    let title: String
    let enabled: Bool
    let screen: String
}

enum QAControlError: Error, LocalizedError {
    case missing(String, visible: [String])
    case disabled(String, title: String)

    var errorDescription: String? {
        switch self {
        case .missing(let id, let visible):
            return "No hay ningún control «\(id)» en pantalla. Visibles: " +
                (visible.isEmpty ? "ninguno" : visible.sorted().joined(separator: ", "))
        case .disabled(let id, let title):
            return "El control «\(id)» («\(title)») está deshabilitado: la interfaz no deja usarlo."
        }
    }
}

/// Qué está ofreciendo la interfaz en este momento.
///
/// Es la pieza que permite afirmar lo que pidió el usuario —«si un botón dice Editar,
/// que lo que se edita quede en modo edición»— en vez de llamar al controlador por
/// atajo: la prueba busca el control por su identificador, comprueba que esté habilitado
/// y **ejecuta la misma acción que el botón**. Un botón que desaparece, cambia de título
/// o queda deshabilitado rompe la prueba, que es justo lo que se quiere.
///
/// Las vistas se registran con `.qaControl(...)`. En Release el modificador no hace nada
/// y este registro queda vacío.
///
/// Confinado al main actor, como las vistas.
@MainActor
enum QAControls {
    #if DEBUG
    private struct Entry {
        var control: QAControl
        var action: () -> Void
    }

    private struct Field {
        var id: String
        var screen: String
        var read: () -> String
        var write: (String) -> Void
    }

    private static var entries: [UUID: Entry] = [:]
    private static var fields: [UUID: Field] = [:]
    private static var screens: [UUID: String] = [:]

    /// Todo lo que está en pantalla, ordenado por identificador.
    static var visible: [QAControl] {
        entries.values.map(\.control).sorted { $0.id < $1.id }
    }

    /// Las pantallas montadas, de la de fondo a la de adelante.
    static var screenStack: [String] {
        screens.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value)
    }

    static func control(_ id: String) -> QAControl? {
        entries.values.first { $0.control.id == id }?.control
    }

    static func exists(_ id: String) -> Bool { control(id) != nil }

    /// Usa el control como lo usaría la persona. Falla si no está o si está deshabilitado.
    static func tap(_ id: String) throws {
        guard let entry = entries.values.first(where: { $0.control.id == id }) else {
            throw QAControlError.missing(id, visible: entries.values.map(\.control.id))
        }
        guard entry.control.enabled else {
            throw QAControlError.disabled(id, title: entry.control.title)
        }
        QAProbe.emit(.control, "control.tap", ["id": id, "title": entry.control.title,
                                               "screen": entry.control.screen])
        entry.action()
    }

    /// Lo que dice un campo de texto en este momento, o `nil` si no está en pantalla.
    static func field(_ id: String) -> String? {
        fields.values.first { $0.id == id }.map { $0.read() }
    }

    /// Escribe en un campo como lo haría la persona. Falla si el campo no está en pantalla.
    static func type(_ text: String, into id: String) throws {
        guard let field = fields.values.first(where: { $0.id == id }) else {
            throw QAControlError.missing(id, visible: fields.values.map(\.id) + entries.values.map(\.control.id))
        }
        QAProbe.emit(.control, "control.type", ["id": id, "screen": field.screen, "text": QAField.text(text)])
        field.write(text)
    }

    static func registerField(_ token: UUID, id: String, screen: String,
                              read: @escaping () -> String, write: @escaping (String) -> Void) {
        let existed = fields[token] != nil
        fields[token] = Field(id: id, screen: screen, read: read, write: write)
        guard !existed else { return }
        QAProbe.emit(.control, "field.appear", ["id": id, "screen": screen])
    }

    static func unregisterField(_ token: UUID) {
        guard let field = fields.removeValue(forKey: token) else { return }
        QAProbe.emit(.control, "field.disappear", ["id": field.id, "screen": field.screen])
    }

    static func register(_ token: UUID, _ control: QAControl, action: @escaping () -> Void) {
        let previous = entries[token]?.control
        entries[token] = Entry(control: control, action: action)
        guard previous != control else { return }
        QAProbe.emit(.control, previous == nil ? "control.appear" : "control.change",
                     ["id": control.id, "title": control.title, "screen": control.screen,
                      "enabled": QAField.bool(control.enabled)])
    }

    static func unregister(_ token: UUID) {
        guard let entry = entries.removeValue(forKey: token) else { return }
        QAProbe.emit(.control, "control.disappear", ["id": entry.control.id, "screen": entry.control.screen])
    }

    static func enter(screen: String, token: UUID) {
        screens[token] = screen
        QAProbe.emit(.control, "screen.appear", ["screen": screen])
    }

    static func leave(token: UUID) {
        guard let screen = screens.removeValue(forKey: token) else { return }
        QAProbe.emit(.control, "screen.disappear", ["screen": screen])
    }

    /// Para el teardown de una prueba: deja el registro sin nada de la corrida anterior.
    static func clear() {
        entries.removeAll()
        fields.removeAll()
        screens.removeAll()
    }
    #else
    static func field(_ id: String) -> String? { nil }
    static func type(_ text: String, into id: String) throws {}
    static func registerField(_ token: UUID, id: String, screen: String,
                              read: @escaping () -> String, write: @escaping (String) -> Void) {}
    static func unregisterField(_ token: UUID) {}
    static var visible: [QAControl] { [] }
    static var screenStack: [String] { [] }
    static func control(_ id: String) -> QAControl? { nil }
    static func exists(_ id: String) -> Bool { false }
    static func tap(_ id: String) throws {}
    static func register(_ token: UUID, _ control: QAControl, action: @escaping () -> Void) {}
    static func unregister(_ token: UUID) {}
    static func enter(screen: String, token: UUID) {}
    static func leave(token: UUID) {}
    static func clear() {}
    #endif
}

extension View {
    /// Le da identidad de QA a un control. `action` tiene que ser **la misma acción** que
    /// ejecuta el control, y `enabled` la misma condición de su `.disabled(...)`: eso es
    /// lo que hace que la prueba ejercite la interfaz y no un camino paralelo.
    ///
    /// En Release devuelve la vista sin tocar.
    func qaControl(_ id: String, title: String, enabled: Bool = true,
                   action: @escaping () -> Void) -> some View {
        #if DEBUG
        return modifier(QAControlModifier(id: id, title: title, enabled: enabled, action: action))
        #else
        return self
        #endif
    }

    /// Le da identidad de QA a un campo de texto, para poder leerlo y **escribir** en él.
    ///
    /// Sin esto un escenario no puede completar un formulario: el estado del campo vive en
    /// la vista. `text` tiene que ser el mismo binding que usa el `TextField`.
    func qaField(_ id: String, text: Binding<String>) -> some View {
        #if DEBUG
        return modifier(QAFieldModifier(id: id, text: text))
        #else
        return self
        #endif
    }

    /// Registra un texto de la interfaz para poder afirmar **qué dice**.
    ///
    /// Un mensaje de error no es un control, pero es lo que el usuario lee; sin esto un
    /// escenario solo podría afirmar el estado interno. Queda registrado como un control
    /// sin acción, así que `assertControl(id, title:)` sirve igual.
    func qaLabel(_ id: String, _ text: String) -> some View {
        #if DEBUG
        return modifier(QAControlModifier(id: id, title: text, enabled: true, action: {}))
        #else
        return self
        #endif
    }

    /// Registra las órdenes de los menús como controles de QA.
    ///
    /// El menú de la app vive en la `Scene`, que los escenarios no montan; registrarlas
    /// desde la vista es lo que permite afirmar que «Reducir zoom» quedó deshabilitado en
    /// el tope, con el mismo título y la misma condición que ve el usuario.
    func qaCommands(_ commands: [AppCommand]) -> some View {
        #if DEBUG
        return modifier(QACommandsModifier(commands: commands))
        #else
        return self
        #endif
    }

    /// Marca una pantalla —una hoja, un panel, una vista de nivel alto— para poder
    /// afirmar qué está montado.
    func qaScreen(_ name: String) -> some View {
        #if DEBUG
        return modifier(QAScreenModifier(name: name))
        #else
        return self
        #endif
    }
}

#if DEBUG
private struct QAControlModifier: ViewModifier {
    let id: String
    let title: String
    let enabled: Bool
    let action: () -> Void
    @Environment(\.qaScreenName) private var screen
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { register() }
            .onDisappear { QAControls.unregister(token) }
            .onChange(of: enabled) { register() }
            .onChange(of: title) { register() }
            .onChange(of: screen) { register() }
    }

    private func register() {
        guard QAProbe.isActive else { return }
        QAControls.register(token, QAControl(id: id, title: title, enabled: enabled, screen: screen),
                            action: action)
    }
}

private struct QAFieldModifier: ViewModifier {
    let id: String
    @Binding var text: String
    @Environment(\.qaScreenName) private var screen
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { register() }
            .onDisappear { QAControls.unregisterField(token) }
            .onChange(of: screen) { register() }
    }

    private func register() {
        guard QAProbe.isActive else { return }
        QAControls.registerField(token, id: id, screen: screen, read: { text }, write: { text = $0 })
    }
}

private struct QACommandsModifier: ViewModifier {
    let commands: [AppCommand]
    @State private var tokens: [String: UUID] = [:]

    /// Lo que hace falta volver a registrar: cambió un título o una habilitación.
    @MainActor private var signature: String {
        commands.map { "\($0.id)·\($0.title)·\($0.enabled)" }.joined(separator: "|")
    }

    func body(content: Content) -> some View {
        content
            .onAppear { register() }
            .onChange(of: signature) { register() }
            .onDisappear {
                for token in tokens.values { QAControls.unregister(token) }
                tokens.removeAll()
            }
    }

    @MainActor private func register() {
        guard QAProbe.isActive else { return }
        for command in commands {
            let token = tokens[command.id] ?? UUID()
            tokens[command.id] = token
            QAControls.register(token, QAControl(id: command.id, title: command.title,
                                                 enabled: command.enabled, screen: "menu"),
                                action: command.run)
        }
    }
}

private struct QAScreenModifier: ViewModifier {
    let name: String
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.qaScreenName, name)
            .onAppear { if QAProbe.isActive { QAControls.enter(screen: name, token: token) } }
            .onDisappear { QAControls.leave(token: token) }
    }
}
#endif

private struct QAScreenNameKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var qaScreenName: String {
        get { self[QAScreenNameKey.self] }
        set { self[QAScreenNameKey.self] = newValue }
    }
}
