@testable import Krabzik
import XCTest

@MainActor final class WorkflowTests: XCTestCase {
    /// Un almacén aislado: las pruebas no tocan las aprobaciones reales del usuario.
    private func approvingStore() throws -> TrustStore {
        try TrustStore(defaults: XCTUnwrap(UserDefaults(suiteName: "WorkflowTests-\(UUID().uuidString)")))
    }

    func testConnectingPortsUpdatesBranchesAndRejectsCycles() throws {
        var flow = Workflow.first()
        let script = try XCTUnwrap(flow.nodes.first(where: { $0.kind == .script }))
        let decision = try XCTUnwrap(flow.nodes.first(where: { $0.kind == .decision }))
        let ends = flow.nodes.filter { $0.kind == .end }
        XCTAssertTrue(flow.connect(from: decision.id, isNo: true, to: ends[0].id))
        XCTAssertEqual(flow.nodes.first(where: { $0.id == decision.id })?.no, ends[0].id)
        XCTAssertFalse(flow.connect(from: decision.id, isNo: false, to: script.id))
        XCTAssertFalse(flow.connect(from: script.id, isNo: true, to: ends[1].id))
        XCTAssertFalse(flow.connect(from: ends[0].id, isNo: false, to: script.id))
        XCTAssertFalse(flow.connect(from: script.id, isNo: false, to: flow.nodes[0].id))
    }

    func testThreeTriggersCanShareAFlowWithoutIncomingConnections() throws {
        var flow = Workflow.first()
        let event = WorkflowNode(kind: .event, title: "Evento", x: 70, y: 320)
        let schedule = WorkflowNode(kind: .schedule, title: "Horario", x: 70, y: 420)
        flow.nodes.append(contentsOf: [event, schedule])
        let file = WorkflowFile(workflows: [flow])
        XCTAssertNoThrow(try file.validate())
        let restored = try JSONDecoder().decode(WorkflowFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(restored.workflows[0].nodes.filter { $0.kind.isTrigger }.count, 3)

        flow.nodes[0].next = event.id
        XCTAssertThrowsError(try WorkflowFile(workflows: [flow]).validate())
    }

    func testEventAndScheduleTriggersReturnOKWhenTested() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let finalNode = try XCTUnwrap(model.selected?.nodes.first(where: { $0.kind == .end }))
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        for kind in [WorkflowKind.event, .schedule] {
            let trigger = WorkflowNode(kind: kind, title: kind.title, x: 70, y: 300, next: finalNode.id)
            model.file.workflows[0].nodes.append(trigger)
            // El script del flujo no cuelga de estos disparadores: no hay nada que aprobar.
            model.run(workspace: workspace, root: root, runner: runner, trusted: true,
                      approvals: try approvingStore(), trigger: kind)
            let deadline = Date().addingTimeInterval(5)
            while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertFalse(model.isRunning)
            XCTAssertEqual(model.visited[trigger.id], .exited(0))
            XCTAssertEqual(model.results[trigger.id]?.summary, "OK")
            XCTAssertEqual(model.results[finalNode.id]?.summary, "Finalizado")
            XCTAssertTrue(model.traversedTransitions.contains(WorkflowTransition(from: trigger.id, to: finalNode.id, isNo: false)))
        }
    }

    func testWorkflowFileRejectsExternalOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        model.save()
        let path = try XCTUnwrap(model.selected.flatMap { model.storageURL(for: $0) })
        XCTAssertTrue(path.path.hasSuffix(".flow.json"))
        let external = Data("external change".utf8)
        try external.write(to: path)
        model.save()
        XCTAssertFalse(model.error.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), external)
    }

    func testFirstFlowBranchesOnScriptFailureAndPersistsEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        XCTAssertEqual(model.selected?.nodes.count, 5, model.error)
        let script = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.kind == .script })
        model.file.workflows[0].nodes[script].command = "exit 3"
        model.save()
        XCTAssertTrue(model.error.isEmpty)
        let reloaded = WorkflowController()
        reloaded.configure(workspace, root: root)
        let reloadedFlow = try XCTUnwrap(reloaded.file.workflows.first, reloaded.error)
        XCTAssertEqual(reloadedFlow.nodes[script].command, "exit 3")
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        reloaded.confirmCommand = { _ in .once }
        reloaded.run(workspace: workspace, root: root, runner: runner, trusted: true, approvals: try approvingStore())
        let deadline = Date().addingTimeInterval(5)
        while reloaded.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(reloaded.isRunning)
        XCTAssertTrue(reloaded.log.contains("No"))
        XCTAssertTrue(reloaded.log.contains("Fin: Sin commits nuevos"))
        XCTAssertFalse(reloaded.log.contains("Fin: Commits pendientes"))
        let decision = try XCTUnwrap(reloadedFlow.nodes.first { $0.kind == .decision })
        let no = try XCTUnwrap(decision.no)
        let yes = try XCTUnwrap(decision.next)
        XCTAssertEqual(reloaded.results[decision.id]?.summary, "No")
        XCTAssertTrue(reloaded.traversedTransitions.contains(WorkflowTransition(from: decision.id, to: no, isNo: true)))
        XCTAssertFalse(reloaded.traversedTransitions.contains(WorkflowTransition(from: decision.id, to: yes, isNo: false)))
    }

    func testScriptSettingsPersistAndApplyToProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subfolder = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let index = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.kind == .script })
        model.file.workflows[0].nodes[index].command = "printf '%s:%s:%s' \"$BRAKET_TEST\" \"$PWD\" \"$BRAKET_INPUT\""
        model.file.workflows[0].nodes[index].settings = WorkflowScriptSettings(workingDirectory: "scripts", timeoutSeconds: 5,
                                                                               environment: [
                                                                                   WorkflowEnvironmentVariable(name: "BRAKET_TEST",
                                                                                                               value: "configured")
                                                                               ])
        model.save()
        XCTAssertTrue(model.error.isEmpty, model.error)

        let restored = WorkflowController()
        restored.configure(workspace, root: root)
        XCTAssertEqual(restored.selected?.nodes[index].settings.timeoutSeconds, 5)
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        restored.confirmCommand = { _ in .once }
        restored.run(workspace: workspace, root: root, runner: runner, trusted: true, approvals: try approvingStore())
        let deadline = Date().addingTimeInterval(8)
        while restored.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(restored.isRunning)
        XCTAssertTrue(restored.log.contains("configured:\(subfolder.path):"), restored.log)
        let scriptID = try XCTUnwrap(restored.selected?.nodes[index].id)
        XCTAssertEqual(WorkflowJSON.decode(restored.inputJSON[scriptID] ?? "")["trigger"] as? String, "start")
        XCTAssertEqual(WorkflowJSON.decode(restored.outputJSON[scriptID] ?? "")["exitCode"] as? Int, 0)
    }

    func testPublicationContextSurvivesLaterScriptAndDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let flow = try XCTUnwrap(model.selected)
        let first = try XCTUnwrap(flow.nodes.first { $0.kind == .script })
        let decision = try XCTUnwrap(flow.nodes.first { $0.kind == .decision })
        let command = "python3 -c 'import json,os; "
            + "print(json.loads(os.environ[\"BRAKET_INPUT\"])[\"context\"][\"baseCommit\"])'"
        let second = WorkflowNode(kind: .script, title: "Read context", command: command,
                                  x: 400, y: 100, next: decision.id)
        let index = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.id == first.id })
        model.file.workflows[0].nodes[index].command = "printf '{\"baseCommit\":\"abc123\"}'"
        model.file.workflows[0].nodes[index].settings.capturesContext = true
        model.file.workflows[0].nodes[index].next = second.id
        model.file.workflows[0].nodes.append(second)
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        model.confirmCommand = { _ in .once }
        model.run(workspace: workspace, root: root, runner: runner, trusted: true,
                  approvals: try approvingStore())
        let deadline = Date().addingTimeInterval(8)
        while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.isRunning)
        let input = WorkflowJSON.decode(model.inputJSON[second.id] ?? "")
        let runID = (input["run"] as? [String: String])?["id"]
        XCTAssertNotNil(UUID(uuidString: runID ?? ""))
        XCTAssertEqual((input["context"] as? [String: Any])?["baseCommit"] as? String, "abc123")
        XCTAssertEqual(input["stdout"] as? String, "")
        let output = WorkflowJSON.decode(model.outputJSON[second.id] ?? "")
        XCTAssertEqual(output["stdout"] as? String, "abc123")
        XCTAssertEqual((output["context"] as? [String: Any])?["baseCommit"] as? String, "abc123")
        XCTAssertEqual((output["run"] as? [String: String])?["id"], runID)
        let step = (output["steps"] as? [String: [String: Any]])?[first.id.uuidString]
        XCTAssertEqual(step?["successful"] as? Bool, true)
        XCTAssertEqual(model.results[decision.id]?.summary, "Sí")
        model.run(workspace: workspace, root: root, runner: runner, trusted: true,
                  approvals: try approvingStore())
        let secondDeadline = Date().addingTimeInterval(8)
        while model.isRunning, Date() < secondDeadline { try await Task.sleep(for: .milliseconds(30)) }
        let nextRunID = (WorkflowJSON.decode(model.inputJSON[second.id] ?? "")["run"] as? [String: String])?["id"]
        XCTAssertNotEqual(nextRunID, runID)
    }

    func testScriptTimeoutMarksStepAsFailed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let index = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.kind == .script })
        model.file.workflows[0].nodes[index].command = "sleep 5"
        model.file.workflows[0].nodes[index].settings.timeoutSeconds = 1
        let id = model.file.workflows[0].nodes[index].id
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        model.confirmCommand = { _ in .once }
        model.run(workspace: workspace, root: root, runner: runner, trusted: true, approvals: try approvingStore())
        let deadline = Date().addingTimeInterval(8)
        while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.visited[id], .failed("Tiempo límite de 1 s agotado"))
        XCTAssertTrue(model.log.contains("Fin: Sin commits nuevos"), model.log)
    }

    func testIfComparesTextAndNumbersWithAllOperators() throws {
        var condition = WorkflowCondition(mode: .compare, valueType: .number,
                                          operation: .equal,
                                          left: WorkflowOperand(source: .previousOutput),
                                          right: WorkflowOperand(value: "3"))
        let expected: [(WorkflowComparisonOperator, Bool)] = [
            (.equal, false), (.notEqual, true), (.less, true),
            (.lessOrEqual, true), (.greater, false), (.greaterOrEqual, false)
        ]
        for (operation, result) in expected {
            condition.operation = operation
            XCTAssertEqual(try condition.evaluate(previousSucceeded: false, output: "2,5", exitCode: nil), result)
        }
        condition.valueType = .text
        condition.right.value = "abc"
        condition.operation = .less
        XCTAssertTrue(try condition.evaluate(previousSucceeded: false, output: "Abc", exitCode: nil))
        condition.operation = .equal
        XCTAssertFalse(try condition.evaluate(previousSucceeded: false, output: "Abc", exitCode: nil))
        condition.valueType = .number
        XCTAssertThrowsError(try condition.evaluate(previousSucceeded: false, output: "Abc", exitCode: nil))
    }

    func testIfCanComparePreviousScriptOutputAndExitCode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let script = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.kind == .script })
        let decision = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.kind == .decision })
        model.file.workflows[0].nodes[script].command = "printf '42'"
        model.file.workflows[0].nodes[decision].condition = WorkflowCondition(mode: .compare, valueType: .number, operation: .greater,
                                                                              left: WorkflowOperand(source: .previousOutput),
                                                                              right: WorkflowOperand(value: "40"))
        let originalEnd = try XCTUnwrap(model.file.workflows[0].nodes[decision].next)
        let capture = WorkflowNode(kind: .script, title: "Recibir salida",
                                   command: "printf '%s' \"$BRAKET_INPUT\" > recibido.txt",
                                   x: 650, y: 120, next: originalEnd)
        model.file.workflows[0].nodes[decision].next = capture.id
        model.file.workflows[0].nodes.append(capture)
        model.save()
        XCTAssertTrue(model.error.isEmpty, model.error)
        let restored = WorkflowController()
        restored.configure(workspace, root: root)
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        restored.confirmCommand = { _ in .once }
        restored.run(workspace: workspace, root: root, runner: runner, trusted: true, approvals: try approvingStore())
        let deadline = Date().addingTimeInterval(5)
        while restored.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(restored.isRunning)
        XCTAssertTrue(restored.log.contains("Fin: Commits pendientes"), restored.log)
        XCTAssertFalse(restored.log.contains("Fin: Sin commits nuevos"), restored.log)
        let received = try String(contentsOf: root.appendingPathComponent("recibido.txt"), encoding: .utf8)
        XCTAssertEqual(WorkflowJSON.decode(received)["stdout"] as? String, "42")
        let selectedDecision = try XCTUnwrap(restored.selected?.nodes.first { $0.kind == .decision })
        XCTAssertEqual(restored.results[selectedDecision.id]?.summary, "Sí")
        XCTAssertTrue(restored.traversedTransitions.contains(WorkflowTransition(from: selectedDecision.id,
                                                                                to: try XCTUnwrap(selectedDecision.next), isNo: false)))

        var exitCondition = WorkflowCondition(mode: .compare, valueType: .number,
                                              operation: .equal,
                                              left: WorkflowOperand(source: .previousExitCode),
                                              right: WorkflowOperand(value: "0"))
        XCTAssertTrue(try exitCondition.evaluate(previousSucceeded: false, output: "", exitCode: 0))
        exitCondition.right.value = "1"
        XCTAssertFalse(try exitCondition.evaluate(previousSucceeded: true, output: "", exitCode: 0))
    }

    func testOlderIfUsesPreviousExitCodeComparedWithZero() throws {
        let flow = Workflow.first()
        let encoded = try JSONEncoder().encode(flow)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        for index in nodes.indices { nodes[index].removeValue(forKey: "condition") }
        object["nodes"] = nodes
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(Workflow.self, from: legacy)
        let decision = try XCTUnwrap(restored.nodes.first { $0.kind == .decision })
        XCTAssertEqual(decision.condition.left.source, .previousExitCode)
        XCTAssertEqual(decision.condition.right.value, "0")
        XCTAssertTrue(try decision.condition.evaluate(previousSucceeded: false, output: "", exitCode: 0))
        XCTAssertFalse(try decision.condition.evaluate(previousSucceeded: true, output: "", exitCode: 2))
    }

    func testIfReadsAFieldFromIncomingJSON() throws {
        let condition = WorkflowCondition(mode: .compare, valueType: .text,
                                          operation: .notEqual,
                                          left: WorkflowOperand(source: .jsonField, value: "data.commits"),
                                          right: WorkflowOperand(value: ""))
        XCTAssertTrue(try condition.evaluate(previousSucceeded: true, output: "", exitCode: nil,
                                             json: "{\"data\":{\"commits\":\"abc\"}}"))
        XCTAssertThrowsError(try condition.evaluate(previousSucceeded: true, output: "", exitCode: nil,
                                                    json: "{}"))
    }

    func testSingleNodeUsesManualJSONAndDoesNotRunFollowingNodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let decision = try XCTUnwrap(model.selected?.nodes.first { $0.kind == .decision })
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        model.testNode(decision.id, input: "no es JSON", workspace: workspace, root: root,
                       runner: runner, trusted: true, approvals: try approvingStore())
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.error.contains("JSON válido"))

        let input = "{\"stdout\":\"abc\",\"stderr\":\"\",\"exitCode\":0}"
        model.testNode(decision.id, input: input, workspace: workspace, root: root,
                       runner: runner, trusted: true, approvals: try approvingStore())
        let deadline = Date().addingTimeInterval(5)
        while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.results[decision.id]?.summary, "Sí")
        XCTAssertEqual(model.executionOrder, [decision.id])
        XCTAssertEqual(WorkflowJSON.decode(model.inputJSON[decision.id] ?? "")["stdout"] as? String, "abc")
        let decisionSteps = WorkflowJSON.decode(model.outputJSON[decision.id] ?? "")["steps"] as? [String: [String: Any]]
        XCTAssertEqual(decisionSteps?[decision.id.uuidString]?["summary"] as? String, "Sí")
        XCTAssertEqual(WorkflowJSON.decode(model.outputJSON[decision.id] ?? "")["stdout"] as? String, "abc")

        model.testNode(decision.id, input: "{\"stdout\":\"\",\"exitCode\":0}",
                       workspace: workspace, root: root, runner: runner,
                       trusted: true, approvals: try approvingStore())
        let secondDeadline = Date().addingTimeInterval(5)
        while model.isRunning, Date() < secondDeadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(model.results[decision.id]?.summary, "No")
        XCTAssertEqual(model.results[decision.id]?.successful, true)
        XCTAssertEqual(model.visited[decision.id], .exited(0))
        XCTAssertEqual(model.executionOrder, [decision.id])
        XCTAssertTrue(model.results[decision.id]?.detail.contains("No se cumplió") == true)
    }

    func testCodexOutputModesAndProjectBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = WorkflowAISettings(prompt: "Notas", outputMode: .output,
                                          outputPath: "docs/releases/draft-notes.md")
        let textResult = try WorkflowAIOutput.deliver("## Cambios", settings: settings, root: root)
        XCTAssertEqual(WorkflowJSON.decode(textResult.output)["text"] as? String, "## Cambios")
        settings.outputMode = .file
        let fileResult = try WorkflowAIOutput.deliver("## Cambios", settings: settings, root: root)
        let files = try XCTUnwrap(WorkflowJSON.decode(fileResult.output)["files"] as? [[String: String]])
        XCTAssertEqual(files.first?["content"], "## Cambios")
        let file = root.appendingPathComponent(settings.outputPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        settings.outputMode = .filePath
        XCTAssertEqual(WorkflowJSON
            .decode(try WorkflowAIOutput.deliver("## Nuevo", settings: settings, root: root).output)["files"] as? [[String: String]],
                       [["name": settings.outputPath, "content": "## Nuevo", "mimeType": "text/markdown"]])
        settings.outputMode = .output
        let multiple = """
        {"text":"Listo","files":[{"name":"a.md","content":"A","mimeType":"text/markdown"},
        {"name":"b.json","content":"{}","mimeType":"application/json"}]}
        """
        let multipleOutput = try WorkflowAIOutput.deliver(multiple, settings: settings, root: root).output
        XCTAssertEqual((WorkflowJSON.decode(multipleOutput)["files"] as? [[String: String]])?.count, 2)
        settings.outputMode = .file
        settings.outputPath = "../afuera.md"
        XCTAssertThrowsError(try WorkflowAIOutput.deliver("No", settings: settings, root: root))
    }

    func testCodexRequiredFilesRejectsIncompleteResponseBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = WorkflowAISettings(requiredFiles: [
            WorkflowAIRequiredFile(name: "notes.es.md", mimeType: "text/markdown"),
            WorkflowAIRequiredFile(name: "notes.en.md", mimeType: "text/markdown")
        ])
        let valid = """
        {"text":"Ready","files":[{"name":"notes.es.md","content":"# ES","mimeType":"text/markdown"},
        {"name":"notes.en.md","content":"# EN","mimeType":"text/markdown"}]}
        """
        XCTAssertNoThrow(try WorkflowAIOutput.deliver(valid, settings: settings, root: root))
        let invalid = [
            "plain text",
            ##"{"text":"Ready","files":[{"name":"notes.es.md","content":"# ES","mimeType":"text/markdown"}]}"##,
            valid.replacingOccurrences(of: "notes.en.md", with: "notes.es.md"),
            valid.replacingOccurrences(of: "# EN", with: "  "),
            valid.replacingOccurrences(of: "text/markdown", with: "text/plain")
        ]
        for response in invalid {
            XCTAssertThrowsError(try WorkflowAIOutput.deliver(response, settings: settings, root: root))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testRequiredFilesDecodeWithoutInternalIDs() throws {
        let data = Data(#"{"prompt":"notes","requiredFiles":[{"name":"notes.es.md","mimeType":"text/markdown"}]}"#.utf8)
        let settings = try JSONDecoder().decode(WorkflowAISettings.self, from: data)
        XCTAssertEqual(settings.requiredFiles.first?.name, "notes.es.md")
        XCTAssertNotNil(settings.requiredFiles.first?.id)
    }

    func testFileNodePreviewsThenWritesAndNumbersCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("releases")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("notes.md"))
        var settings = WorkflowFileSettings()
        settings.destination = "releases"
        let input: [String: Any] = ["text": "original", "files": [
            ["name": "notes.md", "content": "new", "mimeType": "text/markdown"],
            ["content": Data([0, 1, 255]).base64EncodedString(), "encoding": "base64", "mimeType": "image/png"]
        ]]
        let preview = try WorkflowFileProcessor.process(input, settings: settings, root: root, preview: true)
        XCTAssertEqual(preview.saved, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("notes (1).md").path))
        XCTAssertEqual(preview.payload["text"] as? String, "original")
        let written = try WorkflowFileProcessor.process(input, settings: settings, root: root, preview: false)
        XCTAssertEqual(written.failed, 0)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("notes.md")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("notes (1).md")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("archivo-2.png")), Data([0, 1, 255]))
        let results = try XCTUnwrap(written.payload["fileResults"] as? [[String: Any]])
        XCTAssertEqual(results[0]["path"] as? String, "releases/notes (1).md")
        XCTAssertEqual(results[1]["status"] as? String, "saved")
    }

    func testFileNodeContinuesAfterInvalidFileAndControlsEmptyInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input: [String: Any] = ["data": ["files": [
            ["name": "../outside.txt", "content": "bad"],
            ["name": "ok.txt", "content": "good"]
        ]]]
        var settings = WorkflowFileSettings()
        settings.sourcePath = "data.files"
        let result = try WorkflowFileProcessor.process(input, settings: settings, root: root, preview: false)
        XCTAssertEqual(result.saved, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("ok.txt"), encoding: .utf8), "good")
        settings.emptyBehavior = .fail
        let empty = try WorkflowFileProcessor.process([:], settings: settings, root: root, preview: true)
        XCTAssertEqual(empty.failed, 1)
        settings.destination = "../outside"
        XCTAssertThrowsError(try WorkflowFileProcessor.process(input, settings: settings, root: root, preview: true))
    }

    func testCodexStepSendsPreviousOutputAndReceivesFinalText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-codex")
        let fixture = """
        #!/usr/bin/env python3
        import json, sys
        def send(value):
            sys.stdout.write(json.dumps(value) + '\\n')
            sys.stdout.flush()
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get('method')
            request_id = message.get('id')
            if method == 'initialize':
                send({'id': request_id, 'result': {}})
            elif method == 'thread/start':
                send({'id': request_id, 'result': {'thread': {'id': 'workflow-thread'}}})
            elif method == 'turn/start':
                prompt = message['params']['input'][0]['text']
                text = '## Cambios\\n- abc Arreglar editor' if 'abc Arreglar editor' in prompt else 'ENTRADA FALTANTE'
                send({'id': request_id, 'result': {'turn': {'id': 'workflow-turn'}}})
                send({'method': 'item/completed', 'params': {'threadId': 'workflow-thread',
                      'item': {'id': 'answer', 'type': 'agentMessage', 'phase': 'final', 'text': text}}})
                send({'method': 'turn/completed', 'params': {'threadId': 'workflow-thread',
                      'turn': {'id': 'workflow-turn', 'status': 'completed'}}})
        """
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let codex = WorkflowCodexRunner()
        let result = try await codex.run(prompt: "Generá notas", input: "abc Arreglar editor",
                                         model: "modelo-de-prueba", root: root, executable: executable)
        XCTAssertEqual(result, "## Cambios\n- abc Arreglar editor")
    }
}
