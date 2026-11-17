import SwiftUI

struct SQLOutputView: View {
    @Bindable var output: SQLOutputController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar SQL, conexión o base…", text: $output.search)
                    .textFieldStyle(.plain).accessibilityLabel("Buscar en Logs")
                    .qaField("output.search", text: $output.search)
                if output.loading { ProgressView().controlSize(.small) }
                Button(output.hasUpdates ? "Ver nuevas ejecuciones" : "Actualizar") { Task { await output.reload() } }
                    .disabled(output.loading)
                    .qaControl("output.refresh", title: "Actualizar", enabled: !output.loading) {
                        Task { await output.reload() }
                    }
                if let url = output.store?.url {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                        .help("Mostrar archivo del historial").accessibilityLabel("Mostrar archivo del historial")
                }
            }
            .font(Theme.interfaceFont(13)).padding(12).background(Theme.bar)
            if let error = output.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    .font(Theme.interfaceFont(13)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if output.entries.isEmpty, !output.loading {
                ContentUnavailableView(output.search.isEmpty ? "Sin ejecuciones todavía" : "Sin coincidencias",
                                       systemImage: "text.alignleft",
                                       description: Text(output.search.isEmpty
                                           ? "Las consultas de este proyecto se guardan aquí, incluso después de cerrar Braket."
                                           : "Probá con otras palabras de la consulta, conexión o base."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    history.frame(minHeight: 140, maxHeight: .infinity)
                    if let entry = output.selected { detail(entry).frame(minHeight: 120, idealHeight: 230) }
                }
            }
            HStack {
                Text("\(output.entries.count) ejecuciones cargadas")
                Spacer()
                Text("Historial del proyecto · más recientes primero")
            }
            .font(Theme.interfaceFont(12)).foregroundStyle(.secondary).padding(8).background(Theme.bar)
        }
        .background(Theme.background).qaScreen("output")
        .task(id: output.search) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            await output.reload()
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await output.checkForUpdates()
            }
        }
    }

    private var history: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(output.entries) { entry in
                    Button { Task { await output.select(entry) } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image(systemName: entry.status == "success" ? "checkmark.circle" : "clock")
                                Text(entry.statusLabel).fontWeight(.medium)
                                Text(entry.connection + (entry.database.isEmpty ? "" : " · " + entry.database))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                                Text(String(format: "%.0f ms", entry.elapsed * 1000)).frame(width: 72, alignment: .trailing)
                            }
                            .font(Theme.interfaceFont(12)).foregroundStyle(entry.status == "error" ? .orange : .secondary)
                            Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                .font(Theme.codeFont())
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                        .background(output.selected?.id == entry.id ? Theme.accent.opacity(0.12) : .clear)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if output.hasMore {
                    Button("Cargar 200 anteriores") { Task { await output.loadMore() } }
                        .disabled(output.loading).padding(14)
                        .qaControl("output.more", title: "Cargar 200 anteriores", enabled: !output.loading) {
                            Task { await output.loadMore() }
                        }
                }
            }
        }
    }

    private func detail(_ entry: SQLHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.statusLabel + " · " + entry.source)
                Text("\(entry.rows) filas · \(entry.affected) afectadas").foregroundStyle(.secondary)
                Spacer()
                Button("Copiar SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.sql, forType: .string)
                }
            }.font(Theme.interfaceFont(12))
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.sql).font(Theme.codeFont())
                    if !entry.error.isEmpty { Text(entry.error).foregroundStyle(.orange) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12)
    }
}
