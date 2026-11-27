import Foundation
import Observation

struct GitChangedFile: Identifiable, Equatable, Sendable {
    let repository: URL
    let path: String
    let previousPath: String?
    let status: String
    var id: String { repository.path + "\u{0}" + path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var kind: String {
        if status.contains("D") { return "D" }
        if status == "??" || status.contains("A") { return "A" }
        if status.contains("R") { return "R" }
        if status.contains("U") { return "U" }
        return "M"
    }
}

struct GitRepositoryChanges: Identifiable, Equatable, Sendable {
    let root: URL
    let branch: String
    let files: [GitChangedFile]
    var error: String?
    var id: URL { root }
}

/// Read-only Git operations. No shell, optional locks, external diff or text conversion.
enum GitChangesReader {
    struct Output: Sendable {
        let status: Int32
        let data: Data
        let truncated: Bool
    }

    static func run(_ arguments: [String], directory: URL, limit: Int = 4_000_000) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.pager=cat",
                             "-c", "diff.external=", "-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_EXTERNAL_DIFF", "GIT_OBJECT_DIRECTORY"] {
            environment.removeValue(forKey: key)
        }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        pipe.fileHandleForWriting.closeFile()
        var data = Data()
        var truncated = false
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            if data.count + chunk.count > limit {
                truncated = true
                if process.isRunning { process.terminate() }
                break
            }
            data.append(chunk)
        }
        pipe.fileHandleForReading.closeFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, data: data, truncated: truncated)
    }

    static func repositories(directories: [URL]) -> [GitRepositoryChanges] {
        var roots = Set<URL>()
        var result: [GitRepositoryChanges] = []
        for directory in directories {
            guard let output = try? run(["rev-parse", "--show-toplevel"], directory: directory), output.status == 0,
                  let path = String(data: output.data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                  !path.isEmpty else { continue }
            let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard roots.insert(root).inserted else { continue }
            let status = try? run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], directory: root)
            let branchData = try? run(["branch", "--show-current"], directory: root)
            let branch = branchData.flatMap { String(data: $0.data, encoding: .utf8) }?.trimmingCharacters(in: .newlines) ?? ""
            guard let status, status.status == 0, !status.truncated else {
                result.append(GitRepositoryChanges(root: root, branch: branch.isEmpty ? "HEAD" : branch, files: [],
                                                   error: "No se pudo leer el estado del repositorio."))
                continue
            }
            let records = status.data.split(separator: 0, omittingEmptySubsequences: true)
            var files: [GitChangedFile] = []
            var index = 0
            while index < records.count {
                let record = records[index]
                guard record.count >= 4, let text = String(data: record, encoding: .utf8) else { index += 1
                    continue }
                let code = String(text.prefix(2))
                let path = String(text.dropFirst(3))
                var previous: String?
                if code.contains("R") || code.contains("C"), index + 1 < records.count {
                    index += 1
                    previous = String(data: records[index], encoding: .utf8)
                }
                files.append(GitChangedFile(repository: root, path: path, previousPath: previous, status: code))
                index += 1
            }
            result.append(GitRepositoryChanges(root: root, branch: branch.isEmpty ? "HEAD" : branch,
                                               files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }))
        }
        return result.sorted { $0.root.path.localizedStandardCompare($1.root.path) == .orderedAscending }
    }

    static func diff(_ file: GitChangedFile) throws -> String {
        let args: [String]
        if file.status == "??" {
            args = ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", file.path]
        } else {
            let head = try run(["rev-parse", "--verify", "HEAD"], directory: file.repository)
            let paths = [file.previousPath, file.path].compactMap { $0 }
            if head.status == 0 {
                args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD", "--"] + paths
            } else {
                let staged = try run(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--"] + paths,
                                     directory: file.repository)
                let unstaged = try run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--"] + paths,
                                       directory: file.repository)
                return String(decoding: staged.data + unstaged.data, as: UTF8.self)
            }
        }
        let output = try run(args, directory: file.repository)
        guard output.truncated || output.status == 0 || (file.status == "??" && output.status == 1) else {
            throw GitChangesError.failed
        }
        let text = String(decoding: output.data, as: UTF8.self)
        return output.truncated ? text + "\nLa comparación supera el límite de visualización." : text
    }
}

