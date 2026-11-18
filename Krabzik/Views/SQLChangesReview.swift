import SwiftUI

struct SQLChangesReview: View {
    let rows: [SQLRowChange]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(row.action, systemImage: row.action == "Eliminar fila" ? "trash" : "square.and.pencil")
                            .font(Theme.interfaceFont(13, weight: .semibold))
                        Spacer()
                        Text(row.identity).font(Theme.codeFont()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            heading("Campo", width: 135)
                            heading("Valor anterior", width: 235)
                            heading("Valor nuevo", width: 235)
                        }
                        Divider().gridCellColumns(3)
                        ForEach(row.fields) { field in
                            GridRow {
                                Text(field.name).font(Theme.codeFont()).textSelection(.enabled)
                                    .frame(width: 135, alignment: .leading)
                                SQLReviewValue(value: field.before).frame(maxWidth: .infinity, alignment: .leading)
                                SQLReviewValue(value: field.after).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider().gridCellColumns(3)
                        }
                    }
                }
                .padding(14)
                .background(Theme.bar, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func heading(_ text: String, width: CGFloat) -> some View {
        Text(text).font(Theme.interfaceFont(12, weight: .semibold)).foregroundStyle(.secondary)
            .frame(minWidth: width, alignment: .leading)
    }
}

private struct SQLReviewValue: View {
    let value: SQLCellValue?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch value {
            case .text(let text):
                Text("“" + text + "”").font(Theme.codeFont()).textSelection(.enabled)
                    .lineLimit(expanded ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
                if text.count > 200 || text.filter({ $0 == "\n" }).count > 5 {
                    Button(expanded ? "Ver menos" : "Ver valor completo") { expanded.toggle() }
                        .buttonStyle(.link).font(Theme.interfaceFont(11))
                }
            case .null:
                Text("NULL").font(Theme.codeFont()).foregroundStyle(.secondary)
                    .help("Valor nulo")
            case .serverDefault:
                Text("DEFAULT").font(Theme.codeFont()).foregroundStyle(.secondary)
                    .help("Se usará el valor predeterminado de la columna")
            case nil:
                Text("—").foregroundStyle(.tertiary).help("No corresponde a esta operación")
            }
        }
    }
}
