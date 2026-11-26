import SwiftUI

struct TextAppearanceSettings: View {
    @Binding var code: CodeTypography
    @Binding var results: CodeTypography
    @Binding var codeSize: Double
    @Binding var resultSize: Double
    let theme: AppTheme
    @State private var editsResults = false

    private var typography: Binding<CodeTypography> { editsResults ? $results : $code }
    private var size: Binding<Double> { editsResults ? $resultSize : $codeSize }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Apariencia › Textos").font(.title2.weight(.semibold))
                Text("Interfaz · San Francisco").foregroundStyle(.secondary)
                Picker("Configurar", selection: $editsResults) {
                    Text("Código").tag(false)
                    Text("Resultados").tag(true)
                }.pickerStyle(.segmented)
                HStack(spacing: 12) {
                    Text("Tamaño")
                    Slider(value: size, in: AppSettings.fontSizeRange, step: 1)
                        .accessibilityLabel(editsResults ? "Tamaño de fuente de resultados" : "Tamaño de fuente de código")
                    Text("\(Int(size.wrappedValue)) pt").monospacedDigit().frame(width: 44)
                    Button("Restablecer") { typography.wrappedValue = CodeTypography()
                        size.wrappedValue = 14
                    }.disabled(typography.wrappedValue == CodeTypography() && size.wrappedValue == 14)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(CodeFontFamily.allCases) { family in
                        CodeFontCard(family: family, typography: typography, size: size.wrappedValue,
                                     results: editsResults, theme: theme)
                    }
                }
            }.padding(24)
        }.background(Theme.background)
    }
}

private struct CodeFontCard: View {
    let family: CodeFontFamily
    @Binding var typography: CodeTypography
    let size: Double
    let results: Bool
    let theme: AppTheme
    private var selected: Bool { typography.family == family }
    private var bold: Binding<Bool> {
        Binding(get: { selected && typography.bold }, set: { typography.family = family
            typography.bold = $0
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { typography.family = family } label: {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text(family.title).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        if results {
                            Text("id   nombre").fontWeight(.bold)
                            Text("42   María")
                            Text("108  Martín")
                        } else {
                            Text("SELECT ").foregroundColor(Color(nsColor: theme.palette.keyword)) + Text("id, email")
                            Text("FROM ").foregroundColor(Color(nsColor: theme.palette.keyword)) + Text("clientes")
                            Text("WHERE ").foregroundColor(Color(nsColor: theme.palette.keyword)) + Text("id = ") +
                                Text("42;").foregroundColor(Color(nsColor: theme.palette.number))
                        }
                    }
                    .font(Font(family.nativeFont(size: size, bold: selected && typography.bold)))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }.padding(14).frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
                    .contentShape(Rectangle())
            }.buttonStyle(.fullArea).accessibilityLabel("Usar \(family.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            Divider()
            Toggle("Negrita", isOn: bold).toggleStyle(.checkbox).font(.system(size: 12))
                .accessibilityLabel("Negrita en \(family.title)").padding(.horizontal, 14).padding(.vertical, 10)
        }
        .tabSelectionBackground { typography.family = family }
        .foregroundStyle(Color(nsColor: theme.palette.text))
        .background(Color(nsColor: EditorPalette.background(for: theme)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.blue : Theme.border, lineWidth: selected ? 2 : 1))
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
    }
}
