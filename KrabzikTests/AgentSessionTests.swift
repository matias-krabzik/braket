@testable import Krabzik
import XCTest

@MainActor
final class AgentSessionTests: XCTestCase {
    private func environment() throws -> (URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (root, defaults)
    }

    func testSessionsAndDraftsSurviveRestartAndStayWithTheirWorkspace() throws {
        let (root, defaults) = try environment()
        let first = root.appendingPathComponent("a.kzk"), second = root.appendingPathComponent("b.kzk")
        let agent = AgentController(defaults: defaults)
        agent.configureSessions(workspace: first)
        agent.newSession()
        let id = try XCTUnwrap(agent.selectedSessionID)
        agent.draft = "Continuar desde acá"
        agent.renameSession(id, title: "Corregir editor")
        agent.configureSessions(workspace: second)
        XCTAssertTrue(agent.sessions.isEmpty)
        let restored = AgentController(defaults: defaults)
        restored.configureSessions(workspace: first)
        restored.selectSession(id)
        XCTAssertEqual(restored.draft, "Continuar desde acá")
        XCTAssertEqual(restored.sessionTitle, "Corregir editor")
        restored.newSession()
        XCTAssertEqual(restored.sessions.count, 2)
        restored.selectSession(id)
        XCTAssertEqual(restored.draft, "Continuar desde acá")
    }

    func testAutomaticContextIncludesSelectionAndScopedProcessesButExcludesSecrets() async throws {
        let (root, _) = try environment()
        let scope = AgentScope(names: ["api"], roots: [root])
        let docs = DocumentStore()
        let file = root.appendingPathComponent("main.swift")
        try "let selected = 42\n".write(to: file, atomically: true, encoding: .utf8)
        try await docs.open(file)
        let document = try XCTUnwrap(docs.selected)
        document.selectedRange = NSRange(location: 4, length: 8)
        let project = CodeProject(name: "api", path: ".", kind: .files, command: "")
        var workspace = Workspace(name: "Test")
        workspace.projects = [project]
        let url = root.appendingPathComponent("project.kzk")
        let runner = ProcessRunner()
        let run = runner.state(for: project.id)
        run.workspaceURL = url
        run.output = "compiler error: missing identifier"
        var context = AgentContext.capture(scope: scope, docs: docs, workspace: workspace, url: url, runner: runner)
        XCTAssertTrue(context.contains("\"selection\" : \"selected\""))
        XCTAssertTrue(context.contains("compiler error"))
        run.workspaceURL = root.appendingPathComponent("other.kzk")
        context = AgentContext.capture(scope: scope, docs: docs, workspace: workspace, url: url, runner: runner)
        XCTAssertFalse(context.contains("compiler error"))
        document.text = String(repeating: "🦀", count: 100_000)
        document.selectedRange = NSRange(location: 100_001, length: 90_000)
        context = AgentContext.capture(scope: scope, docs: docs, workspace: workspace, url: url, runner: runner)
        XCTAssertLessThan(context.utf8.count, 60_000)
        XCTAssertTrue(context.contains("selectionTruncated"))
        let secret = root.appendingPathComponent(".env.local")
        try "TOKEN=private".write(to: secret, atomically: true, encoding: .utf8)
        try await docs.open(secret)
        context = AgentContext.capture(scope: scope, docs: docs, workspace: workspace, url: url, runner: runner)
        XCTAssertFalse(context.contains("TOKEN"))
        XCTAssertFalse(context.contains(".env.local"))
        let link = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
        XCTAssertFalse(AgentContext.permits(link, scope: scope))
    }

