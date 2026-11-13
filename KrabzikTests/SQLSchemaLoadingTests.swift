@testable import Krabzik
import XCTest

final class SQLSchemaLoadingTests: XCTestCase {
    private actor Pages {
        var calls = 0
        let failColumns: Bool
        init(failColumns: Bool = false) { self.failColumns = failColumns }
        func read(_ sql: String) throws -> SQLResult {
            calls += 1
            let offset = Int(sql.components(separatedBy: " OFFSET ").last ?? "0") ?? 0
            var result = SQLResult(statement: 0, line: 1)
            if sql.contains("INFORMATION_SCHEMA.TABLES") {
                result.rows = (offset..<min(offset + 500, 1201)).map { ["table_\($0)", "BASE TABLE", "InnoDB"] }
            } else if sql.contains("INFORMATION_SCHEMA.COLUMNS") {
                if failColumns { throw DatabaseFailure("Permiso de metadatos denegado") }
                result.rows = (offset..<min(offset + 500, 2402)).map {
                    ["table_\($0 / 2)", $0.isMultiple(of: 2) ? "id" : "name",
                     $0.isMultiple(of: 2) ? "int" : "varchar(80)", "NO", nil, ""]
                }
            } else {
                result.rows = (offset..<min(offset + 500, 1201)).map { ["table_\($0)", "PRIMARY", "id"] }
            }
            return result
        }
    }
    private actor ProgressSink {
        var values: [SQLSchemaProgress] = []
        func append(_ value: SQLSchemaProgress) { values.append(value) }
    }

    func testLargeSchemaUsesPagesAndPublishesTablesBeforeColumns() async throws {
        let pages = Pages(), sink = ProgressSink()
        let loader = SQLSchemaLoader { try await pages.read($0) }
        let snapshot = try await loader.load(connection: DatabaseConnection(), databases: ["qa"]) { await sink.append($0) }
        XCTAssertEqual(snapshot.tables.count, 1201)
        XCTAssertTrue(snapshot.tables.allSatisfy { $0.columns.count == 2 && $0.uniqueKeys == [["id"]] })
        let calls = await pages.calls
        XCTAssertEqual(calls, 11, "1201 tables must not require 2403 queries")
        let progress = await sink.values
        XCTAssertEqual(progress[1].tables?.count, 1201)
        XCTAssertTrue(progress[1].tables?.allSatisfy { $0.columns.isEmpty } == true)
        XCTAssertEqual(progress[2].tables?.first?.columns.count, 2)
        XCTAssertFalse(snapshot.isPartial ?? true)
    }

    func testMetadataFailureStillPublishesDiscoveredTables() async {
        let pages = Pages(failColumns: true), sink = ProgressSink()
        let loader = SQLSchemaLoader { try await pages.read($0) }
        do {
            _ = try await loader.load(connection: DatabaseConnection(), databases: ["qa"]) { await sink.append($0) }
            XCTFail("Expected metadata failure")
        } catch { XCTAssertTrue(MySQLClient.message(error).contains("Permiso")) }
        let values = await sink.values
        XCTAssertEqual(values.last?.tables?.count, 1201)
    }

    private actor Source: SQLSchemaSource {
        var databaseCalls = 0
        var schemaCalls = 0
        var started = false
        let name: String
        let waits: Bool
        let fails: Bool
        private var continuation: CheckedContinuation<Void, Never>?
        init(name: String = "users", waits: Bool = false, fails: Bool = false) {
            self.name = name
            self.waits = waits
            self.fails = fails
        }
        func databases(_ config: DatabaseConnection, password: String) -> [String] {
            databaseCalls += 1
            return ["qa", "other"]
        }
        func schema(_ config: DatabaseConnection, password: String, databases: [String],
                    progress: @escaping @Sendable (SQLSchemaProgress) async -> Void) async throws -> SQLSchemaSnapshot {
            schemaCalls += 1
            let table = SQLSchemaTable(database: "qa", name: name, kind: "BASE TABLE", engine: "InnoDB", columns: [
                SQLSchemaColumn(name: "id", type: "int", nullable: false, extra: "")
            ])
            await progress(.init(database: "qa", message: "Leyendo claves…", tables: [table]))
            started = true
            if waits { await withCheckedContinuation { continuation = $0 } }
            if fails { throw DatabaseFailure("Fallo de estructura de prueba") }
            await progress(.init(database: "qa", message: "Completado", tables: [table]))
            return SQLSchemaSnapshot(connection: config, databases: databases, tables: [table], isPartial: false)
        }
        func release() { continuation?.resume()
        continuation = nil }
    }

    @MainActor private func store() throws -> (SQLSchemaStore, UserDefaults) {
        let name = "braket-schema-loading-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (SQLSchemaStore(defaults: defaults, readPassword: { _ in "" }), defaults)
    }

