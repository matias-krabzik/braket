import Foundation

enum WorkspaceRelocation {
    static func move(_ workspace: Workspace, from source: URL, to destination: URL) throws -> Workspace {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return workspace }
        guard try Workspace.read(from: source) == workspace else { throw WorkspaceError.externalChange }
        var updated = workspace
        updated.projects = workspace.projects.map { project in
            var moved = project
            moved.path = project.directory(relativeTo: source).path
            return moved
        }
        updated.scripts = workspace.scripts.map {
            $0.hasPrefix("/") ? $0 : source.deletingLastPathComponent().appendingPathComponent($0).standardizedFileURL.path
        }
        try updated.checkFormat()
        let original = try Data(contentsOf: source)
        // copyItem refuses to overwrite an existing destination.
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            try updated.write(to: destination)
            guard try Data(contentsOf: source) == original else { throw WorkspaceError.externalChange }
            try FileManager.default.removeItem(at: source)
        } catch {
            do { try FileManager.default.removeItem(at: destination) }
            catch { Log.workspace.error("No se pudo retirar la copia incompleta: \(error.localizedDescription, privacy: .public)") }
            throw error
        }
        return updated
    }
}

extension WorkspaceController {
    func projectModel(for url: URL) -> Workspace? {
        workspaceURL == url ? workspace : openWorkspaceModels[url]
    }

    @discardableResult
    func saveProjectIdentity(name: String, icon: ProjectIconStyle, codeIconMonochrome: Bool? = nil) -> Bool {
        guard !isReadOnly, !isSwitchingWorkspace, var updated = workspace, let url = workspaceURL else { return false }
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.iconStyle = icon
        if let codeIconMonochrome { updated.codeIconMonochrome = codeIconMonochrome }
        do {
            guard !updated.name.isEmpty else { throw WorkspaceError.invalidText("el nombre del proyecto") }
            try updated.checkFormat()
            try session.save(updated)
            openWorkspaceModels[url] = updated
            return true
        } catch { errors.report(error)
        return false }
    }

    func saveSubproject(_ project: CodeProject) async -> Bool {
        guard !isReadOnly, var updated = workspace, let url = workspaceURL,
              let index = updated.projects.firstIndex(where: { $0.id == project.id }), session.beginSwitch() else { return false }
        defer { session.endSwitch() }
        updated.projects[index] = project
        do {
            guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkspaceError.invalidText("el nombre del subproyecto")
            }
            try updated.checkFormat()
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project.directory(relativeTo: url).path, isDirectory: &directory),
                  directory.boolValue else { throw WorkspaceError.missingFolder }
            let previous = workspace?.projects[index]
            let affectsExecution = previous?.path != project.path || previous?.kind != project.kind || previous?.command != project.command
            if affectsExecution { guard await prepareToLeave() else { return false } }
            try session.save(updated)
            trust.approve(command: project.command, project: project.id, workspaceURL: url)
            openWorkspaceModels[url] = updated
            projects.warmUp(updated.projects)
            return true
        } catch { errors.report(error)
        return false }
    }

    func relocateWorkspace(to destination: URL, createDirectory: Bool = false) async -> Bool {
        guard !isReadOnly, let source = workspaceURL, let workspace, session.beginSwitch() else { return false }
        defer { session.endSwitch() }
        let destination = destination.standardizedFileURL
        guard destination != source else { return true }
        guard !openWorkspaceURLs.contains(destination), await prepareToLeave() else { return false }
        do {
            if createDirectory {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let moved = try WorkspaceRelocation.move(workspace, from: source, to: destination)
            trust.markTrusted(destination)
            for project in workspace.projects where trust.isApproved(command: project.command, project: project.id, workspaceURL: source) {
                trust.approve(command: project.command, project: project.id, workspaceURL: destination)
            }
            trust.forget(source)
            adoptRelocatedWorkspace(moved, from: source, to: destination)
            return true
        } catch { errors.report(error)
        return false }
    }
}
