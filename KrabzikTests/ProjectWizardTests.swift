@testable import Krabzik
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ProjectWizardTests: XCTestCase {
    private func setup() throws -> (WorkspaceController, ProjectDraft) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        var draft = ProjectDraft()
        draft.name = "Mi tienda"
        draft.folder = root
        return (WorkspaceController(defaults: defaults), draft)
    }

    func testManagedLocationCreatesYearAndCamelCaseFolderWithoutRenamingProject() async throws {
        var (controller, draft) = try setup()
        let root = draft.folder.appendingPathComponent("BraketProjects")
        draft.libraryRoot = root
        draft.year = 2026
        draft.name = "Mi primer proyecto"
        draft.useDefaultLocation()
        XCTAssertEqual(draft.folder, root.appendingPathComponent("2026/MiPrimerProyecto", isDirectory: true))
        XCTAssertNil(draft.validationMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let created = try await controller.createWorkspace(from: draft)
        XCTAssertTrue(created)
        XCTAssertEqual(try Workspace.read(from: draft.url).name, "Mi primer proyecto")
        XCTAssertEqual(draft.url.lastPathComponent, "Mi primer proyecto.kzk")
        XCTAssertNotNil(draft.validationMessage)
    }

    func testManagedFolderNamingAndCustomLocation() throws {
        let (_, original) = try setup()
        var draft = original
        draft.libraryRoot = original.folder
        draft.useDefaultLocation()
        draft.name = "API de usuarios"
        XCTAssertEqual(draft.folder.lastPathComponent, "ApiDeUsuarios")
        draft.name = "miProyecto-web"
        XCTAssertEqual(draft.folder.lastPathComponent, "MiProyectoWeb")
        draft.folder = original.folder
        draft.name = "Otra cosa"
        XCTAssertEqual(draft.folder, original.folder)
        XCTAssertFalse(draft.usesDefaultLocation)
    }

    func testCustomParentAndFolderNameAreIndependent() async throws {
        var (controller, draft) = try setup()
        let parent = draft.folder
        draft.useDefaultLocation()
        draft.location = parent
        draft.folderName = "FrontendPersonalizado"
        draft.name = "Nombre visible"
        XCTAssertEqual(draft.folder, parent.appendingPathComponent("FrontendPersonalizado", isDirectory: true))
        let created = try await controller.createWorkspace(from: draft)
        XCTAssertTrue(created)
        XCTAssertEqual(try Workspace.read(from: draft.url).name, "Nombre visible")
        for invalid in ["", "..", "../escape", "a/b", "a:b"] {
            draft.folderName = invalid
            XCTAssertNotNil(draft.validationMessage)
        }
    }

    func testSkipOptionalStepsCreatesAndOpensEmptyProjectWithoutProcesses() async throws {
        let (controller, draft) = try setup()
        let created = try await controller.createWorkspace(from: draft)
        XCTAssertTrue(created)
        XCTAssertEqual(draft.url.lastPathComponent, "Mi tienda.kzk")
        XCTAssertEqual(controller.workspaceURL, draft.url)
        XCTAssertEqual(try Workspace.read(from: draft.url).projects, [])
        XCTAssertTrue(controller.runner.runs.isEmpty)
    }

    func testDetectionDeduplicatesAndPersistsEditedTechnologyCommandAndIcon() async throws {
        var (controller, draft) = try setup()
        let web = draft.folder.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data(#"{"devDependencies":{"astro":"*"},"scripts":{"dev":"astro dev"}}"#.utf8)
            .write(to: web.appendingPathComponent("package.json"))
        draft.projects = try ProjectDraft.detect([web, web])
        XCTAssertEqual(draft.projects.count, 1)
        XCTAssertEqual(draft.projects.first?.kind, .astro)
        XCTAssertEqual(draft.projects.first?.command, "npm run dev")
        draft.projects[0].kind = .node
        draft.projects[0].command = "npm run dev -- --port 4322"
        draft.icon = ProjectIconStyle(hex: "8863D7", glass: false, letters: "API")
        let created = try await controller.createWorkspace(from: draft)
        XCTAssertTrue(created)
        let saved = try Workspace.read(from: draft.url)
        XCTAssertEqual(saved.iconStyle, draft.icon)
        XCTAssertEqual(saved.projects, draft.projects)
        XCTAssertFalse(controller.runner.runs.values.contains { $0.status.active })
    }

    func testCreateWithoutOpeningPreservesCurrentProjectAndAddsRecent() async throws {
        var (controller, draft) = try setup()
        _ = try await controller.createWorkspace(from: draft)
        let previous = controller.workspaceURL
        draft.name = "Otro"
        draft.openWhenCreated = false
        _ = try await controller.createWorkspace(from: draft)
        XCTAssertEqual(controller.workspaceURL, previous)
        XCTAssertTrue(controller.recentProjects.contains(draft.url))
        XCTAssertEqual(controller.openWorkspaceURLs, [previous].compactMap { $0 })
    }

    func testExistingFileAndInvalidNamesNeverOverwrite() async throws {
        var (controller, draft) = try setup()
        _ = try await controller.createWorkspace(from: draft)
        let original = try Data(contentsOf: draft.url)
        do {
            _ = try await controller.createWorkspace(from: draft)
            XCTFail("Must reject existing file")
        } catch {
            XCTAssertEqual(try Data(contentsOf: draft.url), original)
        }
        for name in [" ", "../escape", "bad:name", "\u{202E}hidden"] {
            draft.name = name
            XCTAssertNotNil(draft.validationMessage)
            XCTAssertThrowsError(try draft.workspace())
        }
    }

    func testIconLettersRemainCompatibleWithOlderProjects() throws {
        let old = try JSONDecoder().decode(ProjectIconStyle.self, from: Data(#"{"hex":"687080","glass":true}"#.utf8))
        XCTAssertEqual(old.label(for: "Primer proyecto"), "PP")
        let custom = ProjectIconStyle(letters: "Api")
        XCTAssertEqual(custom.label(for: "Otro nombre"), "Api")
        XCTAssertEqual(try JSONDecoder().decode(ProjectIconStyle.self, from: JSONEncoder().encode(custom)), custom)
        XCTAssertEqual(ProjectIconStyle(letters: " ").label(for: "Primer proyecto"), "PP")
        XCTAssertFalse(ProjectIconStyle(letters: "ABCDE").isValid)
        XCTAssertFalse(ProjectIconStyle(letters: "\u{202E}").isValid)
    }

    func testDetectionRejectsFilesAndMissingFolders() throws {
        let (_, draft) = try setup()
        let file = draft.folder.appendingPathComponent("file.txt")
        try Data().write(to: file)
        XCTAssertThrowsError(try ProjectDraft.detect([file]))
        XCTAssertThrowsError(try ProjectDraft.detect([draft.folder.appendingPathComponent("missing")]))
    }

    func testProjectFileTypesDeclareNewAndLegacyExtensions() throws {
        let declarations = try XCTUnwrap(Bundle.main.infoDictionary?["UTExportedTypeDeclarations"] as? [[String: Any]])
        for (type, ext) in [(UTType.kzkProject, "kzk"), (.legacyKrabzikProject, "krabzik")] {
            let declaration = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == type.identifier })
            let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
            XCTAssertEqual(tags["public.filename-extension"] as? [String], [ext])
            XCTAssertTrue(type.conforms(to: .json))
        }
        XCTAssertEqual(UTType.kzkProject.preferredFilenameExtension, "kzk")
    }

    func testLegacyProjectStillOpensWithoutRenamingOrRewritingIt() async throws {
        let (controller, draft) = try setup()
        let legacyURL = draft.folder.appendingPathComponent("Anterior.krabzik")
        let workspace = Workspace(name: "Anterior")
        try workspace.write(to: legacyURL)
        let original = try Data(contentsOf: legacyURL)
        controller.confirmTrust = { _ in .readOnly }
        await controller.openWorkspace(legacyURL)
        XCTAssertEqual(controller.workspace, workspace)
        XCTAssertEqual(controller.workspaceURL, legacyURL)
        XCTAssertEqual(try Data(contentsOf: legacyURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.deletingPathExtension().appendingPathExtension("kzk").path))
    }

    func testFilenameByteLimitIncludesTheKZKExtension() throws {
        var (_, draft) = try setup()
        draft.name = String(repeating: "界", count: 83) + "ab"
        XCTAssertEqual(draft.url.lastPathComponent.utf8.count, 255)
        XCTAssertNil(draft.validationMessage)
        draft.name += "x"
        XCTAssertNotNil(draft.validationMessage)
    }
}
