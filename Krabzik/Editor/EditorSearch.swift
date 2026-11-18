import AppKit
import Observation

struct EditorSearchOptions: Equatable, Sendable {
    var caseSensitive = false
    var wholeWord = false
    var regularExpression = false

    func expression(_ query: String) throws -> NSRegularExpression {
        var pattern = regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])" }
        return try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }
}

struct EditorSearchMatch: Sendable {
    let captures: [NSRange]
    var range: NSRange { captures[0] }
}

enum EditorSearchMatcher {
    static func matches(_ source: String, query: String, options: EditorSearchOptions) throws -> [EditorSearchMatch] {
        guard !query.isEmpty else { return [] }
        let regex = try options.expression(query)
        let deadline = ContinuousClock.now + .seconds(2)
        var matches: [EditorSearchMatch] = []
        var interrupted = false
        regex.enumerateMatches(in: source, options: [.reportProgress], range: NSRange(location: 0, length: source.utf16.count)) {
            result, _, stop in
            if Task.isCancelled || ContinuousClock.now > deadline {
                interrupted = true
                stop.pointee = true
                return
            }
            if let result {
                matches.append(EditorSearchMatch(captures: (0..<result.numberOfRanges).map { result.range(at: $0) }))
            }
        }
        if interrupted { throw DatabaseFailure("La búsqueda tardó demasiado. Simplificá la expresión.") }
        return matches
    }

    static func replacement(_ template: String, match: EditorSearchMatch, source: String,
                            query: String, options: EditorSearchOptions) throws -> String {
        guard options.regularExpression else { return template }
        let regex = try options.expression(query)
        var captures = match.captures
        return captures.withUnsafeMutableBufferPointer { ranges in
            guard let pointer = ranges.baseAddress else { return template }
            let result = NSTextCheckingResult.regularExpressionCheckingResult(ranges: pointer, count: ranges.count,
                                                                              regularExpression: regex)
            return regex.replacementString(for: result, in: source, offset: 0, template: template)
        }
    }
}

@MainActor @Observable
final class EditorSearch {
    var visible = false
    var showsReplacement = false
    var query = ""
    var replacement = ""
    var options = EditorSearchOptions()
    private(set) var matches: [EditorSearchMatch] = []
    private(set) var currentIndex = 0
    private(set) var searching = false
    private(set) var error: String?
    private(set) var focusRequest = UUID()
    @ObservationIgnored private weak var document: EditorDocument?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var source = ""

    var countLabel: String {
        if searching { return "Buscando…" }
        if query.isEmpty { return "" }
        return matches.isEmpty ? "Sin coincidencias" : "\(currentIndex + 1) de \(matches.count)"
    }

    func show(in document: EditorDocument, replace: Bool) {
        self.document = document
        if !visible, let surface = document.editorStorage as? EditorSurface {
            let range = surface.textView.selectedRange()
            if range.length > 0, let selected = surface.textView.textStorage?.mutableString.substring(with: range),
               !selected.contains(where: \.isNewline) { query = selected }
        }
        visible = true
        showsReplacement = replace
        focusRequest = UUID()
        schedule()
    }

    func hide() {
        visible = false
        work?.cancel()
        generation = UUID()
        matches = []
        searching = false
        if let surface = document?.editorStorage as? EditorSurface {
            surface.textView.needsDisplay = true
            surface.window?.makeFirstResponder(surface.textView)
        }
    }

    func schedule() {
        guard visible, let document else { return }
        work?.cancel()
        let token = UUID()
        generation = token
        matches = []
        error = nil
        searching = !query.isEmpty
        (document.editorStorage as? EditorSurface)?.textView.needsDisplay = true
        let query = query, options = options
        work = Task { [weak self, weak document] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self, let document, !Task.isCancelled else { return }
                let source = document.text
                let cursor = (document.editorStorage as? EditorSurface)?.textView.selectedRange().location ?? 0
                let compute = Task.detached(priority: .userInitiated) {
                    try EditorSearchMatcher.matches(source, query: query, options: options)
                }
                let matches = try await withTaskCancellationHandler { try await compute.value } onCancel: { compute.cancel() }
                guard !Task.isCancelled, self.generation == token else { return }
                self.source = source
                self.matches = matches
                self.currentIndex = matches.firstIndex { $0.range.location >= cursor } ?? 0
                self.searching = false
                self.revealCurrent()
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.searching = false
                self.error = error.localizedDescription
            }
        }
    }

    func navigate(backwards: Bool = false) {
        guard !matches.isEmpty, !searching else { return }
        currentIndex = (currentIndex + (backwards ? matches.count - 1 : 1)) % matches.count
        revealCurrent()
    }

    private func revealCurrent() {
        guard let surface = document?.editorStorage as? EditorSurface else { return }
        if matches.indices.contains(currentIndex) {
            let range = matches[currentIndex].range
            surface.textView.setSelectedRange(range)
            surface.textView.scrollRangeToVisible(range)
        }
        surface.textView.needsDisplay = true
    }

    func replace(all: Bool, allowed: Bool) {
        guard allowed, !searching, let document, let surface = document.editorStorage as? EditorSurface,
              surface.textView.isEditable, !surface.textView.hasMarkedText(), !matches.isEmpty else { return }
        guard source == document.text else { schedule()
        return }
        do {
            let range: NSRange
            let text: String
            if all {
                let updated = NSMutableString(string: source)
                for match in matches.reversed() {
                    let value = try EditorSearchMatcher.replacement(replacement, match: match, source: source,
                                                                    query: query, options: options)
                    updated.replaceCharacters(in: match.range, with: value)
                }
                range = NSRange(location: 0, length: source.utf16.count)
                text = updated as String
            } else {
                let match = matches[currentIndex]
                range = match.range
                text = try EditorSearchMatcher.replacement(replacement, match: match, source: source,
                                                           query: query, options: options)
            }
            let view = surface.textView
            view.breakUndoCoalescing()
            view.insertText(text, replacementRange: range)
            view.breakUndoCoalescing()
            view.undoManager?.setActionName(all ? "Reemplazar todo" : "Reemplazar")
            schedule()
        } catch { self.error = error.localizedDescription }
    }
}
