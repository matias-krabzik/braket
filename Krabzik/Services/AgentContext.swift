import Foundation

/// Instantánea acotada del editor y los procesos, capturada por AgentBridge en el
/// main actor. Los archivos restantes se consultan con las herramientas de Codex.
enum AgentContext {
    static let marker = "<braket_context>"
    static let toolName = "braket_get_context"
    static let tool: JSONValue = .object([
        "type": .string("function"), "name": .string(toolName),
        "description": .string("Consulta el estado actual de Braket: archivo activo, selección, archivos abiertos y salida de procesos."),
        "inputSchema": .object(["type": .string("object"), "properties": .object([:]),
                                "additionalProperties": .bool(false), "required": .array([])])
    ])

    static func permits(_ url: URL, scope: AgentScope) -> Bool {
        guard scope.contains(url) else { return false }
        let parts = url.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        let resolved = url.resolvingSymlinksInPath()
        let name = resolved.lastPathComponent.lowercased()
        return !parts.contains(where: { [".git", ".ssh", ".aws", ".codex"].contains($0) })
            && name != ".env" && !name.hasPrefix(".env.")
            && !["pem", "key", "p12", "pfx"].contains(resolved.pathExtension.lowercased())
            && !["credentials", "credentials.json", "auth.json"].contains(name)
    }

    @MainActor static func capture(scope: AgentScope, docs: DocumentStore,
                                   workspace: Workspace, url: URL, runner: ProcessRunner) -> String {
        var value: [String: JSONValue] = [
            "project": .string(workspace.name),
            "openFiles": .array(docs.documents.filter { permits($0.url, scope: scope) }.prefix(30).map { .string($0.url.path) })
        ]
        if let document = docs.selected, document.previewImage == nil, permits(document.url, scope: scope) {
            let source = document.text as NSString
            let cursor = min(max(0, document.selectedRange.location), source.length)
            let start = max(0, cursor - 2_000)
            let length = min(6_000, source.length - start)
            var active: [String: JSONValue] = [
                "path": .string(document.url.path), "language": .string(document.language),
                "line": .number(Double(document.line)), "column": .number(Double(document.column)),
                "unsavedChanges": .bool(document.isDirty), "externalChange": .bool(document.hasExternalChange),
                "excerpt": .string(source.substring(with: NSRange(location: start, length: length))),
                "excerptUTF16Offset": .number(Double(start)), "excerptTruncated": .bool(length < source.length)
            ]
            if document.selectedRange.length > 0, cursor < source.length {
                let length = min(document.selectedRange.length, source.length - cursor, 6_000)
                active["selection"] = .string(source.substring(with: NSRange(location: cursor, length: length)))
                active["selectionTruncated"] = .bool(length < document.selectedRange.length)
            }
            value["activeFile"] = .object(active)
        }
        value["processes"] = .array(workspace.projects.filter {
            scope.contains($0.directory(relativeTo: url))
        }.prefix(4).compactMap { project in
            guard let run = runner.runs[project.id], run.workspaceURL == url.standardizedFileURL else { return nil }
            return .object(["project": .string(project.name), "status": .string(run.status.label),
                            "recentOutput": .string(String(run.output.suffix(2_000)))])
        })
        return Self.marker + "\n" + JSONValue.object(value).pretty + "\n</braket_context>"
    }
}
