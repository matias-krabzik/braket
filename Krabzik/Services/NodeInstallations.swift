import Darwin
import Foundation
import Observation

struct NodeInstallation: Codable, Identifiable, Sendable {
    let tool: String
    let path: String
    let version: String
    var id: String { path }
}

@MainActor @Observable final class NodeInstallations {
    static let shared = NodeInstallations()
    private struct Cache: Codable { let date: Date
    let installations: [NodeInstallation] }
    private let defaults: UserDefaults
    private let detect: @Sendable () -> [NodeInstallation]
    private let cacheKey = "node.installations.v1"
    private(set) var installations: [NodeInstallation] = []
    private(set) var detectedAt: Date?
    private(set) var detecting = false
    private(set) var failure = ""

    init(defaults: UserDefaults = .standard, detect: @escaping @Sendable () -> [NodeInstallation] = NodeInstallations.scan) {
        self.defaults = defaults
        self.detect = detect
        if let data = defaults.data(forKey: cacheKey), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            installations = cache.installations
            detectedAt = cache.date
        }
    }
    func loadIfNeeded() async {
        guard detectedAt == nil else { return }
        await refresh()
    }
    func refresh() async {
        guard !detecting else { return }
        detecting = true
        failure = ""
        let detect = self.detect
        let result = await Task.detached(priority: .utility) { detect() }.value
        installations = result
        detectedAt = Date()
        let cache = Cache(date: detectedAt ?? Date(), installations: result)
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: cacheKey) }
        if result.isEmpty { failure = "No se encontraron instalaciones. Podés elegir un ejecutable o volver a detectar." }
        detecting = false
    }
    nonisolated static func scan() -> [NodeInstallation] {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.volta/bin",
                        home + "/.local/share/pnpm", home + "/.yarn/bin"]
        for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for name in (try? files.contentsOfDirectory(atPath: root)) ?? [] where name == "node" || name.hasPrefix("node@") {
                directories.append(root + "/" + name + "/bin")
            }
        }
        let roots = [home + "/.nvm/versions/node", home + "/.asdf/installs/nodejs", home + "/.local/share/mise/installs/node",
                     home + "/.volta/tools/image/node"]
        for root in roots {
            for name in ((try? files.contentsOfDirectory(atPath: root)) ?? []).prefix(64) { directories.append(root + "/" + name + "/bin") }
        }
        for root in [
            home + "/.fnm/node-versions",
            home + "/.local/share/fnm/node-versions",
            home + "/Library/Application Support/fnm/node-versions"
        ] {
            for name in ((try? files.contentsOfDirectory(atPath: root)) ?? []).prefix(64) {
                directories.append(root + "/" + name + "/installation/bin")
            }
        }
        var seen: Set<String> = []
        var result: [NodeInstallation] = []
        for directory in directories {
            for tool in ["node", "npm", "pnpm", "yarn"] {
                let path = directory + "/" + tool
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard files.isExecutableFile(atPath: path), seen.insert(canonical).inserted else { continue }
                if let version = version(path, directory: directory) { result.append(NodeInstallation(tool: tool, path: path,
                                                                                                      version: version)) }
            }
        }
        return result.sorted { ($0.tool, $0.path) < ($1.tool, $1.path) }
    }
    nonisolated private static func version(_ path: String, directory: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment["COREPACK_ENABLE_NETWORK"] = "0"
        environment["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value.count > 200 ? nil : value
        } catch { return nil }
    }
}
