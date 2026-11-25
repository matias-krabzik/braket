import SwiftUI

/// Selection and secondary actions are sibling buttons: no background hit target hidden beneath the label.
struct TerminalTabItem: View {
    let name: String
    let selected: Bool
    let busy: Bool
    let editable: Bool
    let select: () -> Void
    let configure: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Image(systemName: "terminal").font(Theme.interfaceFont(12))
                    Text(name).font(Theme.interfaceFont(12, weight: .semibold)).lineLimit(1)
                    if busy { Circle().fill(.green).frame(width: 6, height: 6) }
                }
                .padding(.leading, 10).padding(.trailing, 7).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.fullArea).accessibilityLabel(name)
            .accessibilityAddTraits(selected ? .isSelected : []).help("Mostrar \(name)")
            Button(action: configure) {
                Image(systemName: "gearshape").font(Theme.interfaceFont(12))
                    .frame(width: 26, height: 28).contentShape(Rectangle())
            }.buttonStyle(.fullArea).help("Configurar terminal y variables de entorno").disabled(!editable)
            Button(action: close) {
                Image(systemName: "xmark").font(Theme.interfaceFont(10))
                    .frame(width: 27, height: 28).contentShape(Rectangle())
            }.buttonStyle(.fullArea).help("Cerrar \(name)")
        }
        .background(selected ? Theme.surfaceInk.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
