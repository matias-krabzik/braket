@testable import Krabzik
import XCTest

/// El catálogo de casos tiene que estar bien formado: es lo que `scripts/qa.sh` lista y
/// corre, así que un id repetido o una suite inventada rompen el runner y no una prueba.
final class QACatalogTests: XCTestCase {
    private struct Catalog: Decodable {
        struct Case: Decodable {
            let id: String
            let suite: String
            let title: String
            let steps: [String]
            let expect: [String]
            let test: String?
            let tags: [String]
        }

        let version: Int
        let suites: [String: String]
        let cases: [Case]
    }

    private func load() throws -> Catalog {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("cases.json")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    func testTheCatalogIsWellFormed() throws {
        let catalog = try load()
        XCTAssertEqual(catalog.version, 1)
        XCTAssertFalse(catalog.cases.isEmpty)
        var seen: Set<String> = []
        let knownTags: Set<String> = ["needs-mysql", "keychain"]
        for item in catalog.cases {
            XCTAssertTrue(seen.insert(item.id).inserted, "id repetido: " + item.id)
            XCTAssertNotNil(catalog.suites[item.suite], "suite desconocida en " + item.id)
            XCTAssertTrue(item.id.hasPrefix(item.suite + "-"), "el id no empieza con su suite: " + item.id)
            XCTAssertFalse(item.title.isEmpty, item.id)
            XCTAssertFalse(item.steps.isEmpty, "sin pasos: " + item.id)
            XCTAssertFalse(item.expect.isEmpty, "sin expectativa: " + item.id)
            for tag in item.tags { XCTAssertTrue(knownTags.contains(tag), "etiqueta desconocida «\(tag)» en " + item.id) }
            if let test = item.test {
                let parts = test.split(separator: "/")
                XCTAssertEqual(parts.count, 2, "el test de \(item.id) tiene que ser Clase/método")
                XCTAssertTrue(parts[0].hasPrefix("QA"), "la clase de \(item.id) tiene que empezar con QA")
                XCTAssertTrue(parts[1].hasPrefix("test"), "el método de \(item.id) tiene que empezar con test")
            }
        }
    }

    /// Cada clase de pruebas nombrada por el catálogo tiene que existir en el bundle: si
    /// alguien renombra una suite, el catálogo queda mintiendo y `qa.sh` no corre nada.
    func testEveryNamedTestClassExists() throws {
        let catalog = try load()
        let names = Set(catalog.cases.compactMap { $0.test?.split(separator: "/").first.map(String.init) })
        XCTAssertFalse(names.isEmpty)
        for name in names.sorted() {
            XCTAssertNotNil(NSClassFromString("KrabzikTests." + name), "no existe la clase de pruebas " + name)
        }
    }
}
