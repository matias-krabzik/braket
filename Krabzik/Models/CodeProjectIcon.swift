import Foundation

struct CodeProjectIcon: Codable, Equatable {
    enum Source: String, Codable, CaseIterable {
        case automatic, technology, image
        var title: String {
            switch self {
            case .automatic: return "Automático"
            case .technology: return "Logo de tecnología"
            case .image: return "Imagen personalizada"
            }
        }
    }

    enum Rendering: String, Codable, CaseIterable {
        case inherit, color, monochrome
        var title: String {
            switch self {
            case .inherit: return "Como el explorador"
            case .color: return "Color"
            case .monochrome: return "Monocromático"
            }
        }
    }

    var source: Source = .automatic
    var asset = "laravel"
    var rendering: Rendering = .inherit
    var imageData: Data?
    var tintHex: String?
    var tintStrength: Double?

    var tintOpacity: Double { tintStrength ?? 0.12 }

    static let assets = ["android", "angular", "apple", "astro", "bash", "c", "chrome", "composer", "cplusplus",
                         "csharp", "css3", "dart", "docker", "flutter", "git", "go", "html5", "java", "javascript",
                         "json", "laravel", "linux", "markdown", "nodejs", "npm", "php", "python", "react", "ruby",
                         "rust", "svelte", "swift", "typescript", "vuejs", "windows8", "yaml"]

    var isValid: Bool {
        Self.assets.contains(asset) && (imageData?.count ?? 0) <= 131_072
            && (tintHex.map { ProjectIconStyle(hex: $0).isValid } ?? true)
            && tintOpacity.isFinite && (0.04...0.20).contains(tintOpacity)
            && (source != .image || imageData?.isEmpty == false)
    }

    func usesMonochrome(default value: Bool) -> Bool {
        rendering == .inherit ? value : rendering == .monochrome
    }
}
