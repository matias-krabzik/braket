import AppKit
import SwiftUI

/// Vista nativa del Markdown. El texto se toma del editor después de una pausa breve:
/// leer NSTextView.string en cada tecla copiaría el documento entero.
struct MarkdownPreview: View {
    let document: EditorDocument
    let projectRoots: [URL]
    @Bindable private var settings = AppSettings.shared
    @State private var blocks: [MarkdownBlocks.Block] = []
    private var zoom: CGFloat { CGFloat(settings.markdownPreviewZoom) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13 * zoom) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 820 * zoom, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .padding(.bottom, 44)
        }
        .background(Theme.background)
        .overlay(alignment: .bottomTrailing) { zoomControls.padding(12) }
        .task(id: document.previewRevision) {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let source = document.text
            let rendered = await Task.detached(priority: .userInitiated) {
                MarkdownBlocks.parse(source)
            }.value
            guard !Task.isCancelled else { return }
            blocks = rendered
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                settings.markdownPreviewZoom = max(0.7, (settings.markdownPreviewZoom * 10 - 1).rounded() / 10)
            } label: { Image(systemName: "minus") }
                .disabled(settings.markdownPreviewZoom <= 0.7)
                .help("Reducir zoom de Markdown")
                .accessibilityLabel("Reducir zoom de Markdown")
            Text("\(Int((settings.markdownPreviewZoom * 100).rounded())) %")
                .monospacedDigit().frame(width: 48)
                .accessibilityLabel("Zoom de Markdown")
            Button {
                settings.markdownPreviewZoom = min(2, (settings.markdownPreviewZoom * 10 + 1).rounded() / 10)
            } label: { Image(systemName: "plus") }
                .disabled(settings.markdownPreviewZoom >= 2)
                .help("Ampliar zoom de Markdown")
                .accessibilityLabel("Ampliar zoom de Markdown")
        }
        .font(.system(size: 11)).buttonStyle(.borderless)
        .padding(7).background(Theme.bar, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let content):
            inline(content)
                .font(.system(size: max(15, 30 - CGFloat(level - 1) * 3) * zoom, weight: .semibold))
                .textSelection(.enabled)
                .padding(.top, level == 1 ? 8 : 4)
        case .paragraph(let content):
            inline(content).font(.system(size: 13 * zoom)).lineSpacing(5 * zoom).textSelection(.enabled)
        case .quote(let content):
            inline(content).font(.system(size: 13 * zoom)).lineSpacing(5 * zoom)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 13).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.55)).frame(width: 3) }
        case .listItem(let level, let marker, let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).frame(width: 23 * zoom, alignment: .trailing).foregroundStyle(Theme.accent)
                inline(content).textSelection(.enabled)
            }
            .font(.system(size: 13 * zoom)).padding(.leading, CGFloat(level) * 18 * zoom)
        case .code(let language, let content):
            VStack(alignment: .leading, spacing: 8) {
                if !language.isEmpty {
                    Text(language).font(.system(size: 10 * zoom, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(content).font(.system(size: 12 * zoom, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bar, in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 8)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell)
                                .font(.system(size: 12 * zoom, weight: rowIndex == 0 ? .semibold : .regular))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bar, in: RoundedRectangle(cornerRadius: 8))
        case .image(let alt, let path):
            MarkdownLocalImage(url: localImageURL(path), alt: alt.isEmpty ? path : alt, zoom: zoom)
        }
    }

    private func inline(_ content: String) -> Text {
        guard let value = try? AttributedString(markdown: content,
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return Text(content)
        }
        return Text(value)
    }

    private func localImageURL(_ path: String) -> URL? {
        guard !path.hasPrefix("/"), !path.contains("://"), !path.contains("\0") else { return nil }
        let url = document.url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        guard projectRoots.contains(where: { ExplorerFileSystem.contains(url, in: $0) }),
              projectRoots.contains(where: { ExplorerFileSystem.contains(url.resolvingSymlinksInPath(), in: $0) }) else {
            return nil
        }
        return url
    }
}

private struct MarkdownLocalImage: View {
    let url: URL?
    let alt: String
    let zoom: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading, spacing: 5) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 820 * zoom)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(alt).font(.system(size: 11 * zoom)).foregroundStyle(.secondary)
                }
            } else {
                Label(alt, systemImage: "photo").font(.system(size: 12 * zoom)).foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            let data = try? await Task.detached(priority: .utility) { try DocumentIO.preview(url) }.value
            guard !Task.isCancelled, let data else { return }
            image = NSImage(data: data)
        }
    }
}

enum MarkdownBlocks {
    enum Block: Equatable, Sendable {
        case heading(Int, String), paragraph(String), quote(String), listItem(Int, String, String)
        case code(String, String), rule, table([[String]]), image(String, String)
    }

    static func parse(_ source: String) -> [Block] {
        let lines = source.components(separatedBy: .newlines)
        var result: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                result.append(.code(language, code.joined(separator: "\n")))
                index += 1
                continue
            }
            if let level = headingLevel(trimmed) {
                result.append(.heading(level, String(trimmed.dropFirst(level + 1))))
            } else if ["---", "***", "___"].contains(trimmed) {
                result.append(.rule)
            } else if trimmed.hasPrefix("> ") {
                result.append(.quote(String(trimmed.dropFirst(2))))
            } else if let item = listItem(line) {
                result.append(.listItem(item.level, item.marker, item.content))
            } else if let image = image(trimmed) {
                result.append(.image(image.alt, image.path))
            } else if index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                var rows = [tableCells(line)]
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                result.append(.table(rows))
                continue
            } else {
                var paragraph = [trimmed]
                while index + 1 < lines.count {
                    let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || next.hasPrefix("# ") || next.hasPrefix("## ") || next.hasPrefix("> ")
                        || next.hasPrefix("```") || next.hasPrefix("~~~") || listItem(next) != nil { break }
                    index += 1
                    paragraph.append(next)
                }
                result.append(.paragraph(paragraph.joined(separator: " ")))
            }
            index += 1
        }
        return result
    }

    private static func headingLevel(_ line: String) -> Int? {
        let count = line.prefix { $0 == "#" }.count
        return (1...6).contains(count) && line.dropFirst(count).first == " " ? count : nil
    }

    private static func listItem(_ line: String) -> (level: Int, marker: String, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = min(line.prefix { $0 == " " }.count / 2, 6)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (indent, "•", String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty && trimmed.dropFirst(digits.count).hasPrefix(". ") {
            return (indent, String(digits) + ".", String(trimmed.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private static func image(_ line: String) -> (alt: String, path: String)? {
        guard line.hasPrefix("!["), let middle = line.range(of: "]("), line.hasSuffix(")") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<middle.lowerBound])
        let path = String(line[middle.upperBound..<line.index(before: line.endIndex)])
        return path.isEmpty ? nil : (alt, path)
    }

    private static func tableCells(_ line: String) -> [String] {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = tableCells(line)
        return cells.count >= 2 && cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }
}
