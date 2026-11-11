import SwiftUI

struct WorkflowView: View {
    @Bindable var controller: WorkspaceController
    let workspaceURL: URL
    @State private var selectedNode: UUID?

    private var flow: Workflow? { controller.workflows.selected }
    private var index: Int? { controller.workflows.file.workflows.firstIndex { $0.id == controller.workflows.selectedID } }

    var body: some View {
        @Bindable var model = controller.workflows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.accent)
                Text(flow?.name ?? "Automatización").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("Modo", selection: $model.editing) {
                    Text("Ejecución").tag(false)
                    Text("Editar").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                if model.editing {
                    Menu { ForEach(WorkflowKind.allCases.filter { $0 != .start }, id: \.self) { kind in
                        Button(kind.title) { add(kind) }
                    } } label: { Label("Bloque", systemImage: "plus") }
                    Button("Guardar") { model.save() }
                } else {
                    Button(model.isRunning ? "Detener" : "Ejecutar") {
                        if model.isRunning { model.stop() }
                        else { model.run(workspace: workspaceURL, root: controller.workflowRoot,
                                         runner: controller.runner, trusted: !controller.isReadOnly) }
                    }.disabled(controller.isReadOnly)
                }
            }.controlSize(.small).padding(.horizontal, 12).frame(height: 36).background(Theme.bar)
            Divider()
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let scale = min(1, geometry.size.width / 1100, geometry.size.height / 400)
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: 1100, height: 400)
                        if let flow {
                            Canvas { context, _ in
                                for node in flow.nodes {
                                    for (destination, color) in [(node.next, node.kind == .decision ? Color.green : Theme.accent),
                                                                 (node.no, Color.orange)] {
                                        guard let destination,
                                              let target = flow.nodes.first(where: { $0.id == destination }) else { continue }
                                        var path = Path()
                                        let start = CGPoint(x: node.x + 170, y: node.y + 27)
                                        let end = CGPoint(x: target.x, y: target.y + 27)
                                        path.move(to: start)
                                        path.addCurve(to: end, control1: CGPoint(x: start.x + 45, y: start.y),
                                                      control2: CGPoint(x: end.x - 45, y: end.y))
                                        context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 2)
                                    }
                                }
                            }.frame(width: 1100, height: 400)
                            ForEach(flow.nodes) { node in
                                WorkflowNodeCard(node: node, selected: selectedNode == node.id,
                                                 status: model.visited[node.id], active: model.activeNodeID == node.id)
                                    .offset(x: node.x, y: node.y)
                                    .onTapGesture { selectedNode = node.id }
                                    .gesture(model.editing ? DragGesture(minimumDistance: 4).onEnded { gesture in
                                        move(node.id, dx: gesture.translation.width, dy: gesture.translation.height)
                                    } : nil)
                            }
                        }
                    }.frame(width: 1100, height: 400, alignment: .topLeading)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .background(Theme.background)
                }
                if let index, let nodeIndex = model.file.workflows[index].nodes.firstIndex(where: { $0.id == selectedNode }) {
                    Divider()
                    WorkflowInspector(node: $model.file.workflows[index].nodes[nodeIndex],
                                      choices: model.file.workflows[index].nodes, editing: model.editing,
                                      remove: { remove(model.file.workflows[index].nodes[nodeIndex].id) })
                        .frame(width: 270).background(Theme.bar)
                }
            }
        }.onAppear { model.configure(workspaceURL, root: controller.workflowRoot) }
    }

    private func add(_ kind: WorkflowKind) {
        guard let index else { return }
        let node = WorkflowNode(kind: kind, title: kind.title, x: 180 + Double(flow?.nodes.count ?? 0) * 75, y: 360)
        controller.workflows.file.workflows[index].nodes.append(node)
        selectedNode = node.id
    }

    private func move(_ id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let index, let nodeIndex = controller.workflows.file.workflows[index].nodes.firstIndex(where: { $0.id == id }) else { return }
        controller.workflows.file.workflows[index].nodes[nodeIndex].x = max(0,
                                                                            min(900,
                                                                                controller.workflows.file.workflows[index].nodes[nodeIndex]
                                                                                .x + dx))
        controller.workflows.file.workflows[index].nodes[nodeIndex].y = max(0,
                                                                            min(510,
                                                                                controller.workflows.file.workflows[index].nodes[nodeIndex]
                                                                                .y + dy))
    }

    private func remove(_ id: UUID) {
        guard let index else { return }
        controller.workflows.file.workflows[index].nodes.removeAll { $0.id == id && $0.kind != .start }
        for nodeIndex in controller.workflows.file.workflows[index].nodes.indices {
            if controller.workflows.file.workflows[index].nodes[nodeIndex].next == id {
                controller.workflows.file.workflows[index].nodes[nodeIndex].next = nil
            }
            if controller.workflows.file.workflows[index].nodes[nodeIndex].no == id {
                controller.workflows.file.workflows[index].nodes[nodeIndex].no = nil
            }
        }
        selectedNode = nil
    }
}

private struct WorkflowNodeCard: View {
    let node: WorkflowNode
    let selected: Bool
    let status: RunStatus?
    let active: Bool

    private var color: Color {
        switch node.kind {
        case .start: return .green
        case .script: return Theme.accent
        case .decision: return .orange
        case .end: return .purple
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.kind == .start ? "play.fill" : node.kind == .script ? "terminal" : node
                .kind == .decision ? "arrow.triangle.branch" : "checkmark.flag")
                .foregroundStyle(color)
            Text(node.title).lineLimit(1)
            Spacer(minLength: 0)
            if let status { Image(systemName: status == .exited(0) ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(status == .exited(0) ? .green : .red) }
        }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).frame(width: 170, height: 54)
            .background(color.opacity(active ? 0.24 : 0.10), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(selected ? 0.95 : 0.5), lineWidth: selected ? 2 : 1))
    }
}

private struct WorkflowInspector: View {
    @Binding var node: WorkflowNode
    let choices: [WorkflowNode]
    let editing: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(node.kind.title).font(.headline)
            TextField("Nombre", text: $node.title).disabled(!editing)
            if node.kind == .script {
                Text("Comando").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $node.command).font(.system(size: 11, design: .monospaced))
                    .frame(height: 110).disabled(!editing)
                Text("Se ejecuta con zsh en la carpeta del proyecto; podés usar xcodebuild y las herramientas instaladas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if node.kind != .end {
                Picker(node.kind == .decision ? "Si sí" : "Siguiente", selection: $node.next) {
                    Text("Sin conexión").tag(Optional<UUID>.none)
                    ForEach(choices.filter { $0.id != node.id && $0.kind != .start }) { item in
                        Text(item.title).tag(Optional(item.id))
                    }
                }.disabled(!editing)
            }
            if node.kind == .decision {
                Picker("Si no", selection: $node.no) {
                    Text("Sin conexión").tag(Optional<UUID>.none)
                    ForEach(choices.filter { $0.id != node.id && $0.kind != .start }) { item in
                        Text(item.title).tag(Optional(item.id))
                    }
                }.disabled(!editing)
            }
            if node.kind != .start, editing { Button("Quitar bloque", role: .destructive, action: remove) }
            Spacer()
        }.padding(14).textFieldStyle(.roundedBorder)
    }
}
