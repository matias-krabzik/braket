import Foundation

enum PHPServiceProbe {
    static func ready(_ php: PHPServiceConfiguration, directory: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let probe = "exit(@fsockopen('127.0.0.1', \(php.port), $errno, $error, 1) ? 0 : 1);"
            process.arguments = [
                "-c",
                (php.containerPrefix + ["exec", "-T", php.containerService, "php", "-r", probe]).map(Shell.quote).joined(separator: " ")
            ]
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch { return false }
        }.value
    }
}
