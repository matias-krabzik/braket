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

    private static var entries: [UUID: Entry] = [:]
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
        screens.removeAll()
    }
    #else
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
