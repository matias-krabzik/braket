import AppKit
import SwiftUI

struct WelcomeView: View {
    let controller: WorkspaceController

    var body: some View {
        HStack(alignment: .center, spacing: 48) {
            introduction.frame(width: 300)
            Rectangle().fill(Theme.border).frame(width: 1, height: 390)
            recentProjects.frame(maxWidth: .infinity)
        }
        .padding(48)
        .frame(maxWidth: 1080)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(controller.isSwitchingWorkspace)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
                .padding(.leading, -8)
                .padding(.bottom, 24)
            Text("Krabzik IDE")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .padding(.bottom, 12)
            Text("Abrí un proyecto reciente\no empezá uno nuevo.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .padding(.bottom, 32)
            VStack(spacing: 10) {
                WelcomeAction(title: "Abrir proyecto…", icon: "folder", shortcut: "⌘O", prominent: true,
                              action: controller.chooseWorkspace)
                WelcomeAction(title: "Crear proyecto…", icon: "plus", shortcut: "⇧⌘N", prominent: false,
                              action: controller.createWorkspace)
            }
        }
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Proyectos recientes").font(.system(size: 16, weight: .semibold))
                Spacer()
                if !controller.recentProjects.isEmpty {
                    Text("\(controller.recentProjects.count)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.sidebar, in: Capsule())
                }
            }
            if controller.recentProjects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.blue.opacity(0.7))
                        .padding(.bottom, 4)
                    Text("Todavía no hay proyectos recientes")
                        .font(.system(size: 13, weight: .medium))
                    Text("Los proyectos que abras aparecerán acá\npara que puedas retomarlos fácilmente.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineSpacing(4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.sidebar.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border) }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(controller.recentProjects, id: \.self) { url in
                            RecentProjectRow(url: url) { Task { await controller.openWorkspace(url) } }
                                .contextMenu {
                                    Button("Abrir proyecto") { Task { await controller.openWorkspace(url) } }
                                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Divider()
                                    Button("Quitar de recientes") { controller.removeRecentProject(url) }
                                }
                        }
                    }
                    .padding(2)
                }
            }
        }
        .frame(height: 390)
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
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                    .foregroundStyle(Theme.blue)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(prominent ? Theme.blue.opacity(isHovered ? 0.2 : 0.12) : Color.white.opacity(isHovered ? 0.07 : 0.035),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(prominent ? Theme.blue.opacity(0.25) : Theme.border)
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
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: "folder")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.blue)
                    .frame(width: 42, height: 42)
                    .background(Theme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovered ? Theme.blue : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(isHovered ? Theme.sidebar : Theme.sidebar.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(isHovered ? Theme.blue.opacity(0.25) : Theme.border) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.path)
        .accessibilityLabel("Abrir \(url.deletingPathExtension().lastPathComponent)")
        .accessibilityValue(url.path)
    }
}