    @MainActor func testFirstConnectionOnlyListsDatabasesAndDoesNotBlockSelection() async throws {
        let (store, defaults) = try store()
        defer { defaults.removeObject(forKey: "mysql.schemaPreferences.v1") }
        var connection = DatabaseConnection()
        connection.database = "qa"
        let source = Source(waits: true)
        await store.discover(connection, client: source)
        XCTAssertEqual(store.choosing, connection)
        XCTAssertEqual(store.available[connection.id], ["qa", "other"])
        XCTAssertFalse(store.loading.contains(connection.id))
        let calls = await source.schemaCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testFailureClearsSpinnerRetainsPartialTreeAndAllowsCompletion() async throws {
        let (store, defaults) = try store()
        defer { defaults.removeObject(forKey: "mysql.schemaPreferences.v1") }
        let connection = DatabaseConnection()
        store.save(.init(visible: ["qa"], defaultDatabase: "qa"), for: connection)
        await store.discover(connection, client: Source(fails: true))
        XCTAssertFalse(store.loading.contains(connection.id))
        XCTAssertNil(store.progress[connection.id])
        XCTAssertTrue(store.errors[connection.id]?.contains("Fallo de estructura") == true)
        XCTAssertEqual(store.snapshot(connection)?.tables.first?.name, "users")
        XCTAssertEqual(store.snapshot(connection)?.isPartial, true)
        XCTAssertEqual(store.completions(connection: connection, database: "qa", text: "SELECT u.id FROM users u", position: 11), ["id"])
    }

    @MainActor func testCancelledOlderRequestCannotOverwriteRetry() async throws {
        let (store, defaults) = try store()
        defer {
            defaults.removeObject(forKey: "mysql.schemaPreferences.v1")
            defaults.removeObject(forKey: "mysql.schemaCache.v1")
        }
        let connection = DatabaseConnection(), old = Source(name: "stale", waits: true)
        store.save(.init(visible: ["qa"], defaultDatabase: "qa"), for: connection)
        let first = Task { await store.discover(connection, client: old) }
        while !(await old.started) { await Task.yield() }
        store.cancel(connection.id)
        XCTAssertFalse(store.loading.contains(connection.id))
        await store.discover(connection, client: Source(name: "fresh"))
        await old.release()
        await first.value
        XCTAssertEqual(store.snapshot(connection)?.tables.map(\.name), ["fresh"])
        XCTAssertNil(store.errors[connection.id])
    }

    @MainActor func testChoosingWhileLoadingCancelsAndUnlocksDatabaseSelection() async throws {
        let (store, defaults) = try store()
        defer { defaults.removeObject(forKey: "mysql.schemaPreferences.v1") }
        let connection = DatabaseConnection(), source = Source(waits: true)
        store.save(.init(visible: ["qa"], defaultDatabase: "qa"), for: connection)
        let loading = Task { await store.discover(connection, client: source) }
        while !(await source.started) { await Task.yield() }
        await store.discover(connection, client: source, choose: true)
        XCTAssertEqual(store.choosing, connection)
        XCTAssertFalse(store.loading.contains(connection.id))
        await source.release()
        await loading.value
    }

    @MainActor func testNoVisibleDatabasesDoesNotOpenMetadataConnection() async throws {
        let (store, defaults) = try store()
        defer { defaults.removeObject(forKey: "mysql.schemaPreferences.v1") }
        let connection = DatabaseConnection(), source = Source()
        store.save(.init(), for: connection)
        await store.discover(connection, client: source)
        let count = await source.schemaCalls
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.snapshot(connection)?.databases, [])
        XCTAssertFalse(store.loading.contains(connection.id))
    }

    private static func configuration() throws -> DatabaseConnection {
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mysql-test-port")
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw XCTSkip("MySQL local requerido") }
        var config = DatabaseConnection()
        config.port = port
        config.database = "krabzik_qa"
        config.tls = .disabled
        return config
    }

    func testMetadataTimeoutAndCancellationDoNotDisconnectSQLSession() async throws {
        let config = try Self.configuration(), client = MySQLClient()
        do {
            _ = try await client.connect(config, password: "")
            let start = ContinuousClock.now
            do {
                _ = try await client.metadataQuery("SELECT SLEEP(10)", configuration: config, password: "", timeoutMilliseconds: 100)
                XCTFail("Expected timeout")
            } catch { XCTAssertTrue(MySQLClient.message(error).contains("a tiempo"), MySQLClient.message(error)) }
            XCTAssertLessThan(start.duration(to: .now), .seconds(3))
            let live = await client.info(config.id)
            XCTAssertNotNil(live)
            let pending = Task { try await client.metadataQuery("SELECT SLEEP(10)", configuration: config, password: "") }
            try await Task.sleep(for: .milliseconds(100))
            pending.cancel()
            do { _ = try await pending.value
            XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            let session = await client.info(config.id)
            XCTAssertNotNil(session)
            let result = try await client.metadataQuery("SELECT 1", configuration: config, password: "")
            XCTAssertEqual(result.rows, [["1"]])
        } catch { await client.shutdown()
        throw error }
        await client.shutdown()
    }
}
