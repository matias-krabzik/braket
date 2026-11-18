import Foundation

enum SQLTemporalKind: String, Sendable {
    case date, time, datetime, timestamp, year
    func currentQuery(precision: Int) -> String {
        let digits = min(6, max(0, precision))
        switch self {
        case .date: return "SELECT CURRENT_DATE"
        case .time: return "SELECT CURRENT_TIME(\(digits))"
        case .datetime, .timestamp: return "SELECT CURRENT_TIMESTAMP(\(digits))"
        case .year: return "SELECT YEAR(CURRENT_DATE)"
        }
    }
    var format: String {
        switch self {
        case .date: "yyyy-MM-dd"
        case .time: "HH:mm:ss"
        case .datetime, .timestamp: "yyyy-MM-dd HH:mm:ss"
        case .year: "yyyy"
        }
    }
}

enum SQLCellKind: Equatable, Sendable {
    case text
    case integer(bits: Int, unsigned: Bool)
    case decimal(precision: Int, scale: Int, unsigned: Bool)
    case floating(single: Bool, unsigned: Bool)
    case temporal(SQLTemporalKind, precision: Int)
    case enumeration([String])

    var multiline: Bool { self == .text }
    var numeric: Bool {
        switch self { case .integer, .decimal, .floating: true
        default: false }
    }
}

extension SQLSchemaColumn {
    var cellKind: SQLCellKind {
        let lower = type.lowercased()
        let base = lower.prefix { $0 != "(" && $0 != " " }
        let unsigned = lower.contains("unsigned")
        let parameters = lower.split(separator: "(").dropFirst().first?.split(separator: ")").first?
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? []
        if let bits = ["tinyint": 8, "smallint": 16, "mediumint": 24, "int": 32, "integer": 32, "bigint": 64][String(base)] {
            return .integer(bits: bits, unsigned: unsigned)
        }
        switch base {
        case "decimal", "numeric":
            return .decimal(precision: parameters.first ?? 10, scale: parameters.dropFirst().first ?? 0, unsigned: unsigned)
        case "float", "double", "real": return .floating(single: base == "float", unsigned: unsigned)
        case "date", "time", "datetime", "timestamp", "year":
            if let kind = SQLTemporalKind(rawValue: String(base)) { return .temporal(kind, precision: parameters.first ?? 0) }
            return .text
        case "enum": return .enumeration(enumValues)
        default: return .text
        }
    }
}

enum SQLCellInput {
    static func allows(_ text: String, kind: SQLCellKind) -> Bool {
        switch kind {
        case .integer: return matches(text, #"^[+-]?[0-9]*$"#)
        case .decimal: return matches(text, #"^[+-]?[0-9]*(?:\.[0-9]*)?$"#)
        case .floating: return matches(text, #"^[+-]?[0-9]*(?:\.[0-9]*)?(?:[eE][+-]?[0-9]*)?$"#)
        case .temporal: return text.unicodeScalars.allSatisfy { "0123456789-: .".unicodeScalars.contains($0) }
        case .text: return true
        case .enumeration(let values): return values.contains(text)
        }
    }

    static func validate(_ text: String, column: SQLSchemaColumn) throws -> String {
        let kind = column.cellKind
        let value = kind == .text ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .integer(let bits, let unsigned):
            guard matches(value, #"^[+-]?[0-9]+$"#) else { throw DatabaseFailure("Ingresá un número entero.") }
            if unsigned {
                guard let number = UInt64(value.hasPrefix("+") ? String(value.dropFirst()) : value),
                      bits == 64 || number <= (UInt64(1) << bits) - 1 else {
                    throw DatabaseFailure("El valor está fuera del rango de \(column.type).")
                }
            } else {
                guard let number = Int64(value), bits == 64 || (number >= -(Int64(1) << (bits - 1))
                    && number <= (Int64(1) << (bits - 1)) - 1) else {
                    throw DatabaseFailure("El valor está fuera del rango de \(column.type).")
                }
            }
        case .decimal(let precision, let scale, let unsigned):
            guard matches(value, #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#), !unsigned || !value.hasPrefix("-") else {
                throw DatabaseFailure("Ingresá un decimal válido con punto como separador.")
            }
            let magnitude = value.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            let parts = magnitude.split(separator: ".", omittingEmptySubsequences: false)
            let integer = parts.first?.drop(while: { $0 == "0" }).count ?? 0
            let fraction = parts.dropFirst().first?.count ?? 0
            guard integer <= precision - scale, fraction <= scale else {
                throw DatabaseFailure("Este campo admite \(precision - scale) dígitos enteros y \(scale) decimales.")
            }
        case .floating(let single, let unsigned):
            guard matches(value, #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#),
                  let number = Double(value), number.isFinite, !unsigned || number >= 0,
                  !single || abs(number) <= Double(Float.greatestFiniteMagnitude) else {
                throw DatabaseFailure("Ingresá un número válido dentro del rango de \(column.type).")
            }
        case .temporal(let temporal, let precision): try validateTemporal(value, kind: temporal, precision: precision)
        case .enumeration(let values):
            guard values.contains(where: { $0.utf8.elementsEqual(text.utf8) }) else {
                throw DatabaseFailure("Elegí uno de los valores definidos en el ENUM.")
            }
            return text
        case .text:
            let lower = column.type.lowercased()
            if lower.hasPrefix("varchar(") || lower.hasPrefix("char(") {
                let length = lower.drop(while: { $0 != "(" }).dropFirst().prefix { $0 != ")" }
                if let limit = Int(length), text.unicodeScalars.count > limit {
                    throw DatabaseFailure("Este campo admite hasta \(limit) caracteres.")
                }
            }
        }
        return value
    }

    static func formatter(_ kind: SQLTemporalKind) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = kind.format
        return formatter
    }

    private static func validateTemporal(_ text: String, kind: SQLTemporalKind, precision: Int) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let base = String(parts.first ?? "")
        let fraction = parts.dropFirst().first.map(String.init) ?? ""
        let allowedPrecision = [.date, .year].contains(kind) ? 0 : min(6, max(0, precision))
        guard parts.count <= 2, (parts.count == 1 || (!fraction.isEmpty && allowedPrecision > 0)),
              fraction.count <= allowedPrecision, fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw DatabaseFailure("La precisión de este campo es de \(allowedPrecision) decimales de segundo.")
        }
        if kind == .time {
            guard matches(base, #"^-?[0-9]{1,3}:[0-5][0-9]:[0-5][0-9]$"#),
                  let hours = Int(base.split(separator: ":")[0]), abs(hours) <= 838 else {
                throw DatabaseFailure("Ingresá una hora HH:mm:ss, entre -838:59:59 y 838:59:59.")
            }
        } else if kind == .year {
            guard matches(base, #"^[0-9]{4}$"#), let year = Int(base), year == 0 || (1901...2155).contains(year) else {
                throw DatabaseFailure("Ingresá un año entre 1901 y 2155, o 0000.")
            }
        } else {
            let pattern = kind == .date ? #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#
                : #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"#
            let formatter = formatter(kind)
            guard matches(base, pattern), let year = Int(base.prefix(4)), year >= 1000,
                  let date = formatter.date(from: base), formatter.string(from: date) == base else {
                throw DatabaseFailure("Ingresá una fecha válida con formato \(kind.format).")
            }
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
}
