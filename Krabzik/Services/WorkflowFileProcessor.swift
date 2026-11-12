import Darwin
import Foundation
import UniformTypeIdentifiers

struct WorkflowFileProcessingResult {
    let payload: [String: Any]
    let saved: Int
    let failed: Int
    let detail: String
}

enum WorkflowFileProcessor {
    static func process(_ input: [String: Any], settings: WorkflowFileSettings,
                        root: URL, preview: Bool) throws -> WorkflowFileProcessingResult {
        let source = settings.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw WorkflowError.invalid("Indicá el campo JSON que contiene los archivos.") }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let destination = try directory(root: root, relative: settings.destination)
        let value = source.split(separator: ".").reduce(input as Any?) { object, key in
            (object as? [String: Any])?[String(key)]
        }
        guard value == nil || value is [Any] else {
            throw WorkflowError.invalid("«\(source)» debe ser una lista de archivos.")
        }
        let files = value as? [Any] ?? []
        guard files.count <= 100 else { throw WorkflowError.invalid("El nodo admite hasta 100 archivos por ejecución.") }
        var output = input
        var results: [[String: Any]] = []
        var reserved = Set<String>()
        var saved = 0
        var failed = 0
        var lines: [String] = []
        if files.isEmpty {
            let message = "No hay archivos en «\(source)»."
            if settings.emptyBehavior == .fail { failed = 1 }
            lines.append(message)
        }
        for (offset, raw) in files.enumerated() {
            let item = raw as? [String: Any] ?? [:]
            let originalName = item["name"] as? String
            do {
                let mime = item["mimeType"] as? String ?? "application/octet-stream"
                let ext = fileExtension(for: mime)
                let fallback = settings.namePattern
                    .replacingOccurrences(of: "{indice}", with: String(offset + 1))
                    .replacingOccurrences(of: "{extension}", with: ext)
                let name = originalName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? originalName! : fallback
                try validateName(name)
                guard let content = item["content"] as? String else {
                    throw WorkflowError.invalid("Falta el contenido de «\(name)».")
                }
                let encoding = item["encoding"] as? String ?? "utf8"
                let bytes: Data
                switch encoding {
                case "utf8": bytes = Data(content.utf8)
                case "base64":
                    guard let decoded = Data(base64Encoded: content) else {
                        throw WorkflowError.invalid("El contenido base64 de «\(name)» no es válido.")
                    }
                    bytes = decoded
                default: throw WorkflowError.invalid("Codificación desconocida en «\(name)»: \(encoding).")
                }
                guard bytes.count <= 20_000_000 else {
                    throw WorkflowError.invalid("«\(name)» supera el límite de 20 MB.")
                }
                if !preview { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
                var number = 0
                var finalURL: URL
                while true {
                    let candidate = numbered(name, number)
                    finalURL = destination.appendingPathComponent(candidate)
                    try ensureRealPath(root: root, destination: destination, file: finalURL)
                    if reserved.contains(candidate) || FileManager.default.fileExists(atPath: finalURL.path) {
                        number += 1
                        continue
                    }
                    if preview { break }
                    if try writeExclusive(bytes, to: finalURL) { break }
                    number += 1
                }
                reserved.insert(finalURL.lastPathComponent)
                saved += 1
                let relative = String(finalURL.path.dropFirst(root.path.count + 1))
                results.append(["name": finalURL.lastPathComponent, "path": relative,
                                "status": preview ? "preview" : "saved"])
                lines.append("\(preview ? "Vista previa" : "Guardado"): \(relative)")
            } catch {
                failed += 1
                let message = error.localizedDescription
                results.append(["name": originalName ?? "archivo-\(offset + 1)", "path": "",
                                "status": "error", "error": message])
                lines.append("Error en archivo \(offset + 1): \(message)")
            }
        }
        output["fileResults"] = results
        output["fileSummary"] = ["total": files.count, "processed": saved, "failed": failed,
                                 "preview": preview]
        return WorkflowFileProcessingResult(payload: output, saved: saved, failed: failed,
                                            detail: lines.joined(separator: "\n"))
    }

    private static func directory(root: URL, relative: String) throws -> URL {
        let path = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.hasPrefix("/"), !path.contains("\0") else {
            throw WorkflowError.invalid("La ubicación debe ser una carpeta relativa al proyecto.")
        }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains("."), !parts.contains(where: { $0.isEmpty }) else {
            throw WorkflowError.invalid("La ubicación contiene una ruta inválida.")
        }
        let url = parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        try ensureRealPath(root: root, destination: url, file: nil)
        return url
    }

    private static func ensureRealPath(root: URL, destination: URL, file: URL?) throws {
        var current = root
        let suffix = destination.path.dropFirst(root.path.count).split(separator: "/")
        for part in suffix {
            current.appendPathComponent(String(part), isDirectory: true)
            try WorkflowStorage.requireRealFiles([current])
        }
        if let file { try WorkflowStorage.requireRealFiles([file]) }
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw WorkflowError.invalid("El nombre «\(name)» debe ser un archivo sin carpetas.")
        }
    }

    private static func numbered(_ name: String, _ number: Int) -> String {
        guard number > 0 else { return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        return "\(stem) (\(number))\(ext.isEmpty ? "" : ".\(ext)")"
    }

    private static func fileExtension(for mime: String) -> String {
        let known = ["text/plain": "txt", "text/markdown": "md", "application/json": "json",
                     "text/html": "html", "text/css": "css", "application/javascript": "js",
                     "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
                     "image/webp": "webp", "application/pdf": "pdf"]
        return known[mime] ?? UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws -> Bool {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw WorkflowError.invalid("No se pudo crear «\(url.lastPathComponent)»: \(String(cString: strerror(errno))).")
        }
        var succeeded = false
        defer {
            _ = Darwin.close(fd)
            if !succeeded { _ = Darwin.unlink(url.path) }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw WorkflowError.invalid("No se pudo escribir «\(url.lastPathComponent)».")
                }
                written += count
            }
        }
        succeeded = true
        return true
    }
}
