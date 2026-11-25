import Foundation

struct PHPServiceConfiguration: Codable, Equatable {
    enum Kind: String, Codable,
        CaseIterable { case script = "PHP Script", server = "PHP Built-in Web Server", composer = "Composer Script" }
    enum Environment: String, Codable, CaseIterable { case local = "Local", docker = "Docker Compose", sail = "Laravel Sail" }
    var kind = Kind.script
    var environment = Environment.local
    var php = "php"
    var script = "artisan"
    var artisanCommand = "serve"
    var arguments: [String] = []
    var interpreterOptions: [String] = []
    var host = "127.0.0.1"
    var port = 8000
    var publishedPort = 8000
    var documentRoot = "public"
    var router = ""
    var composer = "composer"
    var composerFile = "composer.json"
    var composerScript = "dev"
    var composeFile = "compose.yaml"
    var containerService = "php"
    var containerDirectory = "/app"
    var sail = "vendor/bin/sail"
    var useTemporaryContainer = false
    var startContainer = false

    var servesHTTP: Bool {
        kind == .server || (kind == .script && URL(fileURLWithPath: script).lastPathComponent == "artisan" && artisanCommand == "serve") }
    var effectivePort: Int? { servesHTTP ? (environment == .local ? port : publishedPort) : nil }
    var tokens: [String] {
        let executable = environment == .local ? php : "php"
        switch kind {
        case .script:
            var result = [executable] + interpreterOptions + [script]
            if URL(fileURLWithPath: script).lastPathComponent == "artisan" {
                result += [artisanCommand]
                if servesHTTP { result += ["--host=\(host)", "--port=\(port)"] }
            }
            return result + arguments
        case .server:
            return [executable] + interpreterOptions + ["-S", "\(host):\(port)", "-t", documentRoot] + (router.isEmpty ? [] : [router]) +
                arguments
        case .composer:
            let runner = environment == .local ? [php, composer] : [composer]
            return ["env", "COMPOSER=" + composerFile] + runner + ["run-script", "--timeout=0", composerScript, "--"] + arguments
        }
    }
    var containerPrefix: [String] {
        environment == .sail ? [sail] : ["docker", "compose", "-f", composeFile]
    }
    func command(id: UUID, environmentKeys: [String] = []) -> String {
        let payload = tokens.map(Shell.quote).joined(separator: " ")
        if environment == .local {
            if kind == .composer, !composer.contains("/"), !composer.hasSuffix(".phar") {
                let suffix = (["run-script", "--timeout=0", composerScript, "--"] + arguments).map(Shell.quote).joined(separator: " ")
                return "composer_binary=$(command -v \(Shell.quote(composer))) || exit 127; " +
                    "env \(Shell.quote("COMPOSER=" + composerFile)) \(Shell.quote(php)) \"$composer_binary\" \(suffix)"
            }
            return payload
        }
        let prefix = containerPrefix.map(Shell.quote).joined(separator: " ")
        let env = environmentKeys.sorted().flatMap { ["-e", $0] }.map(Shell.quote).joined(separator: " ")
        if useTemporaryContainer && environment == .docker {
            let name = "braket-" + id.uuidString.lowercased()
            return "trap 'docker stop \(name) >/dev/null 2>&1 || true' EXIT; " +
                "trap 'exit 143' TERM; trap 'exit 130' INT; \(prefix) run --rm --name \(name) --service-ports " +
                "\(env) -w \(Shell.quote(containerDirectory)) \(Shell.quote(containerService)) \(payload)"
        }
        let startup = startContainer ? "\(prefix) up -d \(Shell.quote(containerService)) || exit $?; " : ""
        let marker = "/tmp/braket-\(id.uuidString.lowercased()).pid"
        let remote = "command -v setsid >/dev/null || { echo 'El contenedor necesita setsid.' >&2; exit 127; }; " +
            "setsid sh -c \(Shell.quote("exec " + payload)) & child=$!; echo $child > \(marker); " +
            "wait $child; result=$?; rm -f \(marker); exit $result"
        let cleanup = "if [ -f \(marker) ]; then child=$(cat \(marker)); kill -TERM -- -$child 2>/dev/null || true; rm -f \(marker); fi"
        let stop = "\(prefix) exec -T \(Shell.quote(containerService)) sh -c \(Shell.quote(cleanup)) >/dev/null 2>&1 || true"
        return startup + "trap \(Shell.quote(stop)) EXIT; trap 'exit 143' TERM; trap 'exit 130' INT; " +
            "\(prefix) exec -T \(env) -w \(Shell.quote(containerDirectory)) " +
            "\(Shell.quote(containerService)) sh -c \(Shell.quote(remote))"
    }
    var preview: String {
        let payload = tokens.map(Shell.quote).joined(separator: " ")
        guard environment != .local else { return payload }
        return (containerPrefix + ["exec", "-T", "-w", containerDirectory, containerService]).map(Shell.quote)
            .joined(separator: " ") + " " + payload
    }
    func validate() throws {
        let text = [
            php,
            script,
            artisanCommand,
            host,
            documentRoot,
            router,
            composer,
            composerFile,
            composerScript,
            composeFile,
            containerService,
            containerDirectory,
            sail
        ] + arguments + interpreterOptions
        guard arguments.count <= 256, interpreterOptions.count <= 256,
              text.allSatisfy({ $0.count <= 4096 && !$0.contains("\0") && !$0.contains("\n") }),
              !php.isEmpty, !script.isEmpty, !composer.isEmpty, !composerScript.isEmpty,
              !containerService.isEmpty, !containerDirectory.isEmpty,
              (1...65535).contains(port),
              (1...65535).contains(publishedPort) else { throw WorkspaceError.invalidText("la configuración PHP") }
    }
}
