import Foundation

extension CodeProject {
    /// Evaluating steps in this same shell preserves nvm, exports and directory changes for the main command.
    func executionScript(directory: URL) -> String {
        var steps = ["cd -- \(Shell.quote(directory.path)) || exit $?"]
        if runConfiguration?.initializeNVM == true {
            steps.append("""
                export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
                if [ -s "$NVM_DIR/nvm.sh" ]; then . "$NVM_DIR/nvm.sh"
                elif [ -s /opt/homebrew/opt/nvm/nvm.sh ]; then . /opt/homebrew/opt/nvm/nvm.sh
                elif [ -s /usr/local/opt/nvm/nvm.sh ]; then . /usr/local/opt/nvm/nvm.sh
                else printf '%s\\n' 'No se encontró nvm. Configurá NVM_DIR o instalá nvm.' >&2; exit 127; fi
                """)
        }
        for (index, script) in (runConfiguration?.preScripts ?? []).enumerated() {
            let heading = "Paso previo \(index + 1): \(script)"
            steps.append("printf '%s\\n' \(Shell.quote(heading))")
            let failure = runConfiguration?.stopOnPreScriptFailure == false ? ":" : "exit $_braket_step_status"
            steps.append("""
                if eval \(Shell.quote(script)); then :; else
                _braket_step_status=$?
                printf '%s\\n' 'Falló el paso previo \(index + 1).' >&2
                \(failure)
                fi
                """)
        }
        steps.append(executionCommand)
        return steps.joined(separator: "\n")
    }
}
