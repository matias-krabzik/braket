import Foundation

enum AutomationTemplates {
    static var script: Automation {
        Automation(name: "Nueva automatización", steps: [AutomationStep(name: "Mi script", command: "echo 'Hola desde Braket'")])
    }

    static var braket: Automation {
        let labels = [("Comprobar requisitos", "check", true), ("Incrementar versión", "version", false),
                      ("Compilar y firmar", "archive", true), ("Notarizar y verificar", "notarize", true),
                      ("Preparar actualización", "package", true), ("Commit y push · código", "push-code", true),
                      ("Commit y push · sitio", "push-site", true)]
        return Automation(name: "Publicar Braket", parameters: [
            AutomationVariable(name: "INCREMENT", value: "patch"),
            AutomationVariable(name: "IDENTITY", value: "Developer ID Application: MATIAS IVAN KRABZIK (6P3J382F8G)"),
            AutomationVariable(name: "TEAM", value: "6P3J382F8G"),
            AutomationVariable(name: "NOTARY_PROFILE", value: "Braket"),
            AutomationVariable(name: "SITE_REPO", value: ""),
            AutomationVariable(name: "NOTES", value: ""),
            AutomationVariable(name: "BRANCH", value: "main")
        ], steps: labels.map { name, action, retry in
            AutomationStep(name: name, command: "python3 scripts/release_automation.py " + action,
                           retryable: retry, requiresConfirmation: action.hasPrefix("push-"), timeoutSeconds: 7200)
        })
    }
}

extension WorkspaceController {
    var automationRoot: URL {
        if let workspaceURL,
           let stored = UserDefaults.standard.string(forKey: "automationRoot:" + workspaceURL.path) {
            return URL(fileURLWithPath: stored)
        }
        if let workspaceURL, let first = workspace?.projects.first { return first.directory(relativeTo: workspaceURL) }
        return workspaceURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func configureAutomations(root: URL? = nil) {
        guard let workspaceURL, !automations.isRunning else { return }
        if let root { UserDefaults.standard.set(root.path, forKey: "automationRoot:" + workspaceURL.path) }
        automations.configure(workspace: workspaceURL, root: root ?? automationRoot)
    }
}
