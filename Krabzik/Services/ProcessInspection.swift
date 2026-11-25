import Foundation

/// System inspection runs outside the UI actor. Only listening TCP sockets are collected.
actor ProcessInspection {
    struct Listener: Sendable, Identifiable {
        var id: String { "\(pid):\(port)" }
        let pid: Int32
        let group: Int32
        let command: String
        let port: Int
    }
    func listeners() async -> [Listener] {
        await Task.detached(priority: .utility) {
            let groups = Self.output("/bin/ps", ["-axo", "pid=,pgid="]).split(separator: "\n")
                .reduce(into: [Int32: Int32]()) { result, line in
                    let fields = line.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                    if fields.count == 2 { result[fields[0]] = fields[1] }
                }
            var pid: Int32 = 0
            var command = ""
            var result: [Listener] = []
            for line in Self.output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]).split(separator: "\n") {
                switch line.first {
                case "p": pid = Int32(line.dropFirst()) ?? 0
                case "c": command = String(line.dropFirst())
                case "n":
                    if let text = line.split(separator: ":").last, let port = Int(text), (1...65535).contains(port) {
                        let item = Listener(pid: pid, group: groups[pid] ?? pid, command: command, port: port)
                        if !result.contains(where: { $0.id == item.id }) { result.append(item) }
                    }
                default: break
                }
            }
            return result.sorted { $0.port < $1.port }
        }.value
    }
    private nonisolated static func output(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        // lsof is limited to TCP listeners, and stderr cannot fill a pipe.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
