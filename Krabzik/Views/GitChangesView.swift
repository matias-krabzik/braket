import SwiftUI

struct GitChangesSidebar: View {
    let controller: WorkspaceController
    private var git: GitChangesController { controller.gitChanges }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cambios").font(Theme.interfaceFont(13, weight: .semibold))
                Spacer()
                if git.loading { WorkspaceProgress().controlSize(.small) }
                Button { Task { await controller.refreshGitChanges() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.fullArea).help("Actualizar cambios").accessibilityLabel("Actualizar cambios")
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if git.repositories.isEmpty {
                VStack(spacing: 10) {
                    Text(git.loading ? "Buscando repositorios…" : "No se encontraron repositorios Git.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(git.repositories) { repo in
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.triangle.branch")
                                Text(repo.branch).lineLimit(1)
                                Spacer()
                                Text("\(repo.files.count)").foregroundStyle(.secondary)
                            }.font(Theme.interfaceFont(12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 9)
                            Text(repo.root.lastPathComponent).font(Theme.interfaceFont(12, weight: .semibold))
                                .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 4)
                            if let error = repo.error {
                                Text(error).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
                            } else if repo.files.isEmpty {
                                Text("Sin cambios").foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
                            }
                            ForEach(repo.files) { file in
                                Button {
                                    controller.workflowVisible = false
                                    git.select(file)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(nsImage: FileIcons.file(repo.root.appendingPathComponent(file.path)))
                                            .resizable().scaledToFit().frame(width: 16, height: 16)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.name).lineLimit(1)
                                            Text(file.path).font(Theme.interfaceFont(10)).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 3)
                                        Image(systemName: statusSymbol(file.kind))
                                            .font(Theme.interfaceFont(14, weight: .medium))
                                            .foregroundStyle(color(file.kind))
                                            .help(statusLabel(file.kind))
                                            .accessibilityHidden(true)
                                    }.padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(git.selected?.id == file.id ? Theme.accent.opacity(0.18) : .clear)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.fullArea)
                                    .help("\(file.path) · \(statusLabel(file.kind))")
                                    .accessibilityLabel("\(file.path), \(statusLabel(file.kind))")
                            }
                        }
                    }.padding(.vertical, 4)
                }
            }
        }.background(Theme.sidebar).font(Theme.interfaceFont(12))
    }
    private func statusSymbol(_ kind: String) -> String {
        switch kind {
        case "A": "plus.circle"
        case "D": "minus.circle"
        case "R": "arrow.right.circle"
        case "U": "exclamationmark.circle"
        default: "pencil.circle"
        }
    }
    private func statusLabel(_ kind: String) -> String {
        switch kind {
        case "A": "Nuevo"
        case "D": "Eliminado"
        case "R": "Renombrado"
        case "U": "Conflicto"
        default: "Modificado"
        }
    }
    private func color(_ kind: String) -> Color {
        switch kind {
        case "A": .green
        case "D", "U": .red
        default: .orange
        }
    }
}

struct GitChangesDiffView: View {
    let git: GitChangesController
    private var selectedIndex: Int? { git.selected.flatMap { selected in git.files.firstIndex { $0.id == selected.id } } }
    var body: some View {
        let lines = GitDiffLine.parse(git.patch)
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        return VStack(spacing: 0) {
            if let selected = git.selected {
                HStack(spacing: 12) {
                    Text(selected.path).font(Theme.interfaceFont(14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if selected.kind != "D" {
                        Text("+\(added)").foregroundStyle(.green)
                        Text("−\(removed)").foregroundStyle(.red)
                    }
                    Spacer()
                    if let index = selectedIndex {
                        Button { git.select(git.files[index - 1]) } label: {
                            Image(systemName: "chevron.left").frame(width: 30, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.fullArea).disabled(index == 0).help("Archivo anterior")
                        Text("\(index + 1) de \(git.files.count)").foregroundStyle(.secondary)
                        Button { git.select(git.files[index + 1]) } label: {
                            Image(systemName: "chevron.right").frame(width: 30, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.fullArea).disabled(index + 1 >= git.files.count).help("Archivo siguiente")
                    }
                }.font(Theme.interfaceFont(12)).padding(.horizontal, 16).frame(height: 42).background(Theme.bar)
                Divider()
                if selected.kind == "D" {
                    Spacer()
                    Label("Archivo eliminado", systemImage: "doc.badge.minus")
                        .foregroundStyle(.secondary).font(Theme.interfaceFont(14))
                    Spacer()
                } else if git.diffLoading {
                    Spacer()
                    ProgressView("Cargando cambios…")
                    Spacer()
                } else if let error = git.error {
                    Spacer()
                    Text(error).foregroundStyle(.secondary).padding()
                    Spacer()
                } else if git.patch.isEmpty {
                    Spacer()
                    Text("No hay diferencias de contenido para mostrar.").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(line.old.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                                    Text(line.new.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                                    Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(Theme.codeFont(12)).foregroundStyle(foreground(line))
                                    .padding(.trailing, 12).padding(.vertical, 2)
                                    .frame(minWidth: geometry.size.width, alignment: .leading)
                                    .background(background(line))
                            }
                        }.frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                    }
                }
            } else {
                Spacer()
                Text("Seleccioná un archivo para ver sus cambios.").foregroundStyle(.secondary)
                Spacer()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
    }
    private func foreground(_ line: GitDiffLine) -> Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        case .hunk: Theme.accent
        case .context: Theme.surfaceInk
        }
    }
    private func background(_ line: GitDiffLine) -> Color {
        switch line.kind {
        case .added: Color.green.opacity(0.12)
        case .removed: Color.red.opacity(0.12)
        case .hunk: Theme.accent.opacity(0.08)
        case .context: .clear
        }
    }
}
