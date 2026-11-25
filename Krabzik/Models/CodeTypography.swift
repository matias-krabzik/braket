import AppKit
import CoreText

/// Bundled faces are registered for this process only; system font preferences are untouched.
enum CodeFontFamily: String, Codable, CaseIterable, Identifiable {
    case systemMono, menlo, jetBrainsMono, firaCode, sourceCodePro
    var id: Self { self }
    var title: String {
        switch self {
        case .systemMono: "SF Mono"
        case .menlo: "Menlo"
        case .jetBrainsMono: "JetBrains Mono"
        case .firaCode: "Fira Code"
        case .sourceCodePro: "Source Code Pro"
        }
    }
    private var postScriptName: String {
        switch self {
        case .systemMono: ""
        case .menlo: "Menlo"
        case .jetBrainsMono: "JetBrainsMono"
        case .firaCode: "FiraCode"
        case .sourceCodePro: "SourceCodePro"
        }
    }
    @MainActor private static let registration: Void = {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "CodeFonts") ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    @MainActor func nativeFont(size: CGFloat, bold: Bool = false) -> NSFont {
        _ = Self.registration
        if self != .systemMono, let font = NSFont(name: postScriptName + (bold ? "-Bold" : "-Regular"), size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}

struct CodeTypography: Codable, Equatable {
    var family = CodeFontFamily.systemMono
    var bold = false
    @MainActor func nativeFont(size: CGFloat, forceBold: Bool = false) -> NSFont {
        family.nativeFont(size: size, bold: bold || forceBold)
    }
}
