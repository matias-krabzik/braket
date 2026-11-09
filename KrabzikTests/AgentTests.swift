@testable import Krabzik
import XCTest

final class AgentTests: XCTestCase {
    func testJSONLinesPreserveUnicodeAndSplitMessages() throws {
        let messages = [RPCMessage(id: .number(1), result: .string("Café 🦀")), RPCMessage(method: "item/agentMessage/delta", params: .object(["delta": .string("línea\notra")]))]
        let data = try messages.reduce(into: Data()) { $0.append(try JSONEncoder().encode($1)); $0.append(10) }
        for split in 0...data.count {
            var framer = JSONLineFramer()
            let lines = try framer.append(data.prefix(split)) + framer.append(data.dropFirst(split))
            XCTAssertEqual(lines.count, 2)
            XCTAssertEqual(try JSONDecoder().decode(RPCMessage.self, from: lines[0]).result, .string("Café 🦀"))
        }
        var small = JSONLineFramer(limit: 4)
        XCTAssertThrowsError(try small.append(Data("12345".utf8)))
    }

    func testScopeResolvesSubprojectsAndRejectsSymlinkEscape() throws {
        let base = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let api = base.appendingPathComponent("api"), client = base.appendingPathComponent("client")
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        let first = CodeProject(name: "API", path: "api", kind: .php, command: "")
        let workspace = Workspace(name: "Test", projects: [first, CodeProject(name: "Web", path: client.path, kind: .angular, command: "")])
        let scope = try AgentScope.make(workspace: workspace, url: base.appendingPathComponent("Test.krabzik"), projectID: nil)
        XCTAssertEqual(scope.roots.count, 2)
        XCTAssertTrue(scope.contains(api.appendingPathComponent("new.php")))
        XCTAssertFalse(scope.contains(base.appendingPathComponent("api-else/file.php")))
        try FileManager.default.createSymbolicLink(at: api.appendingPathComponent("outside"), withDestinationURL: base)
        XCTAssertFalse(scope.contains(api.appendingPathComponent("outside/private.txt")))
        let single = try AgentScope.make(workspace: workspace, url: base.appendingPathComponent("Test.krabzik"), projectID: first.id)
        XCTAssertFalse(single.contains(client.appendingPathComponent("app.ts")))
        XCTAssertEqual(scope.sandbox["networkAccess"], .bool(false))
        XCTAssertEqual(scope.sandbox["excludeSlashTmp"], .bool(true))
    }