    func testPersistentProtocolResumesHistoryAndQueriesLiveEditorContext() async throws {
        let (root, defaults) = try environment()
        let script = root.appendingPathComponent("server.py")
        try server.write(to: script, atomically: true, encoding: .utf8)
        let scope = AgentScope(names: ["Test"], roots: [root])
        let workspace = root.appendingPathComponent("test.kzk")
        func start() throws -> AgentController {
            let agent = AgentController(defaults: defaults)
            agent.configureSessions(workspace: workspace)
            agent.scopeProvider = { scope }
            agent.contextProvider = { _ in "editor actualizado" }
            try agent.transport.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path])
            agent.connected = true
            agent.account = "ChatGPT"
            return agent
        }
        let agent = try start()
        defer { agent.shutdown() }
        agent.send("Corregí esto", scope: scope, context: AgentContext.marker + " instantánea")
        try await until { !agent.isRunning }
        XCTAssertNil(agent.error)
        XCTAssertEqual(agent.messages.last?.text, "editor actualizado")
        let id = try XCTUnwrap(agent.selectedSessionID)
        agent.shutdown()
        let restored = try start()
        defer { restored.shutdown() }
        restored.selectSession(id)
        try await until { !restored.messages.isEmpty && !restored.isLoadingSession }
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.messages.map(\.text), ["Corregí esto", "Resuelto"])
        restored.send("Verificá", scope: scope)
        try await until { !restored.isRunning }
        XCTAssertNil(restored.error)
        let calls = try String(contentsOf: root.appendingPathComponent("calls.txt"), encoding: .utf8)
        XCTAssertEqual(calls.components(separatedBy: "thread/start\n").count - 1, 1)
        XCTAssertTrue(calls.contains("thread/resume\n"))
        XCTAssertEqual(restored.sessions.count, 1)
        let other = AgentScope(names: ["Other"], roots: [root.appendingPathComponent("other")])
        restored.send("No ampliar el alcance", scope: other)
        XCTAssertFalse(restored.isRunning)
        XCTAssertTrue(restored.error?.contains("carpetas") == true)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw AgentFailure("Tiempo agotado en el protocolo de sesiones.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var server: String { #"""
import sys,json,pathlib
def out(v): print(json.dumps(v),flush=True)
def note(m,p): out({'method':m,'params':dict({'threadId':'saved-thread','turnId':'turn'},**p)})
for line in sys.stdin:
 v=json.loads(line); m=v.get('method'); i=v.get('id'); p=v.get('params',{})
 if m:
  with open(pathlib.Path(__file__).with_name('calls.txt'),'a') as f: f.write(m+'\n')
 if m=='thread/start':
  assert p['ephemeral']==False
  assert p['dynamicTools'][0]['name']=='braket_get_context'
  out({'id':i,'result':{'thread':{'id':'saved-thread'},'model':'fixture'}})
 elif m=='thread/resume':
  assert p['threadId']=='saved-thread'
  assert p['sandbox']=='workspace-write'
  out({'id':i,'result':{'thread':{'id':'saved-thread'},'model':'fixture'}})
 elif m=='thread/turns/list':
  items=[{'id':'user','type':'userMessage','content':[{'type':'text','text':'Corregí esto'},
   {'type':'text','text':'<braket_context> datos internos'}]},
   {'id':'comment','type':'agentMessage','phase':'commentary','text':'Investigando'},
   {'id':'answer','type':'agentMessage','phase':'final_answer','text':'Resuelto'}]
  out({'id':i,'result':{'data':[{'id':'old-turn','items':items}],'nextCursor':None}})
 elif m=='turn/start':
  out({'id':i,'result':{'turn':{'id':'turn'}}})
  note('turn/started',{'turn':{'id':'turn'}})
  out({'id':'tool','method':'item/tool/call','params':{'threadId':'saved-thread','turnId':'turn',
       'callId':'context','tool':'braket_get_context','arguments':{}}})
 elif i=='tool':
  assert v['result']['success']
  text=v['result']['contentItems'][0]['text']
  note('item/completed',{'item':{'id':'latest','type':'agentMessage','phase':'final_answer','text':text}})
  note('turn/completed',{'turn':{'id':'turn','status':'completed'}})
 elif m=='thread/unsubscribe': out({'id':i,'result':{}})
"""# }
}
