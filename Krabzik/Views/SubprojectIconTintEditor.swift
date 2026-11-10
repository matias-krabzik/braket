import SwiftUI

struct SubprojectIconTintEditor: View {
    @Binding var options: CodeProjectIcon
    var body: some View {
        SidebarTintEditor(hex: $options.tintHex, strength: $options.tintStrength,
                          detail: "El fondo abarca el subproyecto y todos sus archivos visibles.")
    }
}

struct SidebarTintEditor: View {
    @Binding var hex: String?
    @Binding var strength: Double?
    let detail: String
    private let presets = ["D76E6E", "CBA84E", "4589E8", "8863D7", "D662AD", "DB8746", "4B9F83", "8B949E"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Tinte del bloque", isOn: Binding(get: { hex != nil }, set: { enabled in
                hex = enabled ? (hex ?? "8863D7") : nil
            }))
            if hex != nil {
                HStack(spacing: 10) {
                    Text("Tono").font(.callout)
                    Spacer()
                    ForEach(presets, id: \.self) { preset in
                        Button { hex = preset } label: {
                            Circle().fill(ProjectIconStyle(hex: preset).color).frame(width: 22, height: 22)
                                .overlay { Circle().strokeBorder(.white.opacity(hex == preset ? 0.9 : 0), lineWidth: 2) }
                        }.buttonStyle(.plain).accessibilityLabel("Tinte " + preset)
                    }
                    ColorPicker("Personalizado", selection: Binding(get: {
                        ProjectIconStyle(hex: hex ?? "8863D7").color
                    }, set: { color in
                        var style = ProjectIconStyle()
                        style.setColor(color)
                        hex = style.hex
                    }), supportsOpacity: false).labelsHidden().help("Color personalizado")
                }
                HStack {
                    Text("Intensidad").font(.callout)
                    Slider(value: Binding(get: { strength ?? 0.12 }, set: { strength = $0 }), in: 0.04...0.20)
                    Text("\(Int(((strength ?? 0.12) * 100).rounded())) %").monospacedDigit().font(.caption).frame(width: 38)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
