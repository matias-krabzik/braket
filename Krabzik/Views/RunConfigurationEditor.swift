import Foundation

/// Shared URL validation for service ports and browser shortcuts.
enum RunConfigurationEditor {
    static func browserURL(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }
}
