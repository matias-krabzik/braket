import AppKit
import SwiftUI

struct WelcomeView: View {
    let controller: WorkspaceController
    @State private var settingsHovered = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 1)
            recentProjects
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WelcomeBackground())
        .disabled(controller.isSwitchingWorkspace)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Braket")
                .font(.system(size: Theme.zoom(23), weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.bottom, 28)
            VStack(spacing: 10) {
                WelcomeAction(title: "Abrir proyecto…", icon: "folder", shortcut: "⌘O", prominent: true,
                              action: controller.chooseWorkspace)
                WelcomeAction(title: "Crear proyecto…", icon: "plus", shortcut: "⇧⌘N", prominent: false,
                              action: controller.createWorkspace)
            }
            Spacer(minLength: 32)
            SettingsLink {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape").font(.system(size: Theme.zoom(16))).frame(width: 20)
                    Text("Configuración").font(.system(size: Theme.zoom(13), weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 8).frame(height: 40)
                .background(Theme.surfaceInk.opacity(settingsHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { settingsHovered = $0 }
            .help("Configuración · ⌘,")
            .accessibilityLabel("Configuración")
        }
        .padding(.horizontal, 16)
        .padding(.top, 32)
        .padding(.bottom, 20)
        .frame(width: Theme.zoom(240))
        .frame(maxHeight: .infinity)
        .background(AppSettings.shared.theme == .light ? Theme.sidebar.opacity(0.65) : Color.black.opacity(0.035))
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Proyectos recientes").font(.system(size: Theme.zoom(22), weight: .semibold))
                Spacer()
                if !controller.recentProjects.isEmpty {
                    Text("\(controller.recentProjects.count)")
                        .font(.system(size: Theme.zoom(11), weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.sidebar, in: Capsule())
                }
            }
            if controller.recentProjects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: Theme.zoom(30), weight: .light))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                        .padding(.bottom, 4)
                    Text("Todavía no hay proyectos recientes")
                        .font(.system(size: Theme.zoom(13), weight: .medium))
                    Text("Los proyectos que abras aparecerán acá\npara que puedas retomarlos fácilmente.")
                        .font(.system(size: Theme.zoom(12))).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineSpacing(4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.recentProjects, id: \.self) { url in
                            RecentProjectRow(url: url, open: { Task { await controller.openWorkspace(url) } },
                                             forget: { controller.recents.forget(url) })
                                .contextMenu {
                                    Button("Abrir proyecto") { Task { await controller.openWorkspace(url) } }
                                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Divider()
                                    Button("Quitar de recientes") { controller.recents.forget(url) }
                                }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WelcomeBackground: View {
    private var isLight: Bool { AppSettings.shared.theme == .light }
    private var base: Color {
        isLight ? Color(red: 0.985, green: 0.99, blue: 1) : Color(red: 35 / 255, green: 38 / 255, blue: 44 / 255)
    }
    private var glow: Color {
        isLight ? Color(red: 0.78, green: 0.85, blue: 0.96) : Color(red: 81 / 255, green: 87 / 255, blue: 94 / 255)
    }

    var body: some View {
        GeometryReader { geometry in
            let span = max(geometry.size.width, geometry.size.height)
            ZStack {
                base
                RadialGradient(stops: [
                    .init(color: glow.opacity(0.48), location: 0),
                    .init(color: glow.opacity(0.22), location: 0.45),
                    .init(color: glow.opacity(0), location: 1)
                ], center: UnitPoint(x: 0.12, y: 0.06), startRadius: 0, endRadius: span * 0.7)
                RadialGradient(stops: [
                    .init(color: glow.opacity(0.25), location: 0),
                    .init(color: glow.opacity(0.08), location: 0.5),
                    .init(color: glow.opacity(0), location: 1)
                ], center: UnitPoint(x: 0.95, y: 1.08), startRadius: 0, endRadius: span * 0.55)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WelcomeAction: View {
    let title: String
    let icon: String
    let shortcut: String
    let prominent: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: Theme.zoom(14))).frame(width: 18)
                    .foregroundStyle(Theme.accent)
                Text(title).font(.system(size: Theme.zoom(13), weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text(shortcut).font(.system(size: Theme.zoom(11))).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).frame(height: 42)
            .background(prominent ? Theme.accent.opacity(isHovered ? 0.2 : 0.12) : Theme.surfaceInk.opacity(isHovered ? 0.07 : 0.035),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(prominent ? Theme.accent.opacity(0.25) : Theme.border)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct RecentProjectRow: View {
    let url: URL
    let open: () -> Void
    let forget: () -> Void
    @State private var isHovered = false
    @State private var model: Workspace?
    private var name: String { model?.name ?? url.deletingPathExtension().lastPathComponent }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 18) {
                    ProjectIcon(name: name, style: model?.iconStyle ?? ProjectIconStyle(), size: 34)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name)
                            .font(.system(size: Theme.zoom(15), weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: Theme.zoom(12))).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url.path)
            .accessibilityLabel("Abrir \(name)")
            .accessibilityValue(url.path)
            Button(action: forget) {
                Image(systemName: "xmark")
                    .font(.system(size: Theme.zoom(11), weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.trailing, 8)
            .help("Quitar de recientes. Los archivos se conservan.")
            .accessibilityLabel("Quitar \(name) de recientes")
            .accessibilityHint("Los archivos se conservan.")
        }
        .background(isHovered ? Theme.sidebar.opacity(0.6) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .onHover { isHovered = $0 }
        .task(id: url) {
            model = try? await Task.detached(priority: .utility) { try Workspace.read(from: url) }.value
        }
    }
}
