import Foundation

actor TerminalInspection {
    struct Child: Sendable {
        let pid: Int32
        let parent: Int32
        let group: Int32
        let command: String
    }
    struct Snapshot: Sendable {
        var children: [Child] = []
        var directory: String?
    }
    static func descendants(of pid: Int32, in processes: [Child]) -> [Child] {
        var parents: Set<Int32> = [pid]
        var children: [Child] = []
        while true {
            let next = processes.filter { parents.contains($0.parent) && !parents.contains($0.pid) }
            if next.isEmpty { break }
            children += next
            parents.formUnion(next.map(\.pid))
        }
        return children
    }
    func snapshot(pid: Int32) async -> Snapshot {
        guard pid > 0 else { return Snapshot() }
        return await Task.detached(priority: .utility) {
            let text = Self.output("/bin/ps", ["-axo", "pid=,ppid=,pgid=,comm="])
            let processes = text.split(separator: "\n").compactMap { line -> Child? in
                let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
                guard parts.count == 4, let child = Int32(parts[0]), let parent = Int32(parts[1]),
                      let group = Int32(parts[2]) else { return nil }
                return Child(pid: child, parent: parent, group: group, command: String(parts[3]))
            }
            let cwd = Self.output("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
                .split(separator: "\n").first { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
            return Snapshot(children: Self.descendants(of: pid, in: processes), directory: cwd)
        }.value
    }
    private nonisolated static func output(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
