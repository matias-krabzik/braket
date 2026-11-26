import Foundation

struct NodeServiceConfiguration: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case script = "Node.js", package = "Package Script" }
    enum Manager: String, Codable, CaseIterable { case npm, pnpm, yarn }
    var kind = Kind.script
    var executable = "node"
    var file = "index.js"
    var runtimeArguments: [String] = []
    var arguments: [String] = []
    var packageFile = "package.json"
    var manager = Manager.npm
    var managerExecutable = "npm"
    var script = "dev"

    var command: String {
        if kind == .script { return ([executable] + runtimeArguments + [file] + arguments).map(Shell.quote).joined(separator: " ") }
        // npm/pnpm/yarn and their child scripts resolve the same selected Node installation.
        let directory = (executable as NSString).deletingLastPathComponent
        let path = directory.isEmpty ? "" : "export PATH=\(Shell.quote(directory)):\"$PATH\"; "
        let packageDirectory = (packageFile as NSString).deletingLastPathComponent
        let cd = packageDirectory.isEmpty ? "" : "cd -- \(Shell.quote(packageDirectory)) || exit $?; "
        let separator = manager == .yarn ? [] : ["--"]
        return path + cd + ([managerExecutable, "run", script] + separator + arguments).map(Shell.quote).joined(separator: " ")
    }
    func validate() throws {
        let values = [executable, file, packageFile, managerExecutable, script] + arguments + runtimeArguments
        guard !executable.isEmpty, !file.isEmpty, !managerExecutable.isEmpty, !script.isEmpty,
              URL(fileURLWithPath: packageFile).lastPathComponent == "package.json",
              arguments.count <= 256, runtimeArguments.count <= 256,
              values.allSatisfy({ $0.count <= 4096 && !$0.contains("\0") && !$0.contains("\n") }) else {
            throw WorkspaceError.invalidText("la configuración Node.js")
        }
    }
}
