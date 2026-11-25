import Foundation
@testable import Krabzik
import XCTest

/// Contrato de `RunConfiguration`: qué configuración de ejecución se acepta al leer un
/// `.kzk`, qué comando se le pasa a zsh, qué cadena custodia la aprobación y en qué
/// carpeta corre el proceso.
///
/// Las pruebas van por los bordes, que es donde está el riesgo: el tope exacto de cada
/// cantidad, el texto hostil de un archivo que se puede recibir por mail, y el orden del
/// diccionario de variables —si la cadena de aprobación dependiera de él, un comando ya
/// aprobado volvería a preguntar, o dejaría de preguntar cuando debería—.
@MainActor
final class RunConfigurationTests: XCTestCase {
    private let generic = WorkspaceError.invalidText("la configuración de ejecución")
    private let tooMany = WorkspaceError.tooManyEntries("argumentos o variables de entorno (256 como máximo)")

    private func configuration(_ configure: (inout RunConfiguration) -> Void) -> RunConfiguration {
        var value = RunConfiguration()
        configure(&value)
        return value
    }

    private func project(command: String = "npm run dev", path: String = "app",
                         _ configure: (inout RunConfiguration) -> Void = { _ in }) -> CodeProject {
        CodeProject(name: "Worker", path: path, kind: .files, command: command,
                    runConfiguration: configuration(configure))
    }

    /// `nil` cuando la configuración es válida; el `WorkspaceError` concreto cuando no.
    private func failure(_ configure: (inout RunConfiguration) -> Void) -> WorkspaceError? {
        do {
            try configuration(configure).validate()
            return nil
        } catch {
            return error as? WorkspaceError
        }
    }

    // MARK: - Topes de cantidad y longitud

    func testCountLimitsAcceptTheBoundaryAndRejectOneMore() {
        let arguments = Array(repeating: "--flag", count: 256)
        XCTAssertNil(failure({ $0.arguments = arguments }))
        XCTAssertEqual(failure({ $0.arguments = arguments + ["--flag"] }), tooMany)

        let variables = Dictionary(uniqueKeysWithValues: (1...256).map { ("V\($0)", "x") })
        XCTAssertNil(failure({ $0.environment = variables }))
        XCTAssertEqual(failure({ $0.environment = variables.merging(["V257": "x"]) { current, _ in current } }), tooMany)
    }

    func testTextIsRejectedOneCharacterAboveTheLimit() {
        let limit = String(repeating: "a", count: 16_384)
        let excess = limit + "a"
        XCTAssertNil(failure({ $0.name = limit }))
        XCTAssertNil(failure({ $0.workingDirectory = limit }))
        XCTAssertNil(failure({ $0.arguments = [limit] }))
        XCTAssertNil(failure({ $0.environment = ["VAR": limit] }))
        XCTAssertEqual(failure({ $0.name = excess }), generic)
        XCTAssertEqual(failure({ $0.workingDirectory = excess }), generic)
        XCTAssertEqual(failure({ $0.arguments = [excess] }), generic)
        XCTAssertEqual(failure({ $0.environment = ["VAR": excess] }), generic)

        // La URL se mide antes de comprobar que sea navegable: una dirección enorme falla
        // por longitud, no por formato, y el mensaje tiene que decir eso.
        let address = "http://e.com/" + String(repeating: "a", count: 16_384 - 13)
        XCTAssertEqual(address.count, 16_384)
        XCTAssertNil(failure({ $0.launchURL = address }))
        XCTAssertEqual(failure({ $0.launchURL = address + "a" }), generic)
    }

    func testNullBytesAreRejectedInEveryTextField() {
        XCTAssertEqual(failure({ $0.name = "ser\0vidor" }), generic)
        XCTAssertEqual(failure({ $0.workingDirectory = "serv\0er" }), generic)
        XCTAssertEqual(failure({ $0.arguments = ["--port", "3000\0"] }), generic)
        XCTAssertEqual(failure({ $0.environment = ["VAR": "val\0or"] }), generic)
        XCTAssertEqual(failure({ $0.launchURL = "http://localhost:3000\0" }), generic)
    }

    func testEnvironmentNamesFollowTheShellRules() {
        for name in ["PATH", "_", "_x9", "a", "MY_VAR_2", "V0"] {
            XCTAssertNil(failure({ $0.environment = [name: "x"] }), name)
        }
        for name in ["", "1VAR", "VA-R", "VA R", "ÁRBOL", "VAR\n", " VAR", "VAR=", "va.r", "VAR\0"] {
            XCTAssertEqual(failure({ $0.environment = [name: "x"] }), generic, name)
        }
    }

    func testExpectedPortStaysInsideTheTCPRange() {
        XCTAssertNil(failure({ $0.expectedPort = nil }))
        for port in [1, 80, 3000, 65_535] {
            XCTAssertNil(failure({ $0.expectedPort = port }), "\(port)")
        }
        for port in [0, -1, 65_536, Int.max, Int.min] {
            XCTAssertEqual(failure({ $0.expectedPort = port }), generic, "\(port)")
        }
    }

