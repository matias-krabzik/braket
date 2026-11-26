import AppKit

/// The family and appearance mode are persisted independently.
enum AppearanceMode: String, CaseIterable, Codable {
    case system, light, dark

    func isLight(systemIsDark: Bool) -> Bool { self == .light || (self == .system && !systemIsDark) }
}

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case graphite
    case midnight
    case light
    case slate
    case forest
    case olive
    case amber
    case copper
    case garnet
    case plum
    case lavender
    case petrol
    case coral
    case sepia
    case slateLight
    case forestLight
    case oliveLight
    case amberLight
    case copperLight
    case garnetLight
    case plumLight
    case lavenderLight
    case petrolLight
    case coralLight
    case sepiaLight
    case midnightLight

    var id: String { rawValue }
    var isLight: Bool { self == .light || rawValue.hasSuffix("Light") }
    var family: AppTheme {
        if self == .light { return .graphite }
        return AppTheme(rawValue: rawValue.replacingOccurrences(of: "Light", with: "")) ?? .graphite
    }
    func variant(light: Bool) -> AppTheme {
        guard light else { return family }
        return family == .graphite ? .light : AppTheme(rawValue: family.rawValue + "Light") ?? .light
    }
    static var families: [AppTheme] {
        [.graphite, .slate, .forest, .olive, .amber, .copper, .garnet, .plum, .lavender, .petrol, .coral, .sepia]
    }
    var title: String { palette.name }
    var detail: String { "\(title) · \(isLight ? "Claro" : "Oscuro")" }
    var palette: ThemePalette {
        switch family {
        case .graphite:
            ThemePalette(name: "Grafito", light: isLight,
                         darkSurface: ["1F2023", "28292C", "232427"],
                         lightSurface: ["FAFAFC", "EFF0F2", "F5F5F7"],
                         accents: ["B6B9C2", "555B69"],
                         keywords: ["C49CED", "74439E"],
                         strings: ["9AC4A6", "376447"],
                         numbers: ["DDB385", "92501E"])
        case .slate:
            ThemePalette(name: "Pizarra", light: isLight,
                         darkSurface: ["20282A", "2A3436", "253033"],
                         lightSurface: ["F0F7F5", "E2EEEA", "EAF2EF"],
                         accents: ["77C6B4", "226757"],
                         keywords: ["8ED7CB", "226757"],
                         strings: ["B4C5A1", "536D30"],
                         numbers: ["DBBD8F", "885823"])
        case .forest:
            ThemePalette(name: "Bosque", light: isLight,
                         darkSurface: ["1E2820", "29372B", "233025"],
                         lightSurface: ["F6F7EF", "E9EEDC", "F0F2E7"],
                         accents: ["A3CB85", "406B2D"],
                         keywords: ["B4D78E", "406B2D"],
                         strings: ["8FC5B1", "2B7160"],
                         numbers: ["D9BD87", "895722"])
        case .olive:
            ThemePalette(name: "Oliva", light: isLight,
                         darkSurface: ["292B20", "35382A", "303225"],
                         lightSurface: ["F8F6E9", "EDEED8", "F3F1E1"],
                         accents: ["C4CE83", "69722A"],
                         keywords: ["D2D990", "606A20"],
                         strings: ["A5C5AE", "3C6A4B"],
                         numbers: ["DCB28A", "94502B"])
        case .amber:
            ThemePalette(name: "Ámbar", light: isLight,
                         darkSurface: ["29251F", "383127", "302A22"],
                         lightSurface: ["FCF7EC", "F1E8D5", "F7EFDF"],
                         accents: ["E6BA69", "8F5A14"],
                         keywords: ["EDC978", "885415"],
                         strings: ["B4C694", "476733"],
                         numbers: ["DDA392", "974732"])
        case .copper:
            ThemePalette(name: "Cobre", light: isLight,
                         darkSurface: ["2C2420", "3C3029", "332922"],
                         lightSurface: ["FFF6EF", "F3E4D8", "FAECE1"],
                         accents: ["E3A17A", "994B29"],
                         keywords: ["EEB18D", "984826"],
                         strings: ["B9C38F", "5C6B31"],
                         numbers: ["D4B4D8", "80588D"])
        case .garnet:
            ThemePalette(name: "Granate", light: isLight,
                         darkSurface: ["2B2227", "392C33", "32272D"],
                         lightSurface: ["FCF4F7", "F0E1E8", "F7EAF0"],
                         accents: ["DA93AB", "923A59"],
                         keywords: ["EBA5C1", "923A59"],
                         strings: ["AAC4A0", "48653C"],
                         numbers: ["DEC088", "8A5B22"])
        case .plum:
            ThemePalette(name: "Ciruela", light: isLight,
                         darkSurface: ["282230", "362C40", "302738"],
                         lightSurface: ["FAF5FC", "ECE2F0", "F4EBF7"],
                         accents: ["C4A0E0", "794593"],
                         keywords: ["D1ADEA", "794593"],
                         strings: ["ABC99D", "446936"],
                         numbers: ["E1B18D", "985025"])
        case .lavender:
            ThemePalette(name: "Lavanda", light: isLight,
                         darkSurface: ["252332", "302E40", "2B293A"],
                         lightSurface: ["F7F5FF", "E9E5F5", "F0EDFA"],
                         accents: ["B7A8EA", "65509E"],
                         keywords: ["C8B5F0", "65509E"],
                         strings: ["A4CCBB", "306D56"],
                         numbers: ["E3B99A", "905528"])
        case .petrol:
            ThemePalette(name: "Petróleo", light: isLight,
                         darkSurface: ["1B2A2A", "243839", "203132"],
                         lightSurface: ["EFF9F6", "DCEFEA", "E6F5F0"],
                         accents: ["71C9C4", "176B65"],
                         keywords: ["8CDECE", "176B65"],
                         strings: ["BDD19C", "576C2D"],
                         numbers: ["E5B28D", "94522B"])
        case .coral:
            ThemePalette(name: "Coral", light: isLight,
                         darkSurface: ["2B2527", "393032", "332A2D"],
                         lightSurface: ["FFF5F2", "F4E4DF", "FBECE7"],
                         accents: ["E8A09A", "A44740"],
                         keywords: ["F0AEA5", "A44740"],
                         strings: ["B3CAA6", "48663A"],
                         numbers: ["DFC18A", "8B6024"])
        case .sepia:
            ThemePalette(name: "Sepia", light: isLight,
                         darkSurface: ["2C261F", "3B3328", "342D23"],
                         lightSurface: ["FBF4E7", "EFE4CE", "F6ECD9"],
                         accents: ["D9BC8D", "79572D"],
                         keywords: ["E4C99C", "79572D"],
                         strings: ["B9C493", "526434"],
                         numbers: ["DCAB94", "935037"])
        case .midnight:
            ThemePalette(name: "Azul noche", light: isLight,
                         darkSurface: ["1B1E23", "22262C", "1F2228"],
                         lightSurface: ["FAFAFC", "EFF0F2", "F5F5F7"],
                         accents: ["7BAAE8", "315CA0"],
                         keywords: ["C49CED", "74439E"],
                         strings: ["9AC4A6", "376447"],
                         numbers: ["DDB385", "92501E"])
        default: AppTheme.graphite.variant(light: isLight).palette
        }
    }
}

struct ThemePalette {
    let name: String
    let light: Bool
    let darkSurface: [String]
    let lightSurface: [String]
    let accents: [String]
    let keywords: [String]
    let strings: [String]
    let numbers: [String]

    var background: NSColor { color((light ? lightSurface : darkSurface)[0]) }
    var sidebar: NSColor { color((light ? lightSurface : darkSurface)[1]) }
    var bar: NSColor { color((light ? lightSurface : darkSurface)[2]) }
    var text: NSColor { color(light ? "282B30" : "E3E6EB") }
    var muted: NSColor { color(light ? "60646D" : "969BA5") }
    var accent: NSColor { color(accents[light ? 1 : 0]) }
    var keyword: NSColor { color(keywords[light ? 1 : 0]) }
    var string: NSColor { color(strings[light ? 1 : 0]) }
    var number: NSColor { color(numbers[light ? 1 : 0]) }
    var identifier: NSColor { color(light ? "276E9A" : "87BFE7") }
    var selection: NSColor { accent.withAlphaComponent(light ? 0.20 : 0.28) }

    private func color(_ hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                       green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}
