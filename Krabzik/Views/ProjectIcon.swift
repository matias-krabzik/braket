import AppKit
import SwiftUI

extension ProjectIconStyle {
    var color: Color {
        let rgb = UInt32(hex, radix: 16) ?? 0x687080
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    mutating func setColor(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        hex = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                     Int(rgb.blueComponent * 255))
    }
}

struct ProjectIcon: View {
    let name: String
    let style: ProjectIconStyle
    var size: CGFloat = 42
    var selected = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24)
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        ZStack {
            if style.glass {
                shape.fill(.ultraThinMaterial)
                shape.fill(style.color.opacity(0.55))
                shape.fill(LinearGradient(colors: [.white.opacity(0.3), .clear, .black.opacity(0.18)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                shape.fill(style.color)
            }
            Text(initials.isEmpty ? "<>" : initials)
                .font(.system(size: size * 0.31, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(selected ? 0.95 : 0.55), .white.opacity(0.12)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: selected ? 2 : 1)
        }
        .accessibilityHidden(true)
    }
}
