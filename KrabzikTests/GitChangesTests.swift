import Foundation
@testable import Krabzik
import XCTest

final class GitChangesTests: XCTestCase {
    private func command(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testStatusDiffAndCounterForStagedUnstagedNewAndDeletedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try command(["init"], at: root)
        try command(["config", "user.email", "test@example.test"], at: root)
        try command(["config", "user.name", "Test"], at: root)
        try Data("old\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("remove\n".utf8).write(to: root.appendingPathComponent("deleted.txt"))
        try command(["add", "."], at: root)
        try command(["commit", "-m", "initial"], at: root)
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try command(["add", "tracked.txt"], at: root)
        try Data("final\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("new file.txt"))
        let repositories = GitChangesReader.repositories(directories: [root, root])
        XCTAssertEqual(repositories.count, 1)
        let files = try XCTUnwrap(repositories.first).files
        XCTAssertEqual(files.count, 3)
        let modified = try XCTUnwrap(files.first { $0.path == "tracked.txt" })
        XCTAssertEqual(modified.kind, "M")
        let patch = try GitChangesReader.diff(modified)
        XCTAssertTrue(patch.contains("-old"))
        XCTAssertTrue(patch.contains("+final"))
        XCTAssertEqual(files.first { $0.path == "deleted.txt" }?.kind, "D")
        let added = try XCTUnwrap(files.first { $0.path == "new file.txt" })
        XCTAssertEqual(added.kind, "A")
        XCTAssertTrue(try GitChangesReader.diff(added).contains("+hello"))
        let lines = GitDiffLine.parse(patch)
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.old == 1 && $0.new == nil })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.new == 1 && $0.old == nil })
    }

    func testNewRepositoryAndNamesWithPathspecCharacters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try command(["init"], at: root)
        let name = ":strange name.txt"
        try Data("first\n".utf8).write(to: root.appendingPathComponent(name))
        try command(["--literal-pathspecs", "add", "--", name], at: root)
        try Data("second\n".utf8).write(to: root.appendingPathComponent(name))
        let file = try XCTUnwrap(GitChangesReader.repositories(directories: [root]).first?.files.first)
        let patch = try GitChangesReader.diff(file)
        XCTAssertTrue(patch.contains("+first"))
        XCTAssertTrue(patch.contains("+second"))
    }
}

@MainActor
final class GitChangesPresentationTests: XCTestCase {
    func testDeletedFileClearsPreviousComparison() {
        let controller = GitChangesController()
        controller.patch = "+previous"
        let deleted = GitChangedFile(repository: URL(fileURLWithPath: "/tmp"), path: "removed.txt",
                                     previousPath: nil, status: " D")
        controller.select(deleted)
        XCTAssertEqual(controller.selected?.kind, "D")
        XCTAssertEqual(controller.patch, "")
        XCTAssertFalse(controller.diffLoading)
        XCTAssertTrue(controller.tabVisible)
    }
}
