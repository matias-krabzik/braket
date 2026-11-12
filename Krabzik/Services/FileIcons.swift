import AppKit
import ImageIO

/// Logos empaquetados y favicons locales. No hace solicitudes de red al abrir un proyecto.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]
    private static var names: [ObjectIdentifier: String] = [:]
    private static let monochromeCache = NSCache<NSImage, NSImage>()
    private static let customCache = NSCache<NSData, NSImage>()

    static func asset(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "DeveloperIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        names[ObjectIdentifier(image)] = name
        return image
    }

    static func file(_ url: URL) -> NSImage {
        if let name = assetName(for: url), let image = asset(name) { return image }
        let symbol: String
        switch url.pathExtension.lowercased() {
        case "sql": symbol = "externaldrive.fill"
        case "png", "apng", "jpg", "jpeg", "gif", "webp", "svg", "ico", "icns", "heic", "heif",
             "bmp", "tif", "tiff", "avif", "jp2", "j2k", "psd": symbol = "photo"
        case "zip", "gz", "tar": symbol = "archivebox"
        case "pdf": symbol = "doc.richtext"
        default: symbol = "doc"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
    }

    nonisolated static func assetName(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        if name == "pubspec.yaml" || name == "pubspec.lock" { return "flutter" }
        if name == "package.json" || name.hasPrefix("package-lock.") { return "npm" }
        if name == "composer.json" || name == "composer.lock" { return "composer" }
        if name == "dockerfile" || name.hasPrefix("docker-compose") { return "docker" }
        if name.hasPrefix(".git") { return "git" }
        if name.hasSuffix(".blade.php") { return "laravel" }
        let extensions = ["php": "php", "html": "html5", "htm": "html5", "css": "css3", "scss": "css3",
                          "js": "javascript", "mjs": "javascript", "cjs": "javascript", "ts": "typescript",
                          "jsx": "react", "tsx": "react", "vue": "vuejs", "svelte": "svelte", "astro": "astro",
                          "json": "json", "yaml": "yaml", "yml": "yaml", "md": "markdown", "mdx": "markdown",
                          "swift": "swift", "dart": "dart", "py": "python", "rb": "ruby", "go": "go",
                          "rs": "rust", "java": "java", "c": "c", "h": "c", "cpp": "cplusplus",
                          "hpp": "cplusplus", "cs": "csharp", "sh": "bash", "zsh": "bash"]
        return extensions[url.pathExtension.lowercased()]
    }

    nonisolated static func folderTechnology(_ name: String, inFlutterProject: Bool) -> String? {
        guard inFlutterProject else { return nil }
        switch name.lowercased() {
        case "android": return "android"
        case "ios", "macos": return "apple"
        case "web": return "chrome"
        case "windows": return "windows8"
        case "linux": return "linux"
        default: return nil
        }
    }

    nonisolated static func technology(_ kind: ProjectKind) -> String? {
        switch kind {
        case .laravel: return "laravel"
        case .php: return "php"
        case .angular: return "angular"
        case .astro: return "astro"
        case .node: return "nodejs"
        case .files: return nil
        }
    }

    static func project(_ project: CodeProject, automatic: NSImage? = nil, monochrome: Bool = false) -> NSImage {
        let fallback = technology(project.kind).flatMap(asset)
            ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage()
        let options = project.icon ?? CodeProjectIcon()
        let image: NSImage
        switch options.source {
        case .automatic: image = automatic ?? fallback
        case .technology: image = asset(options.asset) ?? fallback
        case .image:
            if let data = options.imageData {
                if let cached = customCache.object(forKey: data as NSData) { image = cached }
                else {
                    image = favicon(data) ?? fallback
                    customCache.countLimit = 64
                    customCache.setObject(image, forKey: data as NSData)
                }
            } else { image = fallback }
        }
        return display(image, monochrome: options.usesMonochrome(default: monochrome))
    }

    static func groupTint(_ project: CodeProject) -> NSColor? {
        guard let options = project.icon, options.isValid else { return nil }
        return groupTint(hex: options.tintHex, strength: options.tintStrength)
    }

    static func groupTint(hex: String?, strength: Double?) -> NSColor? {
        let opacity = strength ?? 0.12
        guard let hex, ProjectIconStyle(hex: hex).isValid, let rgb = UInt32(hex, radix: 16),
              opacity.isFinite, (0.04...0.20).contains(opacity) else { return nil }
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                       blue: Double(rgb & 255) / 255, alpha: opacity)
    }

    static func display(_ image: NSImage, monochrome: Bool) -> NSImage {
        guard monochrome, !image.isTemplate else { return image }
        if let cached = monochromeCache.object(forKey: image) { return cached }
        if let name = names[ObjectIdentifier(image)], let plain = asset(name + "-mono"), let copy = plain.copy() as? NSImage {
            copy.isTemplate = true
            monochromeCache.setObject(copy, forKey: image)
            return copy
        }
        guard let bitmap = bitmap(image, pixels: 64) else { return image }
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
                bitmap.setColor(NSColor(white: 0.32 + 0.64 * luminance, alpha: color.alphaComponent), atX: x, y: y)
            }
        }
        let result = NSImage(size: image.size)
        result.addRepresentation(bitmap)
        monochromeCache.countLimit = 128
        monochromeCache.setObject(result, forKey: image)
        return result
    }

    /// La imagen elegida se guarda dentro del .kzk; moverlo no rompe el icono.
    static func importedImage(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_048_576 else {
            throw ProjectDraftError.invalid("Elegí una imagen de hasta 1 MB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576, let image = favicon(data), let bitmap = bitmap(image, pixels: 128),
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= 131_072 else {
            throw ProjectDraftError.invalid("No se pudo leer la imagen. Usá PNG, JPEG, ICO o un SVG simple.")
        }
        return png
    }

    private static func bitmap(_ image: NSImage, pixels: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), image.size.width > 0, image.size.height > 0 else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let scale = CGFloat(pixels) / max(image.size.width, image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                              width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func favicon(_ data: Data) -> NSImage? {
        // Rasterizar solo al tamaño necesario evita decodificar imágenes enormes para una fila de 18 pt.
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 64,
               kCGImageSourceCreateThumbnailWithTransform: true
           ] as CFDictionary) {
            return NSImage(cgImage: image, size: NSSize(width: 18, height: 18))
        }
        guard safeSVG(data) else { return nil }
        return NSImage(data: data)
    }

    nonisolated static func safeSVG(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), text.localizedCaseInsensitiveContains("<svg") else { return false }
        return !["<!entity", "<!doctype", "<image", "<script", "href", "url(", "@import", "<foreignobject"]
            .contains { text.localizedCaseInsensitiveContains($0) }
    }
}

