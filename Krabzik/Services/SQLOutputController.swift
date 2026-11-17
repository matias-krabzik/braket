import Foundation
import Observation

@MainActor @Observable
final class SQLOutputController {
    private(set) var store: SQLHistoryStore?
    private(set) var entries: [SQLHistoryEntry] = []
    private(set) var selected: SQLHistoryEntry?
    private(set) var loading = false
    private(set) var hasMore = false
    private(set) var hasUpdates = false
    private(set) var error: String?
    var search = ""
    @ObservationIgnored private let root: URL?
    @ObservationIgnored private var stores: [URL: SQLHistoryStore] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selectionGeneration = UUID()
    @ObservationIgnored private var loadedSearch = ""
    @ObservationIgnored private var revision = -1

    init(root: URL? = nil) { self.root = root }

    func configure(project: URL?) {
        generation = UUID()
        selectionGeneration = UUID()
        entries = []
        selected = nil
        search = ""
        loadedSearch = ""
        loading = false
        hasMore = false
        hasUpdates = false
        error = nil
        revision = -1
        guard let project else { store = nil
        return }
        let url = SQLHistoryStore.fileURL(project: project, root: root)
        let target = stores[url] ?? SQLHistoryStore(url: url)
        stores[url] = target
        store = target
    }

    func reload() async {
        let token = UUID()
        generation = token
        loading = true
        entries = []
        selected = nil
        hasMore = false
        loadedSearch = search
        await load(before: nil, token: token)
    }

    func loadMore() async {
        guard !loading, hasMore, loadedSearch == search, let last = entries.last else { return }
        loading = true
        await load(before: last.id, token: generation)
    }

    private func load(before: Int64?, token: UUID) async {
        guard let store else { loading = false
        return }
        let query = loadedSearch
        let observedRevision = await store.revision
        do {
            let page = try await store.page(search: query, before: before, limit: 201)
            let failure = await store.writeError
            guard token == generation, query == search else { return }
            entries.append(contentsOf: page.prefix(200))
            hasMore = page.count > 200
            error = failure
            if before == nil {
                revision = observedRevision
                hasUpdates = false
            }
        } catch {
            guard token == generation else { return }
            self.error = "No se pudo cargar el historial: " + error.localizedDescription
        }
        guard token == generation else { return }
        loading = false
    }

    func select(_ entry: SQLHistoryEntry) async {
        let token = UUID(), context = generation
        selectionGeneration = token
        guard let store else { return }
        do {
            let detail = try await store.detail(entry.id)
            guard token == selectionGeneration, context == generation else { return }
            selected = detail
        } catch {
            guard token == selectionGeneration, context == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func checkForUpdates() async {
        guard let store, !loading else { return }
        let context = generation
        let current = await store.revision
        let failure = await store.writeError
        guard context == generation, !loading else { return }
        if let failure { error = failure }
        guard current != revision else { return }
        // Preserve scroll position and selected detail while browsing the history.
        if entries.isEmpty || (entries.count <= 200 && selected == nil) { await reload() }
        else { hasUpdates = true }
    }
}
