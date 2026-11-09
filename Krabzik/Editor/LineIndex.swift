import Foundation

/// UTF-16 offsets match AppKit's selection and edit ranges.
struct LineIndex {
    private(set) var starts = [0]

    init(_ text: String) {
        starts += text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil }
    }

    func line(at offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    mutating func replace(_ range: NSRange, with text: String) {
        let delta = text.utf16.count - range.length
        let end = NSMaxRange(range)
        let before = starts.prefix { $0 <= range.location }
        let inserted = text.utf16.enumerated().compactMap { $0.element == 10 ? range.location + $0.offset + 1 : nil }
        let after = starts.filter { $0 > end }.map { $0 + delta }
        starts = Array(before) + inserted + after
    }
}
