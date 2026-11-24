import Foundation
import Observation

@MainActor @Observable
final class SQLRelatedRecord {
    let target: SQLRelatedTarget
    var result: SQLResult?
    var error: String?
    var loading = true
    init(target: SQLRelatedTarget) { self.target = target }
    func cardHeight(scale: Double) -> CGFloat {
        CGFloat(error == nil ? 86 + min(4, max(1, result?.rows.count ?? 1)) * 30 : 160) * scale
    }
}

@MainActor @Observable
final class SQLResultRelations {
    var keys: [SQLTableIdentity: [SQLForeignKey]] = [:]
    var expanded: [Int: SQLRelatedRecord] = [:]
    var error: String?
    @ObservationIgnored var load: ((SQLRelatedTarget) async throws -> SQLResult)?
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]

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
        let load = load
        tasks[row] = Task { [weak self, weak record] in
            guard let record else { return }
            do {
                guard let load else { throw DatabaseFailure("La vista relacionada no está disponible.") }
                let result = try await load(target)
                guard !Task.isCancelled, self?.expanded[row] === record else { return }
                record.result = result
            } catch {
                guard !Task.isCancelled, self?.expanded[row] === record else { return }
                record.error = MySQLClient.message(error)
            }
            record.loading = false
        }
    }
}
