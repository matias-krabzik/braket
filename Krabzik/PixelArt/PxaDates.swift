import Foundation

/// Fechas UTC RFC 3339 de los objetos `.pxa`. Son informativas: el orden causal del historial
/// lo dan los padres, nunca el reloj (PXA-02 §1).
enum PxaDates {
    /// El archivo guarda segundos enteros: normalizar al crear evita que un valor en memoria
    /// difiera del que se lee después de guardar.
    static func truncated(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    static func now() -> Date { truncated(Date()) }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func parse(_ text: String, section: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) else { throw PixelArtError.invalid(section, "fecha RFC 3339 inválida «\(text)»") }
        return date
    }
}