    /// El editor decide con `browserURL` si el botón «Guardar» está habilitado y la
    /// lectura decide con `validate` si el archivo se abre. Tienen que coincidir: si no,
    /// la app guarda un proyecto que después no puede volver a abrir.
    func testLaunchURLAcceptsOnlyBrowsableAddressesAndAgreesWithTheEditor() {
        let accepted = ["http://localhost:3000", "https://example.com", "https://example.com/a?b=1#c",
                        "HTTPS://Example.com", "http://127.0.0.1:8080/panel"]
        let rejected = ["ftp://example.com", "file:///etc/passwd", "javascript:alert(1)", "localhost:3000",
                        "http://", "example.com", "/panel", "mailto:alguien@example.com", "http://?a=1"]
        XCTAssertNil(failure({ $0.launchURL = "" }), "vacía es válida: no hay URL que abrir")
        XCTAssertNil(RunConfigurationEditor.browserURL(""))
        for text in accepted {
            XCTAssertNil(failure({ $0.launchURL = text }), text)
            XCTAssertNotNil(RunConfigurationEditor.browserURL(text), text)
        }
        for text in rejected {
            XCTAssertEqual(failure({ $0.launchURL = text }), .invalidText("la URL de ejecución"), text)
            XCTAssertNil(RunConfigurationEditor.browserURL(text), text)
        }
    }

    // MARK: - Ida y vuelta por el archivo

    func testConfigurationSurvivesTheRoundTripThroughTheFile() throws {
        let url = try temporaryWorkspaceURL()
        let project = project(command: "npm run dev", path: ".", { config in
            config.name = "Servidor"
            config.arguments = ["--port", "3000", "con espacios"]
            config.environment = ["NODE_ENV": "development", "API_KEY": ""]
            config.workingDirectory = "server"
            config.expectedPort = 3000
            config.launchURL = "http://localhost:3000"
            config.startsAutomatically = true
            config.restartPolicy = .onFailure
        })
        try Workspace(name: "Run", projects: [project]).write(to: url)
        XCTAssertEqual(try Workspace.read(from: url).projects.first?.runConfiguration, project.runConfiguration)

        let plain = CodeProject(name: "Plain", path: ".", kind: .files, command: "make build")
        try Workspace(name: "Run", projects: [plain]).write(to: url)
        XCTAssertNil(try Workspace.read(from: url).projects.first?.runConfiguration)
    }

