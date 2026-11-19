import Foundation

/// Snapshot de la píldora pulsada: filtrar y copiar no vuelve a consultar MySQL.
struct SQLValueDetail {
    struct Row {
        let index: Int
        let value: String
        let sql: String
    }
    let title: String
    let subtitle: String
    let footer: String
    let origin: String?
    let rows: [Row]

    init(_ value: SQLSetValue) {
        title = value.listSnapshot?.name ?? value.name
        origin = value.detail
        if let list = value.listSnapshot {
            rows = list.values.enumerated().map { offset, element in
                let text: String
                switch element { case .number(let number): text = number
                case .text(let string): text = string }
                return Row(index: offset + 1, value: text, sql: element.sql)
            }
            let type: String
            switch list.values.first { case .number?: type = "Número"
            case .text?: type = "Texto"
            case nil: type = "Lista vacía" }
            subtitle = "\(rows.count) valores · " + type
            footer = "Captura en memoria"
        } else if value.isList {
            rows = []
            subtitle = value.value
            footer = "Ejecutá SET LIST para ver sus valores"
        } else {
            rows = [Row(index: 1, value: value.value, sql: value.value)]
            subtitle = "Valor de SET"
            footer = "Resultado capturado"
        }
    }

    func filtered(_ query: String) -> [Row] {
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.value.localizedStandardContains(query) }
    }

    static func copyText(_ rows: [Row]) -> String? {
        rows.isEmpty ? nil : rows.map(\.sql).joined(separator: ", ")
    }
}
