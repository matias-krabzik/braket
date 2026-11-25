import SwiftUI

struct EditorSearchBar: View {
    let document: EditorDocument
    let readOnly: Bool
    @Bindable var search: EditorSearch
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                field(icon: "magnifyingglass", placeholder: "Buscar", text: $search.query)
                    .focused($focused)
                    .onSubmit { search.navigate(backwards: NSEvent.modifierFlags.contains(.shift)) }
                Text(search.countLabel).font(Theme.interfaceFont(11)).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Coincidencias: " + search.countLabel)
                option("Aa", help: "Distinguir mayúsculas", selected: $search.options.caseSensitive)
                option("Ab", help: "Palabra completa", selected: $search.options.wholeWord)
                option(".*", help: "Expresión regular", selected: $search.options.regularExpression)
                icon("chevron.up", help: "Anterior (⇧⌘G)") { search.navigate(backwards: true) }
                    .disabled(search.matches.isEmpty || search.searching)
                icon("chevron.down", help: "Siguiente (⌘G)") { search.navigate() }
                    .disabled(search.matches.isEmpty || search.searching)
                icon("xmark", help: "Cerrar búsqueda (Esc)", action: search.hide)
            }
            if search.showsReplacement {
                HStack(spacing: 8) {
                    field(icon: "arrow.turn.down.right", placeholder: "Reemplazar por", text: $search.replacement)
                        .onSubmit { search.replace(all: false, allowed: !readOnly) }
                    Button("Reemplazar") { search.replace(all: false, allowed: !readOnly) }
                        .help("Reemplazar la coincidencia actual")
                        .disabled(readOnly || search.searching || search.matches.isEmpty)
                    Button("Reemplazar todo") { search.replace(all: true, allowed: !readOnly) }
                        .help("Reemplazar todas las coincidencias del archivo")
                        .disabled(readOnly || search.searching || search.matches.isEmpty)
                }
            }
            if let error = search.error {
                Text(error).font(Theme.interfaceFont(11)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(Theme.interfaceFont(12))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.bar, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border) }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .workspaceReveal(search.showsReplacement)
        .onExitCommand(perform: search.hide)
        .onAppear {
            focused = true
            search.schedule()
        }
        .onChange(of: search.focusRequest) { _, _ in focused = true }
        .onChange(of: search.query) { _, _ in search.schedule() }
        .onChange(of: search.options) { _, _ in search.schedule() }
        .onChange(of: document.previewRevision) { _, _ in search.schedule() }
    }

    private func field(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.plain).accessibilityLabel(placeholder)
        }
        .padding(.horizontal, 8).frame(height: 27)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border) }
    }

    private func option(_ title: String, help: String, selected: Binding<Bool>) -> some View {
        Button { selected.wrappedValue.toggle() } label: {
            Text(title).font(.system(size: Theme.zoom(12), weight: .medium, design: .monospaced))
                .frame(width: 27, height: 27)
                .background(selected.wrappedValue ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.fullArea).help(help).accessibilityLabel(help)
        .accessibilityAddTraits(selected.wrappedValue ? .isSelected : [])
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 27).contentShape(Rectangle())
        }.buttonStyle(.fullArea).help(help).accessibilityLabel(help)
    }
}
