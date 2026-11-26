import SwiftUI

/// Shared controls for the settings draft and the quick selector.
struct ThemeModeControls: View {
    @Binding var mode: AppearanceMode
    let systemIsDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Seguir la apariencia de macOS", isOn: Binding(get: { mode == .system },
                                                                  set: { mode = $0 ? .system : (systemIsDark ? .dark : .light) }))
            Toggle("Modo oscuro", isOn: Binding(get: { !mode.isLight(systemIsDark: systemIsDark) },
                                                set: { mode = $0 ? .dark : .light })).disabled(mode == .system)
            if mode == .system {
                Text("El sistema está usando el modo \(systemIsDark ? "oscuro" : "claro").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ThemeMiniature: View {
    let theme: AppTheme
    private var palette: ThemePalette { theme.palette }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Text("Braket").font(.system(size: 9, weight: .semibold))
                Spacer()
            }.padding(7).background(Color(nsColor: palette.bar))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Proyecto", systemImage: "folder")
                    Text("demo.sql").padding(4).background(Color(nsColor: palette.selection), in: RoundedRectangle(cornerRadius: 3))
                    Spacer(minLength: 0)
                }.font(.system(size: 9)).padding(7).frame(width: 82).background(Color(nsColor: palette.sidebar))
                VStack(alignment: .leading, spacing: 5) {
                    Text("demo.sql").font(.system(size: 9, weight: .semibold))
                    (Text("SELECT ").foregroundColor(Color(nsColor: palette.keyword)) + Text("id, nombre"))
                    (Text("FROM ").foregroundColor(Color(nsColor: palette.keyword)) + Text("clientes"))
                    (Text("WHERE ").foregroundColor(Color(nsColor: palette.keyword)) + Text("id = ") +
                        Text("7;").foregroundColor(Color(nsColor: palette.number)))
                    Divider()
                    Text("id   nombre").bold()
                    HStack {
                        Text("7").padding(.horizontal, 8).background(Color(nsColor: palette.selection))
                        Text("Ana")
                    }
                }.font(.system(size: 10, design: .monospaced)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(Color(nsColor: palette.text))
        .background(Color(nsColor: palette.background))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: palette.muted).opacity(0.25)))
        .accessibilityElement(children: .ignore).accessibilityLabel("Vista previa de \(theme.detail)")
    }
}

struct ThemeGallery: View {
    @Binding var family: AppTheme
    let light: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(AppTheme.families) { item in
                Button { family = item } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.title).font(.headline)
                            Spacer()
                            if family.family == item { Image(systemName: "checkmark.circle.fill") }
                        }
                        ThemeMiniature(theme: item.variant(light: light))
                    }.padding(10).frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.fullArea)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(family.family == item ? Color(nsColor: item.variant(light: light).palette.accent) : Color.primary
                            .opacity(0.12),
                                      lineWidth: family.family == item ? 2 : 1))
                    .accessibilityLabel("Usar \(item.title)")
                    .accessibilityAddTraits(family.family == item ? .isSelected : [])
            }
        }
    }
}

struct QuickThemePicker: View {
    @Bindable var settings: AppSettings
    @State private var presented = false
    @State private var hovered: AppTheme?
    @FocusState private var focused: AppTheme?

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "paintpalette").frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.fullArea).help("Seleccionar tema").accessibilityLabel("Seleccionar tema")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tema").font(.headline)
                    ThemeModeControls(mode: $settings.appearanceMode, systemIsDark: settings.systemIsDark)
                    Divider()
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 2) {
                            ForEach(AppTheme.families + (settings.theme == .midnight ? [.midnight] : [])) { item in
                                Button { settings.theme = item } label: {
                                    HStack {
                                        Text(item.title)
                                        Spacer()
                                        if settings.theme == item { Image(systemName: "checkmark") }
                                    }.padding(.horizontal, 8).padding(.vertical, 5).frame(width: 145)
                                        .background(hovered == item || focused == item ? Theme.accent.opacity(0.16) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 4))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.fullArea).focused($focused, equals: item)
                                    .onHover { inside in hovered = inside ? item : nil }
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            let preview = hovered ?? focused ?? settings.theme
                            Text(preview.title).font(.headline)
                            ThemeMiniature(theme: preview.variant(light: settings.resolvedTheme.isLight))
                                .frame(width: 290, height: 160)
                        }
                    }
                }.padding(18).background(Theme.background).foregroundStyle(Theme.surfaceInk)
                    .preferredColorScheme(Theme.colorScheme)
            }
    }
}
