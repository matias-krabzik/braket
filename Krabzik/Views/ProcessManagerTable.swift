import SwiftUI

/// One shared column layout keeps group headers and process rows aligned at every window width.
struct ProcessManagerTable: View {
    let runs: [ProjectRun]
    let selectedID: UUID?
    let workspaceURL: URL?
    let select: (ProjectRun) -> Void
    let showLogs: (ProjectRun) -> Void
    let restart: (ProjectRun) -> Void
    let toggle: (ProjectRun) -> Void
    let edit: (ProjectRun) -> Void
    let openPort: (Int) -> Void
    @State private var collapsed: Set<URL> = []

    private var groups: [URL] {
        Array(Set(runs.compactMap(\.workspaceURL))).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    var body: some View {
        GeometryReader { geometry in
            let width = max(Theme.zoom(960), geometry.size.width)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    columns(width)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(groups, id: \.self) { url in
                                groupHeader(url)
                                if !collapsed.contains(url) {
                                    ForEach(runs.filter { $0.workspaceURL == url }) { run in row(run, width: width) }
                                }
                            }
                            if runs.isEmpty {
                                Text("No hay procesos que coincidan con la búsqueda.")
                                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(28)
                            }
                        }
                    }
                }.frame(width: width, height: geometry.size.height)
            }
        }
        .background(ProcessManagerAppearance.background)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.surfaceInk.opacity(0.16)))
    }
    private func column<Content: View>(_ fraction: CGFloat, width: CGFloat,
                                       @ViewBuilder content: () -> Content) -> some View {
        content().lineLimit(1).frame(width: width * fraction - 24, alignment: .leading)
            .padding(.horizontal, 12)
    }
    private func columns(_ width: CGFloat) -> some View {
        HStack(spacing: 0) {
            column(0.27, width: width) { Text("Proceso").padding(.leading, 12) }
            column(0.16, width: width) { Text("Proyecto") }
            column(0.14, width: width) { Text("Estado") }
            column(0.14, width: width) { Text("Puertos") }
            column(0.13, width: width) { Text("Tiempo activo") }
            column(0.16, width: width) { Text("Acciones") }
        }.font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(.secondary)
            .frame(height: Theme.zoom(38)).background(ProcessManagerAppearance.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
    private func groupHeader(_ url: URL) -> some View {
        Button {
            if collapsed.contains(url) { collapsed.remove(url) } else { collapsed.insert(url) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: collapsed.contains(url) ? "chevron.right" : "chevron.down")
                    .font(Theme.interfaceFont(12))
                Text(runs.first(where: { $0.workspaceURL == url })?.workspaceName ?? url.deletingPathExtension().lastPathComponent)
                    .font(Theme.interfaceFont(16, weight: .semibold))
                Text(url == workspaceURL ? "Proyecto actual" : "En segundo plano")
                    .font(Theme.interfaceFont(13)).italic().foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 12).frame(height: Theme.zoom(40)).contentShape(Rectangle())
        }.buttonStyle(.fullArea).background(Theme.surfaceInk.opacity(0.035))
            .overlay(alignment: .bottom) { Divider() }
            .help(collapsed.contains(url) ? "Mostrar procesos del proyecto" : "Contraer procesos del proyecto")
            .accessibilityLabel(runs.first(where: { $0.workspaceURL == url })?.workspaceName ?? url.lastPathComponent)
    }
    private func row(_ run: ProjectRun, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            column(0.27, width: width) {
                HStack(spacing: 12) {
                    if let project = run.project {
                        Image(nsImage: FileIcons.project(project)).resizable().scaledToFit()
                            .frame(width: Theme.zoom(23), height: Theme.zoom(23))
                    }
                    Text(run.name)
                }.padding(.leading, 12).help(run.name)
            }
            column(0.16, width: width) { Text(run.workspaceName).help(run.workspaceName) }
            column(0.14, width: width) {
                HStack(spacing: 8) {
                    Circle().fill(ProcessManagerAppearance.statusColor(run)).frame(width: 9, height: 9)
                    Text(run.pendingRestart ? "Reiniciando…" : run.status == .running ? "Activo" : run.status.label)
                    if !run.portConflict.isEmpty {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(run.portConflict)
                    }
                }
            }
            column(0.14, width: width) {
                HStack(spacing: 5) {
                    if run.ports.isEmpty { Text("—").foregroundStyle(.secondary) }
                    ForEach(run.ports, id: \.self) { port in
                        Button { openPort(port) } label: {
                            Text(":\(port) ↗").foregroundStyle(ProcessManagerAppearance.link)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ProcessManagerAppearance.link.opacity(0.65)))
                        }.buttonStyle(.fullArea).help("Abrir http://localhost:\(port)")
                    }
                }
            }
            column(0.13, width: width) {
                if let start = run.startedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(ProcessManagerAppearance.elapsed(from: start, to: run.endedAt ?? context.date)).monospacedDigit()
                    }
                } else { Text("—").foregroundStyle(.secondary) }
            }
            column(0.16, width: width) {
                HStack(spacing: 10) {
                    ProcessManagerIconButton(icon: "text.alignleft", help: "Ver logs") { showLogs(run) }
                    ProcessManagerIconButton(icon: "arrow.counterclockwise", help: "Reiniciar") { restart(run) }
                        .disabled(run.status == .stopping || run.project?.command.isEmpty != false)
                    ProcessManagerIconButton(icon: run.status.active || run.pendingRestart ? "stop.fill" : "play.fill",
                                             help: run.status.active || run.pendingRestart ? "Detener" : "Iniciar",
                                             tint: run.status.active || run.pendingRestart ? .red : .green) { toggle(run) }
                        .disabled(run.status == .stopping || run.project?.command.isEmpty != false)
                }
            }
        }
        .font(Theme.interfaceFont(14)).frame(height: Theme.zoom(44))
        .background(selectedID == run.id ? ProcessManagerAppearance.selection : .clear)
        .contentShape(Rectangle()).onTapGesture { select(run) }
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu {
            Button("Ver logs") { showLogs(run) }
            Button("Editar configuración de ejecución…") { edit(run) }
            Button("Reiniciar") { restart(run) }.disabled(run.project?.command.isEmpty != false)
            Button("Detener") { toggle(run) }.disabled(!run.status.active && !run.pendingRestart)
        }
    }
}

@MainActor enum ProcessManagerAppearance {
    static var background: Color { Theme.background }
    static var bar: Color { Theme.bar }
    static var link: Color { Theme.settings.theme == .light ? .blue : Theme.accent }
    static var selection: Color { Theme.accent.opacity(0.18) }
    static func statusColor(_ run: ProjectRun) -> Color {
        if run.status == .running { return .green }
        if run.status == .stopping || run.pendingRestart { return .orange }
        if case .failed = run.status { return .red }
        if case .exited(let code) = run.status, code != 0 { return .red }
        return .secondary
    }
    static func elapsed(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }
}

struct ProcessManagerIconButton: View {
    let icon: String
    let help: String
    var tint: Color = .secondary
    let perform: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: perform) {
            Image(systemName: icon).font(Theme.interfaceFont(14)).foregroundStyle(tint)
                .frame(width: Theme.zoom(32), height: Theme.zoom(28)).contentShape(Rectangle())
                .background(Theme.surfaceInk.opacity(hovering ? 0.1 : 0.025), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.surfaceInk.opacity(hovering ? 0.35 : 0.18)))
        }.buttonStyle(.fullArea).opacity(enabled ? 1 : 0.4).onHover { hovering = $0 }.help(help).accessibilityLabel(help)
    }
}
