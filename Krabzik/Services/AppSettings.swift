import Foundation
import Observation

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case graphite
    case midnight
    case light

    var id: String { rawValue }
    var title: String {
        switch self {
        case .graphite: "Grafito"
        case .midnight: "Azul noche"
        case .light: "Claro"
        }
    }
    var detail: String {
        switch self {
        case .graphite: "Inspirado en el icono de Krabzik."
        case .midnight: "El tema azul oscuro original."
        case .light: "Fondos claros y colores de sintaxis con contraste para trabajar de día."
        }
    }
}

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    static let uiScaleRange = 0.8...1.5
    static let fontSizeRange = 10.0...24.0

    var defaultSQLTimeoutSeconds: Int {
        didSet { defaults.set(min(3600, max(1, defaultSQLTimeoutSeconds)), forKey: "defaultSQLTimeoutSeconds") }
    }
    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "appearanceTheme") }
    }
    var restoreLastState: Bool {
        didSet {
            defaults.set(restoreLastState, forKey: "restoreLastState")
            if !restoreLastState { defaults.removeObject(forKey: SessionRestoration.key) }
        }
    }
    var markdownPreviewZoom: Double {
        didSet { defaults.set(markdownPreviewZoom, forKey: "markdownPreviewZoom") }
    }
    var uiScale: Double {
        didSet { defaults.set(uiScale, forKey: "uiScale") }
    }
    var codeFontSize: Double {
        didSet { defaults.set(codeFontSize, forKey: "codeFontSize") }
    }
    var resultFontSize: Double {
        didSet { defaults.set(resultFontSize, forKey: "resultFontSize") }
    }
    var codeTypography: CodeTypography {
        didSet { persistTypography(codeTypography, key: "codeTypography") }
    }
    var resultTypography: CodeTypography {
        didSet { persistTypography(resultTypography, key: "resultTypography") }
    }
    private func persistTypography(_ value: CodeTypography, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    var wrapLines: Bool {
        didSet { defaults.set(wrapLines, forKey: "editorWrapLines") }
    }
    var editorOptions: EditorOptions {
        didSet {
            if let data = try? JSONEncoder().encode(editorOptions) { defaults.set(data, forKey: "editorOptions") }
        }
    }
    var codeFontScale: Double { codeFontSize / 14 }
    var resultFontScale: Double { resultFontSize / 14 }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        codeTypography = defaults.data(forKey: "codeTypography")
            .flatMap { try? JSONDecoder().decode(CodeTypography.self, from: $0) } ?? CodeTypography()
        resultTypography = defaults.data(forKey: "resultTypography")
            .flatMap { try? JSONDecoder().decode(CodeTypography.self, from: $0) } ?? CodeTypography()
        let timeout = defaults.object(forKey: "defaultSQLTimeoutSeconds") as? Int ?? 60
        defaultSQLTimeoutSeconds = (1...3600).contains(timeout) ? timeout : 60
        var savedEditorOptions = defaults.data(forKey: "editorOptions")
            .flatMap { try? JSONDecoder().decode(EditorOptions.self, from: $0) } ?? EditorOptions()
        if ![2, 4].contains(savedEditorOptions.indentWidth) { savedEditorOptions.indentWidth = 4 }
        if !["upper", "lower", "preserve"].contains(savedEditorOptions.keywordCase) { savedEditorOptions.keywordCase = "upper" }
        editorOptions = savedEditorOptions
        let savedCodeSize = defaults.object(forKey: "codeFontSize") as? Double ?? 14
        let savedResultSize = defaults.object(forKey: "resultFontSize") as? Double ?? 14
        codeFontSize = savedCodeSize.isFinite ? min(24, max(10, savedCodeSize)) : 14
        resultFontSize = savedResultSize.isFinite ? min(24, max(10, savedResultSize)) : 14
        wrapLines = defaults.object(forKey: "editorWrapLines") as? Bool ?? true
        theme = AppTheme(rawValue: defaults.string(forKey: "appearanceTheme") ?? "") ?? .graphite
        restoreLastState = defaults.object(forKey: "restoreLastState") as? Bool ?? true
        let savedZoom = defaults.object(forKey: "markdownPreviewZoom") as? Double ?? 1
        markdownPreviewZoom = savedZoom.isFinite ? min(2, max(0.7, savedZoom)) : 1
        let savedScale = defaults.object(forKey: "uiScale") as? Double ?? 1
        uiScale = savedScale.isFinite ? min(Self.uiScaleRange.upperBound,
                                            max(Self.uiScaleRange.lowerBound, savedScale)) : 1
    }

    func zoomIn() { uiScale = min(Self.uiScaleRange.upperBound, (uiScale * 10).rounded() / 10 + 0.1) }
    func zoomOut() { uiScale = max(Self.uiScaleRange.lowerBound, (uiScale * 10).rounded() / 10 - 0.1) }
    func resetZoom() { uiScale = 1 }
}