struct ProjectIconFiles: Sendable {
    let favicons: [Data]
    let technology: String?

    static func read(at directory: URL, kind: ProjectKind) -> Self {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var candidates: [URL] = []
        for path in ["index.html", "public/index.html", "src/index.html"] {
            let htmlURL = root.appendingPathComponent(path)
            guard let data = boundedData(htmlURL, within: root), let html = String(data: data, encoding: .utf8) else { continue }
            for href in iconLinks(in: html) {
                guard let components = URLComponents(string: href), components.scheme == nil, components.host == nil,
                      let path = components.percentEncodedPath.removingPercentEncoding, !path.isEmpty else { continue }
                if path.hasPrefix("/") {
                    for base in [root.appendingPathComponent("public"), root.appendingPathComponent("static"), root] {
                        candidates.append(base.appendingPathComponent(String(path.dropFirst())))
                    }
                } else { candidates.append(htmlURL.deletingLastPathComponent().appendingPathComponent(path)) }
            }
        }
        for folder in ["public", "static", "", "src", "src/assets", "app", "src/app"] {
            for name in ["favicon.svg", "favicon.ico", "favicon.png", "icon.svg", "icon.png", "apple-touch-icon.png"] {
                candidates.append(root.appendingPathComponent(folder).appendingPathComponent(name))
            }
        }
        var seen: Set<URL> = []
        let images = candidates.filter { seen.insert($0.standardizedFileURL).inserted }
            .compactMap { boundedData($0, within: root) }.prefix(8)
        var technology = FileIcons.technology(kind)
        if kind == .files {
            let manifests = [("pubspec.yaml", "flutter"), ("Package.swift", "swift"), ("Cargo.toml", "rust"),
                             ("go.mod", "go"), ("pyproject.toml", "python"), ("Gemfile", "ruby")]
            technology = manifests.first { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.0).path) }?.1
        }
        if kind == .node, let data = boundedData(root.appendingPathComponent("package.json"), within: root),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let dependencies = (json["dependencies"] as? [String: Any] ?? [:])
                .merging(json["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
            if dependencies["react"] != nil { technology = "react" }
            else if dependencies["vue"] != nil { technology = "vuejs" }
            else if dependencies["svelte"] != nil { technology = "svelte" }
        }
        return Self(favicons: Array(images), technology: technology)
    }

    private static func boundedData(_ url: URL, within root: URL) -> Data? {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(root.path + "/"),
              let values = try? target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1_048_576,
              let handle = try? FileHandle(forReadingFrom: target) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return data
    }

    private static func iconLinks(in html: String) -> [String] {
        guard let links = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: "(rel|href)\\s*=\\s*[\"']([^\"']*)[\"']",
                                                        options: .caseInsensitive) else { return [] }
        return links.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range, in: html) else { return nil }
            let tag = String(html[range])
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let key = Range(attribute.range(at: 1), in: tag), let value = Range(attribute.range(at: 2), in: tag) else { continue }
                values[String(tag[key]).lowercased()] = String(tag[value])
            }
            guard values["rel"]?.lowercased().split(separator: " ").contains(where: { $0 == "icon" || $0 == "apple-touch-icon" })
                == true else { return nil }
            return values["href"]
        }
    }
}
