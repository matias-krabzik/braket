import Foundation

struct SidebarFileMatch: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let path: String
    let root: URL
}

struct SidebarFileSearch: Sendable {
    var matches: [SidebarFileMatch] = []
    var truncated = false

    /// Búsqueda de nombres fuera del main actor, sin recorrer carpetas generadas ni symlinks.
    static func find(_ query: String, roots: [(String, URL)], limit: Int = 200) throws -> Self {
        var result = Self()
        var visited = 0
        var seen: Set<URL> = []
        let excluded: Set<String> = [".git", "node_modules", "vendor", ".build", "DerivedData", "dist", ".next", ".angular"]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for (name, selectedRoot) in roots {
            let root = selectedRoot.resolvingSymlinksInPath().standardizedFileURL
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                visited += 1
                if visited > 20_000 { result.truncated = true
                return result }
                let values = try url.resourceValues(forKeys: Set(keys))
                if excluded.contains(url.lastPathComponent) || values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory != true else { continue }
                let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
                let path = name + "/" + relative
                if path.localizedStandardContains(query), seen.insert(url.standardizedFileURL).inserted {
                    if result.matches.count == limit { result.truncated = true
                    return result }
                    result.matches.append(SidebarFileMatch(url: url, path: path, root: root))
                }
            }
        }
        result.matches.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }
}
