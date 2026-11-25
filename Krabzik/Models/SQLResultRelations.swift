import AppKit
import Observation

@MainActor @Observable
final class SQLRelatedRecord {
    let target: SQLRelatedTarget
    var result: SQLResult?
    var error: String?
    var loading = true
    var cached = false
    var elapsed: TimeInterval?
    init(target: SQLRelatedTarget) { self.target = target }
    func cardHeight(scale: Double, availableWidth: CGFloat = .infinity) -> CGFloat {
        let layout = SQLRelationLayout(scale: scale, interfaceScale: Theme.settings.uiScale)
        let body = result.map {
            layout.tableHeight(rows: $0.rows.count, horizontalScroll: layout.tableWidth($0) > availableWidth + 0.5)
        } ?? 100 * scale
        return layout.headerHeight + layout.footerHeight + body + 2 + 2 * layout.outerInset
    }
}

@MainActor @Observable
final class SQLResultRelations {
    var keys: [SQLTableIdentity: [SQLForeignKey]] = [:]
    var expanded: [Int: SQLRelatedRecord] = [:]
    var error: String?
    @ObservationIgnored var load: ((SQLRelatedTarget) async throws -> SQLResult)?
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]

    @ObservationIgnored private var cache: [Data: SQLResult] = [:]

    func targets(row: Int, draft: SQLResultDraft) -> [SQLRelatedTarget] {
        guard (0..<draft.result.rows.count).contains(row), !draft.deleted.contains(row) else { return [] }
        return keys.keys.sorted { ($0.database, $0.table) < ($1.database, $1.table) }.flatMap { source in
            (keys[source] ?? []).compactMap { key -> SQLRelatedTarget? in
                guard !key.columns.isEmpty, key.columns.count == key.referencedColumns.count,
                      key.columns.count == key.columnTypes.count else { return nil }
                var values: [String] = []
                for column in key.columns {
                    let indices = draft.result.origins.indices.filter {
                        let origin = draft.result.origins[$0]
                        return origin.database == source.database && origin.table == source.table && origin.column == column
                    }
                    guard let index = indices.first, !indices.contains(where: { draft.result.origins[$0].binary }),
                          case .text(let value) = draft.value(row: row, column: index),
                          indices.allSatisfy({ draft.value(row: row, column: $0) == .text(value) }) else { return nil }
                    values.append(value)
                }
                return SQLRelatedTarget(source: source, key: key, values: values)
            }
        }
    }

    func targets(row: Int, column: Int, draft: SQLResultDraft) -> [SQLRelatedTarget] {
        guard draft.result.origins.indices.contains(column) else { return [] }
        let origin = draft.result.origins[column]
        return targets(row: row, draft: draft).filter {
            $0.source == SQLTableIdentity(database: origin.database, table: origin.table) && $0.key.columns.contains(origin.column)
        }
    }

    func collapse(_ row: Int) {
        tasks.removeValue(forKey: row)?.cancel()
        expanded.removeValue(forKey: row)
    }

    func toggle(_ target: SQLRelatedTarget, row: Int) {
        if expanded[row]?.target == target { collapse(row)
        return }
        collapse(row)
        let record = SQLRelatedRecord(target: target)
        expanded[row] = record
        if let cached = cache[Data(target.previewQuery.utf8)] {
            record.result = cached
            record.cached = true
            record.loading = false
            return
        }
        refresh(row)
    }

    func refresh(_ row: Int) {
        guard let record = expanded[row] else { return }
        let target = record.target
        record.loading = true
        record.cached = record.result != nil
        record.error = nil
        tasks[row]?.cancel()
        let load = load
        tasks[row] = Task { [weak self, weak record] in
            guard let record else { return }
            let started = ContinuousClock.now
            do {
                guard let load else { throw DatabaseFailure("La vista relacionada no está disponible.") }
                let result = try await load(target)
                guard !Task.isCancelled, self?.expanded[row] === record else { return }
                self?.cache[Data(target.previewQuery.utf8)] = result
                record.cached = false
                record.result = result
            } catch {
                guard !Task.isCancelled, self?.expanded[row] === record else { return }
                record.error = MySQLClient.message(error)
            }
            let duration = started.duration(to: .now).components
            record.elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            record.loading = false
        }
    }
}

/// The card and native table share exact dimensions so a result row never needs its own vertical scroll.
@MainActor struct SQLRelationLayout {
    let scale: Double
    let interfaceScale: Double
    var headerHeight: CGFloat { max(36, 36 * interfaceScale) }
    var footerHeight: CGFloat { max(26, 26 * interfaceScale) }
    var outerInset: CGFloat { 12 * interfaceScale }
    var scrollerSpace: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 2 }
    var rowHeight: CGFloat {
        let font = Theme.nativeResultFont(scale: scale)
        return ceil(font.ascender - font.descender + font.leading) + 16 * scale
    }
    func tableHeight(rows: Int, horizontalScroll: Bool = false) -> CGFloat {
        rowHeight * CGFloat(1 + max(1, rows)) + CGFloat(max(1, rows)) + (horizontalScroll ? scrollerSpace : 0)
    }
    func columnWidth(_ column: Int, result: SQLResult) -> CGFloat {
        let font = Theme.nativeResultFont(scale: scale)
        let content = ([result.columns[column]] + result.rows.prefix(10).map { column < $0.count ? $0[column] ?? "NULL" : "" })
        return min(320 * scale, max(100 * scale, content.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0))
    }
    func tableWidth(_ result: SQLResult) -> CGFloat {
        result.columns.indices.reduce(0) { $0 + columnWidth($1, result: result) + 16 * scale }
    }
}