    @MainActor func testEditorReloadPreservesUnsavedChangesAndUpdatesNativeSurface() throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/agent.swift"), data: Data("let a = 1\n".utf8))
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        document.acceptExternalData(Data("let a = 2\n".utf8))
        XCTAssertEqual(surface.textView.string, "let a = 2\n")
        XCTAssertFalse(document.isDirty)
        document.text = "mi edición"; document.isDirty = true
        document.acceptExternalData(Data("let a = 3\n".utf8))
        XCTAssertEqual(document.text, "mi edición")
        XCTAssertTrue(document.hasExternalChange)
        XCTAssertEqual(String(decoding: document.originalData, as: UTF8.self), "let a = 2\n")
        document.acceptExternalData(Data("let a = 3\n".utf8), discardEdits: true)
        XCTAssertEqual(surface.textView.string, "let a = 3\n")
        XCTAssertFalse(document.hasExternalChange)
    }

    @MainActor func testTransportTimeoutAndPendingRequestOnDisconnect() async throws {
        let base = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let script = base.appendingPathComponent("server.py")
        try fakeServer.write(to: script, atomically: true, encoding: .utf8)
        let transport = CodexTransport()
        defer { transport.stop() }
        try transport.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path])
        do { _ = try await transport.request("hang", timeout: 0.1); XCTFail("Debe vencer") } catch {}
        let result = try await transport.request("echo", .string("🦀"))
        XCTAssertEqual(result, .string("🦀"))
        let job = Task { try await transport.request("hang", timeout: 10) }
        await Task.yield()
        transport.stop()
        do { _ = try await job.value; XCTFail("Debe completar con error al cerrar") } catch {}
    }

    @MainActor func testAgentApprovalStreamingAndFileEvents() async throws {
        let base = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let script = base.appendingPathComponent("server.py")
        try fakeServer.write(to: script, atomically: true, encoding: .utf8)
        let agent = AgentController()
        defer { agent.shutdown() }
        try agent.transport.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path])
        agent.connected = true; agent.account = "ChatGPT"
        var refreshes = 0
        agent.onFilesChanged = { _ in refreshes += 1 }
        agent.send("Cambiar el archivo", scope: AgentScope(names: ["Test"], roots: [base]))
        try await until { !agent.requests.isEmpty }
        XCTAssertTrue(agent.isRunning)
        XCTAssertEqual(agent.requests[0].params["command"].string, "test command")
        XCTAssertTrue(agent.changes.isEmpty)
        agent.answer(agent.requests[0], accept: true)
        try await until { !agent.isRunning }
        XCTAssertNil(agent.error)
        XCTAssertEqual(agent.messages.last?.text, "Cambio terminado 🦀")
        XCTAssertEqual(agent.changes.first?.path, "hello.txt")
        XCTAssertTrue(agent.diff.contains("+nuevo"))
        XCTAssertTrue(agent.requests.isEmpty)
        XCTAssertGreaterThan(refreshes, 0)
        // Old notifications must not contaminate a cleared/new conversation.
        agent.clearConversation()
        agent.receive(RPCMessage(method: "item/agentMessage/delta", params: .object(["threadId": .string("thread-test"), "itemId": .string("late"), "delta": .string("old")])))
        XCTAssertTrue(agent.messages.isEmpty)
    }

    @MainActor func testLiveCodexReadsAndEditsTwoSubprojects() async throws {
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/codex-live-tests")
        guard FileManager.default.fileExists(atPath: marker.path) else { throw XCTSkip("Prueba con suscripción: crear .build/codex-live-tests para habilitarla.") }
        let base = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let roots = [base.appendingPathComponent("api"), base.appendingPathComponent("client")]
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "estado=inicial\n".write(to: root.appendingPathComponent("estado.txt"), atomically: true, encoding: .utf8)
        }
        let agent = AgentController()
        defer { agent.shutdown() }
        await agent.connect()
        XCTAssertTrue(agent.connected, agent.error ?? "No conectado")
        XCTAssertFalse(agent.account.isEmpty, "Requiere sesión de ChatGPT")
        agent.send("Prueba de integración. Leé estado.txt en ambos subproyectos y reemplazá exactamente estado=inicial por estado=listo usando apply_patch. No crees otros archivos, no uses subagentes ni servicios externos. Al finalizar respondé brevemente.", scope: AgentScope(names: ["api", "client"], roots: roots))
        try await until(timeout: 180) { !agent.isRunning || !agent.requests.isEmpty }
        XCTAssertTrue(agent.requests.isEmpty, "La prueba no autoriza ninguna ampliación de permisos")
        XCTAssertNil(agent.error)
        for root in roots { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("estado.txt"), encoding: .utf8), "estado=listo\n") }
        XCTAssertEqual(agent.changes.count, 2)
        XCTAssertFalse(agent.messages.last?.text.isEmpty ?? true)
    }

    @MainActor func testInterruptClearsPendingApprovalAndAllowsNewTurn() async throws {
        let base = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let script = base.appendingPathComponent("server.py")
        try fakeServer.write(to: script, atomically: true, encoding: .utf8)
        let agent = AgentController()
        defer { agent.shutdown() }
        try agent.transport.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path])
        agent.connected = true; agent.account = "ChatGPT"
        let scope = AgentScope(names: ["Test"], roots: [base])
        agent.send("Primero", scope: scope)
        try await until { !agent.requests.isEmpty }
        agent.stop()
        try await until { !agent.isRunning }
        XCTAssertTrue(agent.requests.isEmpty)
        XCTAssertFalse(agent.isStopping)
        XCTAssertTrue(agent.transport.running)
        agent.send("Segundo", scope: scope)
        try await until { !agent.requests.isEmpty }
        // An old interrupt watchdog must never stop a later turn.
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertTrue(agent.isRunning)
        agent.answer(agent.requests[0], accept: true)
        try await until { !agent.isRunning }
        XCTAssertNil(agent.error)
        XCTAssertEqual(agent.messages.filter(\.isUser).count, 2)
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor private func until(timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw AgentFailure("La prueba agotó su tiempo de espera.") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    private var fakeServer: String { #"""
import sys,json
def out(v): print(json.dumps(v,ensure_ascii=False),flush=True)
def note(m,p): out({'method':m,'params':dict({'threadId':'thread-test','turnId':'turn-test'},**p)})
for line in sys.stdin:
 v=json.loads(line); method=v.get('method'); i=v.get('id')
 if method=='hang': continue
 if method=='echo': out({'id':i,'result':v['params']})
 elif method=='thread/start': out({'id':i,'result':{'thread':{'id':'thread-test'},'model':'fixture'}})
 elif method=='turn/start':
  note('turn/started',{'turn':{'id':'turn-test'}})
  out({'id':i,'result':{'turn':{'id':'turn-test'}}})
  out({'id':'approve-1','method':'item/commandExecution/requestApproval','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'cmd','command':'test command'}})
 elif i=='approve-1':
  if v.get('result',{}).get('decision')!='accept': continue
  note('item/completed',{'item':{'id':'file','type':'fileChange','status':'completed','changes':[{'path':'hello.txt','kind':{'type':'update'},'diff':'-viejo\n+nuevo'}]}})
  note('turn/diff/updated',{'diff':'-viejo\n+nuevo'})
  note('item/agentMessage/delta',{'itemId':'answer','delta':'Cambio '})
  note('item/agentMessage/delta',{'itemId':'answer','delta':'terminado 🦀'})
  note('item/completed',{'item':{'id':'answer','type':'agentMessage','text':'Cambio terminado 🦀','phase':'final_answer'}})
  note('turn/completed',{'turn':{'id':'turn-test','status':'completed'}})
 elif method=='turn/interrupt':
  out({'id':i,'result':{}})
  note('turn/completed',{'turn':{'id':'turn-test','status':'interrupted'}})
"""# }
}
