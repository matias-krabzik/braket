import AppKit
import Observation
import SwiftTerm

@MainActor @Observable
final class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    let workspaceURL: URL
    var configuration: TerminalTabConfiguration
    var running = false
    var children: [TerminalInspection.Child] = []
    var currentDirectory: String
    var exitCode: Int32?
    @ObservationIgnored var view: LocalProcessTerminalView?
    @ObservationIgnored var didChange: (() -> Void)?
    init(configuration: TerminalTabConfiguration, workspaceURL: URL) {
        id = configuration.id
        self.configuration = configuration
        self.workspaceURL = workspaceURL
        currentDirectory = configuration.directory
        super.init()
    }
    var hasWork: Bool {
        guard running else { return false }
        if !children.isEmpty { return true }
        guard let process = view?.process, process.childfd >= 0 else { return false }
        let foreground = tcgetpgrp(process.childfd)
        return foreground > 0 && foreground != process.shellPid
    }
    func start(projectVariables: [TerminalEnvironmentVariable]) {
        guard view == nil else { return }
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 320))
        terminal.processDelegate = self
        view = terminal
        applyAppearance()
        let environment = TerminalEnvironment.merge(system: ProcessInfo.processInfo.environment,
                                                    project: projectVariables, terminal: configuration.variables)
        let directory = FileManager.default.fileExists(atPath: currentDirectory) ? currentDirectory
            : workspaceURL.deletingLastPathComponent().path
        terminal.startProcess(executable: "/bin/zsh", args: ["-l"],
                              environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory)
        running = terminal.process.running
    }
    func applyAppearance() {
        let font = Theme.nativeCodeFont(scale: Theme.settings.codeFontScale)
        if view?.font != font { view?.font = font }
        view?.nativeBackgroundColor = EditorPalette.background
        view?.nativeForegroundColor = Theme.settings.theme == .light ? .black : .white
    }
    func stop() {
        guard let terminal = view else { return }
        let shell = terminal.process.shellPid
        let groups = Set(children.map(\.group)).union(shell > 0 ? [shell] : [])
        for group in groups where group > 0 && group != getpgrp() { kill(-group, SIGHUP) }
        terminal.terminate()
        // Retain the PTY until the child has been reaped. Force surviving groups only while they still belong to this shell.
        let targets = children.map { ($0.pid, $0.group) } + (shell > 0 ? [(shell, shell)] : [])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for (pid, group) in targets where group > 0 && group != getpgrp() && getpgid(pid) == group {
                kill(-group, SIGKILL)
            }
            _ = terminal
        }
        running = false
        children = []
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        Task { @MainActor [weak self] in
            self?.currentDirectory = url.path
            self?.didChange?()
        }
    }
    nonisolated func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.running = false
            self?.exitCode = exitCode
            self?.didChange?()
        }
    }
}