    func testTheReaderRejectsAFileWithAnImpossibleConfiguration() throws {
        let url = try temporaryWorkspaceURL()
        let project = project(command: "npm run dev", path: ".", { $0.expectedPort = 3000 })
        try Workspace(name: "Run", projects: [project]).write(to: url)
        let original = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))

        let hostile = original.replacingOccurrences(of: "\"expectedPort\" : 3000", with: "\"expectedPort\" : 70000")
        XCTAssertNotEqual(hostile, original, "cambió el formato del JSON: hay que actualizar la prueba")
        try Data(hostile.utf8).write(to: url)
        XCTAssertThrowsError(try Workspace.read(from: url)) { error in
            XCTAssertEqual(error as? WorkspaceError, self.generic)
        }

        // Una política de reinicio que la app no conoce no se degrada a «nunca» en
        // silencio: el archivo se rechaza y el usuario ve el error.
        let unknown = original.replacingOccurrences(of: "\"restartPolicy\" : \"never\"",
                                                    with: "\"restartPolicy\" : \"siempre\"")
        XCTAssertNotEqual(unknown, original, "cambió el formato del JSON: hay que actualizar la prueba")
        try Data(unknown.utf8).write(to: url)
        XCTAssertThrowsError(try Workspace.read(from: url)) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
    }

    // MARK: - El comando que recibe el shell

    func testExecutionCommandQuotesEveryArgument() {
        XCTAssertEqual(project(command: "npm run dev").executionCommand, "npm run dev")
        XCTAssertEqual(project(command: "node", { $0.arguments = ["server.js", "--port", "3000"] }).executionCommand,
                       "node 'server.js' '--port' '3000'")
        // Un argumento no puede inyectar shell: va entero dentro de comillas simples, y
        // la comilla simple que traiga se escapa.
        let hostile = project(command: "echo", { $0.arguments = ["mi carpeta", "it's", "", "$HOME", "; rm -rf /"] })
        XCTAssertEqual(hostile.executionCommand, "echo 'mi carpeta' 'it'\\''s' '' '$HOME' '; rm -rf /'")

        let plain = CodeProject(name: "Plain", path: ".", kind: .files, command: "make build")
        XCTAssertEqual(plain.executionCommand, "make build")
        XCTAssertEqual(plain.commandApproval, "make build")
    }

    func testApprovalChangesWithEverythingThatDecidesHowTheProcessRuns() {
        XCTAssertEqual(project(command: "npm run dev").commandApproval, "npm run dev")
        // Nombre, puerto y URL no cambian lo que se ejecuta: no vuelven a preguntar.
        let cosmetic = project(command: "npm run dev", { config in
            config.name = "Servidor"
            config.expectedPort = 3000
            config.launchURL = "http://localhost:3000"
        })
        XCTAssertEqual(cosmetic.commandApproval, "npm run dev")
        // Arrancar al abrir el proyecto y reiniciar sin intervención sí lo cambian: son
        // dos formas de ejecutar el comando sin que nadie toque «Ejecutar».
        XCTAssertEqual(project(command: "npm run dev", { $0.startsAutomatically = true }).commandApproval,
                       "npm run dev\n\nInicio automático: true")
        XCTAssertEqual(project(command: "npm run dev", { $0.restartPolicy = .onFailure }).commandApproval,
                       "npm run dev\n\nReinicio: onFailure")

        XCTAssertEqual(project(command: "npm run dev", { $0.arguments = ["--port", "3000"] }).commandApproval,
                       "npm run dev '--port' '3000'\n")
        XCTAssertEqual(project(command: "npm run dev", { $0.workingDirectory = "server" }).commandApproval,
                       "npm run dev\nserver")
        XCTAssertEqual(project(command: "npm run dev", { $0.environment = ["B": "2", "A": "1"] }).commandApproval,
                       "npm run dev\n\nA=1\nB=2")
        XCTAssertNotEqual(project(command: "npm run dev", { $0.environment = ["A": "9"] }).commandApproval,
                          project(command: "npm run dev", { $0.environment = ["A": "1"] }).commandApproval)
        XCTAssertNotEqual(project(command: "npm run dev", { $0.environment = ["A": "1"] }).commandApproval,
                          project(command: "npm run dev", { $0.environment = ["B": "1"] }).commandApproval)
    }

    func testExecutionNameFallsBackToTheProjectName() {
        XCTAssertEqual(project(command: "serve", { $0.name = "Servidor" }).executionName, "Servidor")
        XCTAssertEqual(project(command: "serve", { $0.name = "" }).executionName, "Worker")
        XCTAssertEqual(CodeProject(name: "Plain", path: ".", kind: .files, command: "serve").executionName, "Plain")
    }

    func testApprovalDoesNotDependOnTheDictionaryOrder() {
        var ascending: [String: String] = [:]
        var descending: [String: String] = [:]
        for index in 1...64 {
            ascending["V\(index)"] = "\(index)"
        }
        for index in (1...64).reversed() {
            descending["V\(index)"] = "\(index)"
        }
        XCTAssertEqual(project(command: "serve", { $0.environment = ascending }).commandApproval,
                       project(command: "serve", { $0.environment = descending }).commandApproval)
    }

    // MARK: - Carpeta de trabajo

    func testExecutionDirectoryResolvesFromTheSubprojectFolder() {
        let workspace = URL(fileURLWithPath: "/Users/x/Proyecto/Proyecto.kzk")
        func directory(_ path: String) -> String {
            project(path: "app", { $0.workingDirectory = path }).executionDirectory(relativeTo: workspace).path
        }
        XCTAssertEqual(project(path: "app").executionDirectory(relativeTo: workspace).path, "/Users/x/Proyecto/app")
        XCTAssertEqual(directory(""), "/Users/x/Proyecto/app")
        XCTAssertEqual(directory("server"), "/Users/x/Proyecto/app/server")
        XCTAssertEqual(directory("server/"), "/Users/x/Proyecto/app/server")
        XCTAssertEqual(directory("./server"), "/Users/x/Proyecto/app/server")
        XCTAssertEqual(directory("../tools"), "/Users/x/Proyecto/tools")
        XCTAssertEqual(directory("/opt/build/../serve"), "/opt/serve")
        // La tilde no la expande nadie: zsh recibe la ruta entre comillas.
        XCTAssertEqual(directory("~/code"), "/Users/x/Proyecto/app/~/code")

        let absolute = project(path: "/opt/app", { $0.workingDirectory = "" })
        XCTAssertEqual(absolute.executionDirectory(relativeTo: workspace).path, "/opt/app")
    }

    // MARK: - Etiquetas

    func testPolicyAndStatusLabels() {
        XCTAssertEqual(RunConfiguration.RestartPolicy.allCases.map(\.rawValue), ["never", "onFailure"])
        XCTAssertEqual(RunConfiguration.RestartPolicy.never.label, "Nunca")
        XCTAssertEqual(RunConfiguration.RestartPolicy.onFailure.label, "Si falla (máximo 3 intentos)")
        XCTAssertEqual(RunStatus.idle.label, "Detenido")
        XCTAssertEqual(RunStatus.running.label, "En ejecución")
        XCTAssertEqual(RunStatus.stopping.label, "Deteniendo")
        XCTAssertEqual(RunStatus.exited(0).label, "Finalizado")
        XCTAssertEqual(RunStatus.exited(143).label, "Salida 143")
        XCTAssertEqual(RunStatus.failed("sin carpeta").label, "Error")
        XCTAssertTrue(RunStatus.running.active)
        XCTAssertTrue(RunStatus.stopping.active)
        XCTAssertFalse(RunStatus.idle.active)
        XCTAssertFalse(RunStatus.exited(0).active)
        XCTAssertFalse(RunStatus.failed("sin carpeta").active)
    }

    // MARK: - Apoyo

    private func temporaryWorkspaceURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent("Run.kzk")
    }
}
