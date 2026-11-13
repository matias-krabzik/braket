@testable import Krabzik
import XCTest

@MainActor final class ExplorerFileSystemTests: XCTestCase {
    private func fixture() throws -> (URL, URL, ExplorerFileSystem) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (base, root, ExplorerFileSystem(roots: [root]))
    }

    func testCreateCopyMoveAndTrashWithoutOverwriting() throws {
        let (_, root, files) = try fixture()
        let folder = try files.create(name: "src", in: root, directory: true)
        let source = try files.create(name: "main.dart", in: folder, directory: false)
        try Data("hello".utf8).write(to: source)
        XCTAssertThrowsError(try files.create(name: "main.dart", in: folder, directory: false))
        XCTAssertThrowsError(try files.copy(source, to: folder))
        let copy = try files.copy(source, to: root)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "hello")
        let renamed = try files.move(source, to: folder, name: "app.dart")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "hello")
        let trash = try files.trash(renamed)
        defer { try? FileManager.default.moveItem(at: trash, to: renamed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
    }

    func testRootAndOutsidePathsCannotBeChanged() throws {
        let (base, root, files) = try fixture()
        let outside = base.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        XCTAssertThrowsError(try files.trash(root))
        XCTAssertThrowsError(try files.move(root, to: root, name: "other"))
        XCTAssertThrowsError(try files.trash(outside))
        XCTAssertThrowsError(try files.create(name: "../escape", in: root, directory: false))
        XCTAssertThrowsError(try files.create(name: "bad/name", in: root, directory: false))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        let imported = try files.copy(outside, to: root, external: true)
        XCTAssertEqual(try String(contentsOf: imported, encoding: .utf8), "keep")
        XCTAssertThrowsError(try files.copy(outside, to: root, external: true))
        XCTAssertEqual(try files.availableName(for: "outside.txt", in: root), "outside 2.txt")
    }

    func testLinkedParentAndNestedProjectAreProtected() throws {
        let (base, root, files) = try fixture()
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try files.create(name: "escape.txt", in: link, directory: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
        let nested = root.appendingPathComponent("nested")
        let secondRoot = nested.appendingPathComponent("child-project")
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let scoped = ExplorerFileSystem(roots: [root, secondRoot])
        XCTAssertThrowsError(try scoped.trash(nested))
        XCTAssertThrowsError(try files.move(nested, to: secondRoot))
    }

    func testBraketMetadataCannotBeMovedOrOverwritten() throws {
        let (_, root, files) = try fixture()
        let metadata = root.appendingPathComponent(".braket/automations")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let flow = metadata.appendingPathComponent("example.flow.json")
        try Data("{}".utf8).write(to: flow)
        XCTAssertThrowsError(try files.trash(flow))
        XCTAssertThrowsError(try files.move(root.appendingPathComponent(".braket"), to: root, name: "backup"))
        XCTAssertThrowsError(try files.create(name: "other.flow.json", in: metadata, directory: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flow.path))
    }

    func testMovedFolderKeepsDirtyTabsAtNewURL() async throws {
        let (_, root, files) = try fixture()
        let folder = try files.create(name: "src", in: root, directory: true)
        let url = try files.create(name: "main.dart", in: folder, directory: false)
        try Data("before".utf8).write(to: url)
        let docs = DocumentStore()
        try await docs.open(url)
        let document = try XCTUnwrap(docs.selected)
        document.text = "unsaved"
        document.isDirty = true
        let moved = try files.move(folder, to: root, name: "lib")
        docs.relocate(from: folder, to: moved)
        XCTAssertEqual(docs.selected?.url, moved.appendingPathComponent("main.dart"))
        XCTAssertEqual(docs.selected?.text, "unsaved")
        XCTAssertTrue(docs.selected?.sqlExecution === document.sqlExecution)
        XCTAssertTrue(try XCTUnwrap(docs.selected).isDirty)
        let saved = try await docs.save(try XCTUnwrap(docs.selected))
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("main.dart"), encoding: .utf8), "unsaved")
    }
}
