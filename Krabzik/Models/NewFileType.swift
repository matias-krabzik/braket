import Foundation

struct NewFileType: Equatable {
    let title: String
    let suffix: String
    var prefix = ""

    func filename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("."), !suffix.isEmpty else { return trimmed }
        return (trimmed.hasPrefix(prefix) ? trimmed : prefix + trimmed) + "." + suffix
    }

    func availableName(in folder: URL) throws -> String {
        for number in 1...999 {
            let name = filename(number == 1 ? "nuevo" : "nuevo \(number)")
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { return name }
        }
        throw ExplorerFileError.alreadyExists
    }

    static func contents(for filename: String) -> Data {
        guard filename.lowercased().hasSuffix(".ipynb") else { return Data() }
        return Data("""
        {"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}

        """.utf8)
    }

    static func suggestions(in folder: URL, root: URL) -> [NewFileType] {
        let files = FileManager.default
        func entries(_ url: URL) -> [String] {
            Array((try? files.contentsOfDirectory(atPath: url.path))?.sorted().prefix(256) ?? [])
        }
        func read(_ url: URL) -> String {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000 else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        func json(_ url: URL) -> [String: Any] {
            guard let data = read(url).data(using: .utf8) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let nearby = entries(folder)
        var fallback = nearby
        var current = folder.standardizedFileURL
        let boundary = root.standardizedFileURL
        var suggested: [String] = []
        var pythonTests = false
        while ExplorerFileSystem.contains(current, in: boundary) {
            let names = Set(entries(current))
            if fallback.isEmpty { fallback = names.sorted() }
            let package = json(current.appendingPathComponent("package.json"))
            let dependencies = (package["dependencies"] as? [String: Any] ?? [:])
                .merging(package["devDependencies"] as? [String: Any] ?? [:]) { first, _ in first }
            let composer = json(current.appendingPathComponent("composer.json"))
            let requires = composer["require"] as? [String: Any] ?? [:]
            let relative = folder.pathComponents.dropFirst(current.pathComponents.count)
            if names.contains("artisan") || requires["laravel/framework"] != nil {
                suggested = relative.starts(with: ["resources", "views"])
                    ? ["blade.php", "php", "html", "js", "css", "json"]
                    : ["php", "blade.php", "html", "js", "css", "json"]
                if relative.starts(with: ["resources", "css"]) { suggested.insert("css", at: 0) }
                if relative.starts(with: ["resources", "js"]) { suggested.insert("js", at: 0) }
            } else if names.contains("angular.json") || dependencies["@angular/core"] != nil {
                let config = read(current.appendingPathComponent("angular.json"))
                    .filter { !$0.isWhitespace }
                let style = ["scss", "sass", "less"].first { suffix in
                    nearby.contains(where: { $0.hasSuffix("." + suffix) }) || config.contains("\"style\":\"" + suffix + "\"")
                } ?? "css"
                suggested = ["ts", "html", style, "json"]
                suggested.insert(contentsOf: ["component.ts", "component.html", "component." + style, "spec.ts"].filter { suffix in
                    nearby.contains { $0.hasSuffix("." + suffix) }
                }, at: 0)
            } else if names.contains("pubspec.yaml") {
                suggested = ["dart", "yaml", "json"]
            } else if names.contains("pyproject.toml") || names.contains("requirements.txt") || names.contains("setup.py") {
                pythonTests = relative.contains("tests") || relative.contains("test")
                suggested = ["py", "toml", "yaml", "json"]
                if nearby.contains(where: { $0.hasSuffix(".ipynb") }) { suggested.insert("ipynb", at: 0) }
            } else if names.contains("hive-site.xml") || names.contains(".hiverc")
                        || names.contains(where: { $0.hasSuffix(".hql") || $0.hasSuffix(".q") }) {
                suggested = ["hql"]
                if names.contains(where: { $0.hasSuffix(".q") }) { suggested.append("q") }
            } else if names.contains("package.json") {
                suggested = names.contains("tsconfig.json") || dependencies["typescript"] != nil
                    ? ["ts", "js", "json"] : ["js", "json"]
                suggested.insert(contentsOf: ["mjs", "cjs"].filter { suffix in
                    nearby.contains { $0.hasSuffix("." + suffix) }
                }, at: 0)
            }
            if !suggested.isEmpty || current == boundary { break }
            current.deleteLastPathComponent()
        }
        let supported = Set(["php", "html", "css", "scss", "sass", "less", "js", "ts", "mjs", "cjs",
                             "py", "ipynb", "hql", "q", "dart", "json", "yaml", "yml", "toml", "md", "csv", "txt",
                             "swift", "kt", "java", "rs", "go", "xml", "sh"])
        let counts = Dictionary((nearby.isEmpty && suggested.isEmpty ? fallback : nearby).compactMap { name -> String? in
            let lowercased = name.lowercased()
            let suffix = suggested.sorted { $0.count > $1.count }.first { lowercased.hasSuffix("." + $0) }
                ?? (name as NSString).pathExtension.lowercased()
            return supported.contains(suffix) || suggested.contains(suffix) ? suffix : nil
        }.map { ($0, 1) }, uniquingKeysWith: +)
        let local = counts.keys.sorted {
            let first = counts[$0, default: 0], second = counts[$1, default: 0]
            return first == second ? $0 < $1 : first > second
        }
        // Las convenciones de la carpeta afinan el orden de los tipos del proyecto.
        suggested = local.filter { suggested.contains($0) } + suggested + local
        let titles = ["php": "PHP", "blade.php": "Blade", "html": "HTML", "js": "JavaScript", "ts": "TypeScript",
                      "py": "Python", "ipynb": "Jupyter", "hql": "HiveQL", "q": "HiveQL", "dart": "Dart"]
        var result = [NewFileType(title: "Archivo sin extensión", suffix: ""),
                      NewFileType(title: "SQL (.sql)", suffix: "sql")]
        if pythonTests, nearby.contains(where: { $0.hasPrefix("test_") && $0.hasSuffix(".py") }) {
            result.append(NewFileType(title: "Prueba Python (test_….py)", suffix: "py", prefix: "test_"))
        }
        for suffix in suggested where !result.contains(where: { $0.suffix == suffix && $0.prefix.isEmpty }) {
            result.append(NewFileType(title: (titles[suffix] ?? suffix.uppercased()) + " (." + suffix + ")", suffix: suffix))
        }
        return result
    }
}