enum GitChangesError: LocalizedError {
    case failed
    var errorDescription: String? { "No se pudo leer la comparación. Actualizá la lista de cambios." }
}

@MainActor @Observable final class GitChangesController {
    var repositories: [GitRepositoryChanges] = []
    var selected: GitChangedFile?
    var patch = ""
    var loading = false
    var diffLoading = false
    var sidebarVisible = false
    var tabOpen = false
    var tabVisible = false
    var error: String?
    private var generation = 0
    private var diffGeneration = 0
    var count: Int { repositories.reduce(0) { $0 + $1.files.count } }
    var files: [GitChangedFile] { repositories.flatMap(\.files) }

    func reset() {
        generation += 1
        diffGeneration += 1
        repositories = []
        selected = nil
        patch = ""
        loading = false
        diffLoading = false
        sidebarVisible = false
        tabOpen = false
        tabVisible = false
        error = nil
    }

    func refresh(directories: [URL]) async {
        guard !loading else { return }
        generation += 1
        let current = generation
        loading = true
        let values = await Task.detached(priority: .utility) { GitChangesReader.repositories(directories: directories) }.value
        guard generation == current else { return }
        repositories = values
        loading = false
        if let selected, let updated = files.first(where: { $0.id == selected.id }) {
            self.selected = updated
        } else if selected != nil {
            selected = nil
            patch = ""
        }
    }

    func select(_ file: GitChangedFile) {
        if selected?.id != file.id { patch = "" }
        selected = file
        tabOpen = true
        tabVisible = true
        if file.kind == "D" {
            diffGeneration += 1
            diffLoading = false
            error = nil
            patch = ""
        } else { loadDiff(file) }
    }

    func loadDiff(_ file: GitChangedFile, showProgress: Bool = true) {
        diffGeneration += 1
        let current = diffGeneration
        if showProgress { diffLoading = true }
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try GitChangesReader.diff(file) } }.value
            guard current == diffGeneration else { return }
            diffLoading = false
            switch result {
            case .success(let text): patch = text
            case .failure(let failure): patch = ""
                error = failure.localizedDescription
            }
        }
    }
}

struct GitDiffLine {
    enum Kind { case added, removed, hunk, context }
    let old: Int?
    let new: Int?
    let text: String
    let kind: Kind

    static func parse(_ patch: String) -> [GitDiffLine] {
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        var lines: [GitDiffLine] = []
        patch.enumerateLines { line, stop in
            if lines.count >= 10_000 {
                lines.append(GitDiffLine(old: nil, new: nil, text: "La comparación supera el límite de visualización.", kind: .context))
                stop = true
                return
            }
            if line.hasPrefix("@@ ") {
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldLine = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                inHunk = true
                lines.append(GitDiffLine(old: nil, new: nil, text: line, kind: .hunk))
            } else if line.hasPrefix("diff --git ") {
                inHunk = false
            } else if inHunk && line.hasPrefix("+") {
                lines.append(GitDiffLine(old: nil, new: newLine, text: line, kind: .added))
                newLine += 1
            } else if inHunk && line.hasPrefix("-") {
                lines.append(GitDiffLine(old: oldLine, new: nil, text: line, kind: .removed))
                oldLine += 1
            } else if inHunk && line.hasPrefix(" ") {
                lines.append(GitDiffLine(old: oldLine, new: newLine, text: line, kind: .context))
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("La comparación supera") || line.hasPrefix("\\") {
                lines.append(GitDiffLine(old: nil, new: nil, text: line, kind: .context))
            }
        }
        return lines
    }
}
