@testable import Krabzik
import XCTest

@MainActor
final class FileIconsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPackagedVectorLogosAndFileTypes() throws {
        for name in [
            "flutter",
            "android",
            "apple",
            "chrome",
            "windows8",
            "linux",
            "laravel",
            "php",
            "angular",
            "astro",
            "nodejs",
            "html5",
            "css3",
            "javascript",
            "typescript",
            "react",
            "vuejs",
            "svelte",
            "json",
            "yaml",
            "markdown",
            "swift",
            "dart",
            "python",
            "ruby",
            "go",
            "rust",
            "java",
            "c",
            "cplusplus",
            "csharp",
            "docker",
            "git",
            "bash",
            "npm",
            "composer"
        ] {
            XCTAssertTrue(try XCTUnwrap(FileIcons.asset(name), name).isValid)
        }
        let mappings = ["view.blade.php": "laravel", "index.php": "php", "App.TSX": "react", "package.json": "npm",
                        "Dockerfile": "docker", ".gitignore": "git", "composer.lock": "composer", "style.css": "css3"]
        for (file, expected) in mappings { XCTAssertEqual(FileIcons.assetName(for: URL(fileURLWithPath: file)), expected) }
        XCTAssertNil(FileIcons.assetName(for: URL(fileURLWithPath: "other.xyz")))
        XCTAssertEqual(FileIcons.assetName(for: URL(fileURLWithPath: "pubspec.yaml")), "flutter")
    }

    func testFlutterDestinationsUsePlatformIcons() throws {
        let root = try directory()
        try Data("name: sample".utf8).write(to: root.appendingPathComponent("pubspec.yaml"))
        XCTAssertEqual(ProjectIconFiles.read(at: root, kind: .files).technology, "flutter")
        let destinations = ["android": "android", "ios": "apple", "macos": "apple", "web": "chrome",
                            "windows": "windows8", "linux": "linux"]
        for (folder, icon) in destinations {
            XCTAssertEqual(FileIcons.folderTechnology(folder, inFlutterProject: true), icon)
            XCTAssertNil(FileIcons.folderTechnology(folder, inFlutterProject: false))
        }
        XCTAssertNil(FileIcons.folderTechnology("lib", inFlutterProject: true))
    }

    func testDeclaredLocalFaviconTakesPriorityAndInvalidDataFallsBack() throws {
        let root = try directory()
        let publicFolder = root.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="red"/></svg>"#
            .utf8)
        try svg.write(to: publicFolder.appendingPathComponent("brand.svg"))
        try Data(#"<link href='/brand.svg?v=2' rel='shortcut icon'>"#.utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("broken".utf8).write(to: root.appendingPathComponent("favicon.ico"))
        let result = ProjectIconFiles.read(at: root, kind: .astro)
        XCTAssertEqual(result.favicons.first, svg)
        XCTAssertNotNil(FileIcons.favicon(svg))
        XCTAssertNil(FileIcons.favicon(Data("broken".utf8)))
        XCTAssertEqual(result.technology, "astro")
    }

    func testFaviconDoesNotReadOutsideProjectOrOversizedFiles() throws {
        let root = try directory(), external = try directory()
        let secret = external.appendingPathComponent("icon.svg")
        try Data("external".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("favicon.svg"), withDestinationURL: secret)
        try Data(repeating: 1, count: 1_048_577).write(to: root.appendingPathComponent("favicon.png"))
        let html = "<link rel='icon' href='https://example.com/icon.png'><link rel='icon' href='\(secret.path)'>"
        try Data(html.utf8).write(to: root.appendingPathComponent("index.html"))
        XCTAssertTrue(ProjectIconFiles.read(at: root, kind: .laravel).favicons.isEmpty)
        XCTAssertEqual(ProjectIconFiles.read(at: root, kind: .laravel).technology, "laravel")
    }

    func testMonochromePreservesOriginalAndSupportsOverrides() throws {
        let original = try XCTUnwrap(FileIcons.asset("javascript"))
        let mono = FileIcons.display(original, monochrome: true)
        XCTAssertTrue(mono.isValid)
        XCTAssertTrue(mono.isTemplate)
        XCTAssertFalse(original.isTemplate)
        XCTAssertTrue(FileIcons.display(original, monochrome: false) === original)
        var project = CodeProject(name: "Web", path: ".", kind: .node, command: "")
        project.icon = CodeProjectIcon(source: .technology, asset: "laravel", rendering: .color)
        XCTAssertTrue(FileIcons.project(project, monochrome: true) === FileIcons.asset("laravel"))
        project.icon?.rendering = .monochrome
        XCTAssertTrue(FileIcons.project(project).isValid)
    }

    func testCustomIconPersistsAndDefaultsToMonochrome() throws {
        let root = try directory()
        let svg = try XCTUnwrap(Bundle.main.url(forResource: "laravel", withExtension: "svg", subdirectory: "DeveloperIcons"))
        let png = try FileIcons.importedImage(svg)
        XCTAssertLessThanOrEqual(png.count, 131_072)
        var project = CodeProject(name: "API", path: root.path, kind: .laravel, command: "")
        project.icon = CodeProjectIcon(source: .image, rendering: .color, imageData: png)
        var workspace = Workspace(name: "Test", projects: [project])
        workspace.codeIconMonochrome = true
        let url = root.appendingPathComponent("Test.krabzik")
        try workspace.write(to: url)
        XCTAssertEqual(try Workspace.read(from: url), workspace)
        let old = try JSONDecoder().decode(Workspace.self, from: Data(#"{"version":1,"name":"Old","projects":[]}"#.utf8))
        XCTAssertTrue(old.codeIconMonochrome)
        XCTAssertFalse(CodeProjectIcon(source: .image).isValid)
        XCTAssertFalse(CodeProjectIcon(asset: "../../unknown").isValid)
    }

    func testGroupTintPersistsRegardlessOfIconRendering() throws {
        var project = CodeProject(name: "API", path: ".", kind: .laravel, command: "")
        project.icon = CodeProjectIcon(tintHex: "8863D7")
        let tint = try XCTUnwrap(FileIcons.groupTint(project))
        XCTAssertEqual(tint.alphaComponent, 0.12, accuracy: 0.001)
        let decoded = try JSONDecoder().decode(CodeProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.icon, project.icon)
        project.icon?.rendering = .color
        XCTAssertNotNil(FileIcons.groupTint(project))
        XCTAssertFalse(CodeProjectIcon(tintHex: "invalid").isValid)
        XCTAssertFalse(CodeProjectIcon(tintHex: "8863D7", tintStrength: 0.8).isValid)
        let explicit = try JSONDecoder().decode(Workspace.self,
                                                from: Data(#"{"version":1,"name":"Color","codeIconMonochrome":false}"#.utf8))
        XCTAssertFalse(explicit.codeIconMonochrome)
    }

    func testConnectionTintRoundTripAndValidation() throws {
        var connection = DatabaseConnection()
        connection.tintHex = "D76E6E"
        connection.tintStrength = 0.10
        XCTAssertEqual(try connection.validated(), connection)
        let data = try JSONEncoder().encode(connection)
        XCTAssertEqual(try JSONDecoder().decode(DatabaseConnection.self, from: data), connection)
        connection.tintHex = "invalid"
        XCTAssertThrowsError(try connection.validated())
        connection.tintHex = nil
        connection.tintStrength = 0.9
        XCTAssertThrowsError(try connection.validated())
    }

    func testChangingOnlyIconDoesNotCloseDirtyDocuments() async throws {
        let root = try directory()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let controller = WorkspaceController(defaults: defaults)
        var project = CodeProject(name: "API", path: root.path, kind: .laravel, command: "")
        let url = root.appendingPathComponent("Test.krabzik")
        try Workspace(name: "Test", projects: [project]).write(to: url)
        controller.trust.markTrusted(url)
        await controller.openWorkspace(url)
        let file = root.appendingPathComponent("file.txt")
        try Data("saved".utf8).write(to: file)
        try await controller.docs.open(file)
        let document = try XCTUnwrap(controller.selectedDocument)
        document.text = "unsaved"
        document.isDirty = true
        project.icon = CodeProjectIcon(source: .technology, asset: "php")
        let saved = await controller.saveSubproject(project)
        XCTAssertTrue(saved)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.text, "unsaved")
        XCTAssertEqual(try Workspace.read(from: url).projects.first?.icon, project.icon)
    }

    func testNodeFrameworkFallbackUsesPackageDependencies() throws {
        let root = try directory()
        try Data(#"{"dependencies":{"react":"*"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        XCTAssertEqual(ProjectIconFiles.read(at: root, kind: .node).technology, "react")
        try Data("package".utf8).write(to: root.appendingPathComponent("Package.swift"))
        XCTAssertEqual(ProjectIconFiles.read(at: root, kind: .files).technology, "swift")
    }
}
