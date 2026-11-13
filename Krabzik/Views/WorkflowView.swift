import SwiftUI

private struct WorkflowPortSource: Equatable {
    let nodeID: UUID
    let isNo: Bool
}

struct WorkflowView: View {
    @Bindable var controller: WorkspaceController
    let workspaceURL: URL
    @State private var selectedNode: UUID?
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat?
    @State private var draggedNode: UUID?
    @State private var liveNodeDrag: CGSize = .zero
    @State private var pendingConnection: WorkflowPortSource?
    @State private var connectionPreview: CGPoint?
    @State private var hoveredInput: UUID?
    @State private var hoveredNode: UUID?
    @State private var showingInspector = false
    @State private var showingNodePicker = false
    @State private var showingCodexConnection = false
    @State private var pickerSource: WorkflowPortSource?

    private var flow: Workflow? { controller.workflows.selected }
    private var index: Int? { controller.workflows.file.workflows.firstIndex { $0.id == controller.workflows.selectedID } }
    private var canEdit: Bool { !controller.isReadOnly && !controller.workflows.isRunning }
    private var selectedTriggerKind: WorkflowKind? {
        flow?.nodes.first(where: { $0.id == selectedNode && $0.kind.isTrigger })?.kind
    }

    var body: some View {
        @Bindable var model = controller.workflows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.accent)
                Text(flow?.name ?? "Automatización").font(.system(size: Theme.zoom(12), weight: .semibold))
                Spacer()
                Button { pickerSource = nil
                    showingNodePicker = true
                } label: { Label("Bloque", systemImage: "plus") }
                    .disabled(!canEdit)
                Button("Guardar") { model.save() }.disabled(!canEdit)
                Button(model.isRunning ? "Detener" : selectedTriggerKind == .event || selectedTriggerKind == .schedule
                    ? "Probar" : "Ejecutar") {
                    if model.isRunning { model.stop() }
                    else { runWorkflow(from: selectedTriggerKind ?? .start) }
                }.disabled(controller.isReadOnly || (!model.isRunning &&
                    flow?.nodes.contains { $0.kind == (selectedTriggerKind ?? .start) } != true))
            }.controlSize(.small).padding(.horizontal, 12).frame(height: 36).background(Theme.bar)
            Divider()
            VSplitView {
                GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    WorkflowPanSurface(zoom: zoom, interactionRects: interactionRects(size: geometry.size),
                                       connections: connectionDrawings(size: geometry.size), clearConnection: {
                        pendingConnection = nil
                        connectionPreview = nil
                    }) {
                    ZStack(alignment: .topLeading) {
                    if let flow {
                        ForEach(flow.nodes) { node in
                            WorkflowNodeCard(node: node, selected: selectedNode == node.id,
                                             status: model.visited[node.id], result: model.results[node.id],
                                             active: model.isRunning && model.activeNodeID == node.id)
                                .contextMenu { nodeMenuActions(node, in: flow) }
                                .scaleEffect(zoom)
                                .onTapGesture { openInspector(node.id) }
                                .onHover { hoveredNode = $0 ? node.id : nil }
                                .overlay(alignment: .topTrailing) {
                                    if hoveredNode == node.id || selectedNode == node.id {
                                        Menu {
                                            nodeMenuActions(node, in: flow)
                                        } label: {
                                            Image(systemName: "ellipsis")
                                                .font(.system(size: Theme.zoom(11), weight: .semibold))
                                                .frame(width: 22, height: 22)
                                                .background(Theme.bar, in: Circle())
                                        }
                                        .menuStyle(.borderlessButton)
                                        .frame(width: 22, height: 22)
                                        .offset(x: 9, y: -8)
                                        .help("Opciones de \(node.title)")
                                        .onHover { if $0 { hoveredNode = node.id } }
                                    }
                                }
                                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("workflowCanvas"))
                                    .onChanged { value in
                                        guard canEdit else { return }
                                        selectedNode = node.id
                                        draggedNode = node.id
                                        liveNodeDrag = value.translation
                                    }
                                    .onEnded { value in
                                        guard canEdit else { return }
                                        move(node.id, dx: value.translation.width / zoom,
                                             dy: value.translation.height / zoom)
                                        draggedNode = nil
                                        liveNodeDrag = .zero
                                    })
                                .position(nodeCenter(node, size: geometry.size))
                        }
                        ForEach(flow.nodes.filter { !$0.kind.isTrigger }) { node in
                            inputPort(for: node, size: geometry.size)
                                .position(inputPoint(node, size: geometry.size))
                                .onTapGesture { connect(to: node.id) }
                        }
                        ForEach(flow.nodes.filter { $0.kind != .end }) { node in
                            outputPort(for: node, isNo: false, size: geometry.size)
                                .position(outputPoint(node, isNo: false, size: geometry.size))
                            if node.kind == .decision {
                                outputPort(for: node, isNo: true, size: geometry.size)
                                    .position(outputPoint(node, isNo: true, size: geometry.size))
                            }
                        }
                    }
                    }
                    .coordinateSpace(name: "workflowCanvas")
                    }
                    VStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Button { zoom = max(0.65, zoom - 0.1) } label: { Image(systemName: "minus") }
                            Text("\(Int(zoom * 100)) %").monospacedDigit().frame(width: 48)
                            Button { zoom = min(1.6, zoom + 0.1) } label: { Image(systemName: "plus") }
                        }
                        .font(.system(size: Theme.zoom(11))).buttonStyle(.borderless)
                        .padding(7).background(Theme.bar, in: RoundedRectangle(cornerRadius: 7))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(12)
                    }
                }
                .background(Theme.background)
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { value in
                        if zoomAtGestureStart == nil { zoomAtGestureStart = zoom }
                        zoom = min(1.6, max(0.65, (zoomAtGestureStart ?? zoom) * value))
                    }
                    .onEnded { _ in zoomAtGestureStart = nil })
                }
                WorkflowExecutionPanel(model: model, flow: flow)
                    .frame(minHeight: 135, idealHeight: 205, maxHeight: .infinity)
            }
        }.onAppear { model.configure(workspaceURL, root: controller.workflowRoot) }
            .task(id: workspaceURL) {
                // The connection must not cancel/restart its own task when it
                // publishes connected. Failures are retried explicitly in Codex.
                await controller.agent.connect()
            }
            .onChange(of: model.selectedID) { _, _ in
                selectedNode = nil
                pendingConnection = nil
                showingInspector = false
            }
            .sheet(isPresented: $showingNodePicker) {
                WorkflowNodePicker(kinds: WorkflowKind.allCases.filter { kind in
                    guard kind != .event && kind != .schedule else { return false }
                    guard available(kind) else { return false }
                    guard let pickerSource else { return true }
                    return !kind.isTrigger && (kind != .end || linkedTarget(of: pickerSource) == nil)
                }, select: { kind in
                    add(kind, after: pickerSource)
                    showingNodePicker = false
                    pickerSource = nil
                }, close: { showingNodePicker = false })
            }
            .sheet(isPresented: $showingInspector) {
                if let index, let nodeIndex = model.file.workflows[index].nodes.firstIndex(where: { $0.id == selectedNode }) {
                    WorkflowInspector(node: $model.file.workflows[index].nodes[nodeIndex],
                                      choices: model.file.workflows[index].nodes, canEdit: canEdit,
                                      isRunning: model.isRunning,
                                      rootURL: controller.workflowRoot,
                                      models: controller.agent.availableModels,
                                      codexConnected: controller.agent.connected && !controller.agent.account.isEmpty,
                                      openCodex: { showingCodexConnection = true },
                                      inputJSON: model.inputJSON[model.file.workflows[index].nodes[nodeIndex].id],
                                      outputJSON: model.outputJSON[model.file.workflows[index].nodes[nodeIndex].id],
                                      branchOutcome: model.results[model.file.workflows[index].nodes[nodeIndex].id]?.summary,
                                      result: model.results[model.file.workflows[index].nodes[nodeIndex].id],
                                      error: model.error,
                                      test: { input in
                                          if model.isRunning { model.stop() }
                                          else {
                                              model.testNode(model.file.workflows[index].nodes[nodeIndex].id,
                                                             input: input, workspace: workspaceURL,
                                                             root: controller.workflowRoot,
                                                             runner: controller.runner,
                                                             trusted: !controller.isReadOnly,
                                                             approvals: controller.session.trustStore,
                                                             agent: controller.agent)
                                          }
                                      },
                                      save: {
                                          model.save()
                                          if model.error.isEmpty {
                                              showingInspector = false
                                              selectedNode = nil
                                          }
                                      },
                                      close: {
                                          showingInspector = false
                                          selectedNode = nil
                                      })
                        .id(model.file.workflows[index].nodes[nodeIndex].id)
                        .frame(width: 1260, height: 720)
                        .background(Theme.bar)
                        .sheet(isPresented: $showingCodexConnection) {
                            AgentPanel(controller: controller, onClose: { showingCodexConnection = false })
                                .frame(width: 430, height: 560)
                        }
                }
            }
    }

    private func available(_ kind: WorkflowKind) -> Bool {
        !kind.isTrigger || flow?.nodes.contains(where: { $0.kind.isTrigger }) != true
    }

    private func linkedTarget(of source: WorkflowPortSource) -> UUID? {
        guard let node = flow?.nodes.first(where: { $0.id == source.nodeID }) else { return nil }
        return source.isNo ? node.no : node.next
    }

    private func openInspector(_ id: UUID) {
        selectedNode = id
        showingInspector = true
    }

    private func runWorkflow(from trigger: WorkflowKind) {
        let model = controller.workflows
        guard !controller.isReadOnly, !model.isRunning,
              flow?.nodes.contains(where: { $0.kind == trigger }) == true else { return }
        model.save()
        guard model.error.isEmpty else { return }
        model.run(workspace: workspaceURL, root: controller.workflowRoot,
                  runner: controller.runner, trusted: true,
                  approvals: controller.session.trustStore, agent: controller.agent,
                  trigger: trigger)
    }

    @ViewBuilder private func nodeMenuActions(_ node: WorkflowNode, in flow: Workflow) -> some View {
        if node.kind == .start {
            Button("Ejecutar", systemImage: "play.fill") { runWorkflow(from: .start) }
                .disabled(!canEdit)
            Divider()
        }
        Button("Ver detalle", systemImage: "slider.horizontal.3") { openInspector(node.id) }
        Divider()
        Button("Quitar bloque", systemImage: "trash", role: .destructive) { remove(node.id) }
            .disabled(!canEdit || node.kind.isTrigger && flow.nodes.filter { $0.kind.isTrigger }.count == 1)
    }

    private func nodeCenter(_ node: WorkflowNode, size: CGSize) -> CGPoint {
        let drag = draggedNode == node.id ? liveNodeDrag : .zero
        return CGPoint(x: (CGFloat(node.x) + (node.kind.isTrigger ? 30 : halfWidth(of: node)) - 550) * zoom
                        + size.width / 2 + drag.width,
                       y: (CGFloat(node.y) + (node.kind.isTrigger ? 30 : 27) - 200) * zoom
                        + size.height / 2 + drag.height)
    }

    private func halfWidth(of node: WorkflowNode) -> CGFloat { node.kind == .decision ? 100 : 85 }

    private func inputPoint(_ node: WorkflowNode, size: CGSize) -> CGPoint {
        let center = nodeCenter(node, size: size)
        return CGPoint(x: center.x - halfWidth(of: node) * zoom, y: center.y)
    }

    private func outputPoint(_ node: WorkflowNode, isNo: Bool, size: CGSize) -> CGPoint {
        let center = nodeCenter(node, size: size)
        return CGPoint(x: center.x + (node.kind.isTrigger ? 30 : halfWidth(of: node)) * zoom,
                       y: center.y + (node.kind == .decision ? (isNo ? 12 : -12) * zoom : 0))
    }

    private func inputPort(for node: WorkflowNode, size: CGSize) -> some View {
        Circle()
            .fill(Theme.background)
            .frame(width: 15 * zoom, height: 15 * zoom)
            .overlay(Circle().stroke(hoveredInput == node.id ? Theme.accent : Theme.accent.opacity(0.8),
                                     lineWidth: hoveredInput == node.id ? 3 : 2))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .help(pendingConnection == nil ? "Entrada de \(node.title)" : "Conectar con \(node.title)")
    }

    private func outputPort(for node: WorkflowNode, isNo: Bool, size: CGSize) -> some View {
        let source = WorkflowPortSource(nodeID: node.id, isNo: isNo)
        let color: Color = node.kind == .decision ? (isNo ? .red : .green) : Theme.accent
        return Image(systemName: pendingConnection == source ? "arrow.right" : "plus")
            .font(.system(size: Theme.zoom(11), weight: .bold))
            .foregroundStyle(color)
            .frame(width: 20 * zoom, height: 20 * zoom)
            .background(Theme.background, in: Circle())
            .overlay(Circle().stroke(color, lineWidth: 2))
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .onTapGesture {
                guard canEdit else { return }
                pickerSource = source
                showingNodePicker = true
                pendingConnection = nil
                connectionPreview = nil
            }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("workflowCanvas"))
                .onChanged { value in
                    guard canEdit else { return }
                    pendingConnection = source
                    connectionPreview = value.location
                    hoveredInput = dropTarget(at: value.location, size: size)
                }
                .onEnded { value in
                    guard canEdit else { return }
                    if let target = dropTarget(at: value.location, size: size) { connect(to: target) }
                    connectionPreview = nil
                    hoveredInput = nil
                })
            .help(node.kind == .decision ? (isNo ? "Conectar salida No" : "Conectar salida Sí")
                  : "Conectar salida de \(node.title)")
    }

    private func dropTarget(at point: CGPoint, size: CGSize) -> UUID? {
        flow?.nodes.filter { !$0.kind.isTrigger }.first { node in
            let input = inputPoint(node, size: size)
            return hypot(input.x - point.x, input.y - point.y) <= 30
        }?.id
    }

    private func connect(to targetID: UUID) {
        guard canEdit, let pendingConnection, let index else { return }
        if controller.workflows.file.workflows[index]
            .connect(from: pendingConnection.nodeID, isNo: pendingConnection.isNo, to: targetID) {
            self.pendingConnection = nil
            connectionPreview = nil
            hoveredInput = nil
        }
    }

    private func interactionRects(size: CGSize) -> [CGRect] {
        (flow?.nodes ?? []).map { node in
            let center = nodeCenter(node, size: size)
            let width = (node.kind.isTrigger ? 60 : halfWidth(of: node) * 2) * zoom + 48
            return CGRect(x: center.x - width / 2, y: center.y - 55, width: width, height: 110)
        }
    }

    private func connectionDrawings(size: CGSize) -> [WorkflowConnectionDrawing] {
        guard let flow else { return [] }
        var drawings: [WorkflowConnectionDrawing] = []
        let traversed = controller.workflows.traversedTransitions
        let hasExecution = !controller.workflows.results.isEmpty
        let nodesByID = Dictionary(uniqueKeysWithValues: flow.nodes.map { ($0.id, $0) })
        for node in flow.nodes {
            for (destination, isNo, color) in [(node.next, false, node.kind == .decision ? Color.green : Theme.accent),
                                               (node.no, true, Color.red)] {
                guard let destination, let target = nodesByID[destination] else { continue }
                let taken = traversed.contains(WorkflowTransition(from: node.id, to: destination, isNo: isNo))
                drawings.append(arrowDrawing(from: outputPoint(node, isNo: isNo, size: size),
                          to: inputPoint(target, size: size), color: color,
                          targetWidth: halfWidth(of: target) * 2 * zoom,
                          opacity: hasExecution ? (taken ? 1 : 0.16) : 0.85,
                          lineWidth: taken ? 3.5 : 2))
            }
        }
        if let pendingConnection, let source = nodesByID[pendingConnection.nodeID] {
            let start = outputPoint(source, isNo: pendingConnection.isNo, size: size)
            let end = connectionPreview ?? CGPoint(x: start.x + 65 * zoom, y: start.y)
            let color: Color = source.kind == .decision ? (pendingConnection.isNo ? .red : .green) : Theme.accent
            drawings.append(arrowDrawing(from: start, to: end, color: color))
        }
        return drawings
    }

    private func arrowDrawing(from start: CGPoint, to end: CGPoint,
                           color: Color, targetWidth: CGFloat = 0,
                           opacity: Double = 0.85, lineWidth: CGFloat = 2) -> WorkflowConnectionDrawing {
        var path = Path()
        path.move(to: start)
        if end.x < start.x + 24 * zoom {
            let direction: CGFloat = end.y >= start.y ? 1 : -1
            let right = max(start.x, end.x + targetWidth) + 55 * zoom
            let outsideY = end.y + direction * 82 * zoom
            let left = end.x - 55 * zoom
            let corner = 14 * zoom
            path.addLine(to: CGPoint(x: right - corner, y: start.y))
            path.addQuadCurve(to: CGPoint(x: right, y: start.y + direction * corner),
                              control: CGPoint(x: right, y: start.y))
            path.addLine(to: CGPoint(x: right, y: outsideY - direction * corner))
            path.addQuadCurve(to: CGPoint(x: right - corner, y: outsideY),
                              control: CGPoint(x: right, y: outsideY))
            path.addLine(to: CGPoint(x: left + corner, y: outsideY))
            path.addQuadCurve(to: CGPoint(x: left, y: outsideY - direction * corner),
                              control: CGPoint(x: left, y: outsideY))
            path.addLine(to: CGPoint(x: left, y: end.y + direction * corner))
            path.addQuadCurve(to: CGPoint(x: left + corner, y: end.y),
                              control: CGPoint(x: left, y: end.y))
            path.addLine(to: end)
        } else {
            let control = max(30, abs(end.x - start.x) * 0.35)
            path.addCurve(to: end, control1: CGPoint(x: start.x + control, y: start.y),
                          control2: CGPoint(x: end.x - control, y: end.y))
        }
        var tip = Path()
        tip.move(to: CGPoint(x: end.x - 8, y: end.y - 4))
        tip.addLine(to: end)
        tip.addLine(to: CGPoint(x: end.x - 8, y: end.y + 4))
        path.addPath(tip)
        return WorkflowConnectionDrawing(path: path, color: color, opacity: opacity, lineWidth: lineWidth)
    }

    private func add(_ kind: WorkflowKind, after source: WorkflowPortSource? = nil) {
        guard let index, available(kind) else { return }
        let triggerCount = flow?.nodes.filter { $0.kind.isTrigger }.count ?? 0
        var node = WorkflowNode(kind: kind, title: kind.title,
                                x: kind.isTrigger ? 70 : 180 + Double(flow?.nodes.count ?? 0) * 75,
                                y: kind.isTrigger ? 220 + Double(triggerCount) * 90 : 360)
        if let source, !kind.isTrigger,
           let sourceIndex = controller.workflows.file.workflows[index].nodes.firstIndex(where: { $0.id == source.nodeID }) {
            let origin = controller.workflows.file.workflows[index].nodes[sourceIndex]
            node.x = origin.x + (origin.kind.isTrigger ? 110 : 220)
            node.y = origin.y + (source.isNo ? 120 : 0)
            if source.isNo {
                node.next = origin.no
                controller.workflows.file.workflows[index].nodes[sourceIndex].no = node.id
            } else {
                node.next = origin.next
                controller.workflows.file.workflows[index].nodes[sourceIndex].next = node.id
            }
        }
        controller.workflows.file.workflows[index].nodes.append(node)
        selectedNode = node.id
    }

    private func move(_ id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let index, let nodeIndex = controller.workflows.file.workflows[index].nodes.firstIndex(where: { $0.id == id }) else { return }
        controller.workflows.file.workflows[index].nodes[nodeIndex].x += Double(dx)
        controller.workflows.file.workflows[index].nodes[nodeIndex].y += Double(dy)
    }

    private func remove(_ id: UUID) {
        guard let index,
              let node = controller.workflows.file.workflows[index].nodes.first(where: { $0.id == id }) else { return }
        if node.kind.isTrigger && controller.workflows.file.workflows[index].nodes.filter({ $0.kind.isTrigger }).count == 1 {
            return
        }
        controller.workflows.file.workflows[index].nodes.removeAll { $0.id == id }
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

private struct WorkflowNodePicker: View {
    let kinds: [WorkflowKind]
    let select: (WorkflowKind) -> Void
    let close: () -> Void

    private func symbol(_ kind: WorkflowKind) -> String {
        switch kind {
        case .start: "play.fill"
        case .event: "bolt.fill"
        case .schedule: "clock.fill"
        case .script: "terminal"
        case .ai: "sparkles"
        case .files: "doc.badge.arrow.down"
        case .decision: "arrow.triangle.branch"
        case .end: "stop.fill"
        }
    }

    private func description(_ kind: WorkflowKind) -> String {
        switch kind {
        case .start: "Inicia el flujo manualmente desde Ejecutar."
        case .event: "Disparador por evento; por ahora se prueba manualmente."
        case .schedule: "Disparador por horario; por ahora se prueba manualmente."
        case .script: "Ejecuta un comando o script en tu proyecto."
        case .ai: "Procesa la salida anterior con Codex."
        case .files: "Guarda los archivos de una lista JSON dentro del proyecto."
        case .decision: "Compara un valor y elige entre Sí y No."
        case .end: "Marca la finalización de una rama."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agregar bloque").font(.system(size: Theme.zoom(17), weight: .semibold))
                    Text("Elegí qué hará el próximo paso del flujo.")
                        .font(.system(size: Theme.zoom(12))).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar", action: close)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(kinds, id: \.self) { kind in
                        Button { select(kind) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: symbol(kind))
                                    .font(.system(size: Theme.zoom(19), weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(kind.title).font(.system(size: Theme.zoom(13), weight: .semibold))
                                    Text(description(kind)).font(.system(size: Theme.zoom(11)))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 63, alignment: .topLeading)
                            .padding(12)
                            .background(Theme.background, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 580, height: min(450, CGFloat((kinds.count + 1) / 2) * 100 + 120))
        .background(Theme.bar)
    }
}

private struct WorkflowExecutionPanel: View {
    @Bindable var model: WorkflowController
    let flow: Workflow?
    @State private var focusedStep: UUID?

    private var focusedResult: WorkflowStepResult? {
        focusedStep.flatMap { model.results[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "text.alignleft").foregroundStyle(Theme.accent)
                Text("Ejecución").font(.system(size: Theme.zoom(11), weight: .semibold))
                if model.isRunning { ProgressView().controlSize(.mini) }
                Spacer()
                if focusedStep != nil {
                    Button("Registro completo") { focusedStep = nil }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 31)
            Divider()
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.executionOrder.enumerated()), id: \.offset) { _, id in
                            if let node = flow?.nodes.first(where: { $0.id == id }) {
                                Button { focusedStep = id } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: model.results[id]?.successful == false
                                              ? "xmark.circle.fill" : model.results[id] == nil
                                              ? "circle.dotted" : "checkmark.circle.fill")
                                            .foregroundStyle(model.results[id]?.successful == false ? Color.red : Color.green)
                                        Text(node.title).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if let result = model.results[id] {
                                            Text(result.summary).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .font(.system(size: Theme.zoom(11)))
                                    .padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(focusedStep == id ? Theme.accent.opacity(0.15) : .clear,
                                                in: RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 170, idealWidth: 230, maxWidth: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.error.isEmpty {
                            Label(model.error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                        if let focusedResult {
                            Text(focusedResult.summary).font(.system(size: Theme.zoom(11), weight: .semibold))
                            Text(focusedResult.detail).textSelection(.enabled)
                        } else {
                            Text(model.log.isEmpty ? "Todavía no se ejecutó este flujo." : model.log)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.system(size: Theme.zoom(11), design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(minWidth: 250, maxWidth: .infinity)
            }
        }
        .background(Theme.bar)
        .onChange(of: model.selectedID) { _, _ in focusedStep = nil }
    }
}

private struct WorkflowNodeCard: View {
    let node: WorkflowNode
    let selected: Bool
    let status: RunStatus?
    let result: WorkflowStepResult?
    let active: Bool

    private var color: Color {
        switch node.kind {
        case .start: return .green
        case .event: return .cyan
        case .schedule: return .indigo
        case .script: return Theme.accent
        case .ai: return .indigo
        case .files: return .teal
        case .decision: return .orange
        case .end: return .purple
        }
    }

    private var symbol: String {
        switch node.kind {
        case .start: "play.fill"
        case .event: "bolt.fill"
        case .schedule: "clock.fill"
        case .script: "terminal"
        case .ai: "sparkles"
        case .files: "doc.badge.arrow.down"
        case .decision: "arrow.triangle.branch"
        case .end: "stop.fill"
        }
    }

    private var finishColor: Color {
        guard let status else { return .purple }
        return status == .exited(0) ? .green : .red
    }

    var body: some View {
        Group {
            if node.kind.isTrigger {
                Image(systemName: symbol)
                    .font(.system(size: Theme.zoom(23), weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 60, height: 60)
                    .background(color.opacity(active ? 0.24 : 0.10), in: Circle())
                    .overlay(Circle().stroke(color.opacity(selected ? 0.95 : 0.5), lineWidth: selected ? 2 : 1))
                    .overlay(alignment: .bottom) {
                        Text(node.title)
                            .font(.system(size: Theme.zoom(10), weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .offset(y: 20)
                    }
                    .help(node.title)
            } else if node.kind == .end {
                HStack(spacing: 9) {
                    Image(systemName: status == nil ? "stop.fill" : status == .exited(0) ? "checkmark" : "xmark")
                        .font(.system(size: Theme.zoom(15), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(finishColor, in: Circle())
                    Text(node.title).font(.system(size: Theme.zoom(11), weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(width: 170, height: 54)
                .background(LinearGradient(colors: [finishColor.opacity(0.19), finishColor.opacity(0.08)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                .overlay(Capsule().stroke(finishColor.opacity(selected ? 0.95 : 0.55),
                                          lineWidth: selected ? 2 : 1))
                .shadow(color: finishColor.opacity(0.13), radius: 7, y: 3)
            } else {
                HStack(spacing: 8) {
                    if node.kind == .decision {
                        DecisionBranchIcon()
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: Theme.zoom(18), weight: .semibold))
                            .foregroundStyle(color)
                            .frame(width: 25, height: 25)
                    }
                    Text(node.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if let status {
                        Image(systemName: status == .exited(0) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(status == .exited(0) ? .green : .red)
                    }
                }
                .font(.system(size: Theme.zoom(11), weight: .medium)).padding(.horizontal, 10)
                .frame(width: node.kind == .decision ? 200 : 170, height: 54)
                .background(color.opacity(active ? 0.24 : 0.10), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(color.opacity(selected ? 0.95 : 0.5), lineWidth: selected ? 2 : 1))
            }
        }
        .overlay(alignment: .bottom) {
            if let result {
                Text(result.summary)
                    .font(.system(size: Theme.zoom(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(result.successful ? Color.green : Color.red)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.background, in: Capsule())
                    .overlay(Capsule().strokeBorder((result.successful ? Color.green : Color.red).opacity(0.65)))
                    .offset(y: node.kind.isTrigger ? 35 : 18)
                    .allowsHitTesting(false)
            } else if active {
                Text("Ejecutando…")
                    .font(.system(size: Theme.zoom(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.background, in: Capsule())
                    .offset(y: node.kind.isTrigger ? 35 : 18)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct DecisionBranchIcon: View {
    var body: some View {
        Canvas { context, _ in
            var stem = Path()
            stem.move(to: CGPoint(x: 2, y: 12.5))
            stem.addLine(to: CGPoint(x: 12, y: 12.5))
            context.stroke(stem, with: .color(.orange), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            var yes = Path()
            yes.move(to: CGPoint(x: 12, y: 12.5))
            yes.addLine(to: CGPoint(x: 20, y: 5))
            yes.addLine(to: CGPoint(x: 28, y: 5))
            context.stroke(yes, with: .color(.green), style: StrokeStyle(lineWidth: 2.5,
                                                                         lineCap: .round, lineJoin: .round))

            var no = Path()
            no.move(to: CGPoint(x: 12, y: 12.5))
            no.addLine(to: CGPoint(x: 20, y: 20))
            no.addLine(to: CGPoint(x: 28, y: 20))
            context.stroke(no, with: .color(.red), style: StrokeStyle(lineWidth: 2.5,
                                                                      lineCap: .round, lineJoin: .round))
        }
        .frame(width: 29, height: 25)
        .accessibilityLabel("Bifurcación Sí y No")
    }
}

private struct WorkflowInspector: View {
    @Binding var node: WorkflowNode
    let choices: [WorkflowNode]
    let canEdit: Bool
    let isRunning: Bool
    let rootURL: URL
    let models: [CodexModelChoice]
    let codexConnected: Bool
    let openCodex: () -> Void
    let inputJSON: String?
    let outputJSON: String?
    let branchOutcome: String?
    let result: WorkflowStepResult?
    let error: String
    let test: (String) -> Void
    let save: () -> Void
    let close: () -> Void
    @State private var manualJSON = ""

    private var resultLabel: String {
        guard let result else { return "" }
        if node.kind == .decision {
            if result.summary == "Sí" { return "Condición verdadera · Sí/A" }
            if result.summary == "No" { return "Condición falsa · No/B" }
            return "Error al evaluar la condición"
        }
        return result.successful ? "Prueba correcta · \(result.summary)" : "Prueba con error · \(result.summary)"
    }

    private var resultColor: Color {
        if result?.successful == false { return .red }
        if node.kind == .decision && result?.summary == "No" { return .orange }
        return .green
    }

    private var summary: String {
        switch node.kind {
        case .script: node.command.split(separator: "\n").first.map(String.init) ?? "Sin comando"
        case .ai: node.ai.model.isEmpty ? "Modelo automático" : node.ai.model
        case .files: "\(node.fileSettings.sourcePath) → \(node.fileSettings.destination.isEmpty ? "Proyecto" : node.fileSettings.destination)"
        case .decision: "\(node.condition.left.source == .previousExitCode ? "Código" : "Salida") · \(node.condition.operation.title)"
        case .end: "Finaliza el flujo"
        case .start: "Inicio manual"
        case .event: "Disparador por evento"
        case .schedule: "Disparador por horario"
        }
    }

    private var symbol: String {
        switch node.kind {
        case .script: "terminal"
        case .ai: "sparkles"
        case .files: "doc.badge.arrow.down"
        case .decision: "arrow.triangle.branch"
        case .end: "stop.fill"
        case .start: "play.fill"
        case .event: "bolt.fill"
        case .schedule: "clock.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: Theme.zoom(15), weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                Text(node.kind.title).font(.system(size: Theme.zoom(12), weight: .semibold))
                TextField("Nombre del bloque", text: $node.title)
                    .font(.system(size: Theme.zoom(12))).frame(maxWidth: 250).disabled(!canEdit)
                Text(summary).font(.system(size: Theme.zoom(10), design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 250, alignment: .leading)
                Spacer(minLength: 0)
                Button(isRunning ? "Detener" : "Probar nodo") { test(manualJSON) }
                    .disabled(!canEdit && !isRunning)
                if canEdit { Button("Guardar", action: save) }
                Button("Cerrar", action: close).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let result {
                Label(resultLabel, systemImage: result.successful ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: Theme.zoom(11), weight: .semibold))
                    .foregroundStyle(resultColor)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            } else if isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Ejecutando este nodo…")
                }.font(.system(size: Theme.zoom(11))).padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: Theme.zoom(11))).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            HStack(spacing: 0) {
                WorkflowJSONPane(title: node.kind.isTrigger ? "ORIGEN" : "ENTRADA",
                                 source: predecessor?.title,
                                 json: manualJSON,
                                 example: false,
                                 editableJSON: $manualJSON)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("PARÁMETROS").font(.system(size: Theme.zoom(11), weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 10)
                        Divider()
                        settings
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                WorkflowJSONPane(title: node.kind == .end ? "RESULTADO FINAL" : "SALIDA",
                                 source: node.title,
                                 json: outputJSON ?? (result == nil && error.isEmpty ? exampleOutput : "{}"),
                                 example: outputJSON == nil && result == nil && error.isEmpty,
                                 branchOutcome: node.kind == .decision && result?.successful != false
                                     ? (branchOutcome ?? "Sí") : nil,
                                 tested: outputJSON != nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let result, (node.kind == .decision || node.kind == .files || !result.successful), !result.detail.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.kind == .decision ? "Evaluación" : node.kind == .files ? "Archivos" : "Detalle del error")
                        .font(.system(size: Theme.zoom(11), weight: .semibold))
                    Text(result.detail).font(.system(size: Theme.zoom(11), design: .monospaced))
                        .textSelection(.enabled).lineLimit(node.kind == .files ? 8 : 3)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.bar)
            }
        }.textFieldStyle(.roundedBorder)
            .onAppear { manualJSON = inputJSON ?? exampleInput }
    }

    private var predecessor: WorkflowNode? {
        choices.first { $0.next == node.id || $0.no == node.id }
    }

    private var exampleInput: String {
        guard !node.kind.isTrigger else { return "{}" }
        switch predecessor?.kind {
        case .script: return WorkflowJSON.encode(["stdout": "a12b3c Mejorar editor", "stderr": "", "exitCode": 0])
        case .ai: return WorkflowJSON.encode(["text": "Notas generadas", "files": [["name": "notas.md", "content": "# Cambios", "mimeType": "text/markdown"]]])
        case .files: return WorkflowJSON.encode(["files": [["name": "notas.md", "content": "# Cambios", "mimeType": "text/markdown"]]])
        default: return WorkflowJSON.encode(["project": rootURL.lastPathComponent, "trigger": "manual"])
        }
    }

    private var exampleOutput: String {
        switch node.kind {
        case .start, .event, .schedule:
            return WorkflowJSON.encode(["project": rootURL.lastPathComponent, "trigger": node.kind.rawValue])
        case .script: return WorkflowJSON.encode(["stdout": "a12b3c Mejorar editor", "stderr": "", "exitCode": 0])
        case .ai: return WorkflowJSON.encode(["text": "Notas generadas", "files": [["name": "notas.md", "content": "# Cambios", "mimeType": "text/markdown"]]])
        case .files: return WorkflowJSON.encode(["fileResults": [["name": "notas.md", "path": "notas.md", "status": "preview"]],
                                                  "fileSummary": ["total": 1, "processed": 1, "failed": 0, "preview": true]])
        case .decision, .end: return exampleInput
        }
    }

    private var settings: some View {
                VStack(spacing: 8) {
                    switch node.kind {
                    case .script:
                        WorkflowSettingsCard(title: "Comando", symbol: "terminal") {
                            Text("Se ejecuta con zsh.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("La salida anterior está en $BRAKET_INPUT; su código en $BRAKET_PREVIOUS_EXIT_CODE.")
                                .font(.caption2).foregroundStyle(.secondary)
                            TextEditor(text: $node.command)
                                .font(.system(size: Theme.zoom(11), design: .monospaced))
                                .frame(height: 70).disabled(!canEdit)
                        }
                        WorkflowSettingsCard(title: "Ubicación", symbol: "folder") {
                            HStack(spacing: 8) {
                                TextField("Carpeta del proyecto", text: $node.settings.workingDirectory)
                                    .font(.system(size: Theme.zoom(11), design: .monospaced))
                                    .disabled(!canEdit)
                                Button("Elegir…", action: chooseWorkingDirectory).disabled(!canEdit)
                            }
                            Text("Ruta relativa al proyecto o ruta absoluta. Vacío: carpeta del proyecto.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        WorkflowSettingsCard(title: "Tiempo límite", symbol: "timer") {
                            HStack(spacing: 8) {
                                TextField("Segundos", value: $node.settings.timeoutSeconds, format: .number)
                                    .frame(width: 100).disabled(!canEdit)
                                Text("segundos · 0 = sin límite")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        WorkflowSettingsCard(title: "Variables de entorno", symbol: "curlybraces") {
                            ForEach($node.settings.environment) { $variable in
                                HStack(spacing: 8) {
                                    TextField("NOMBRE", text: $variable.name)
                                        .font(.system(size: Theme.zoom(11), design: .monospaced))
                                        .frame(maxWidth: 180)
                                    TextField("Valor", text: $variable.value)
                                        .font(.system(size: Theme.zoom(11), design: .monospaced))
                                    if canEdit {
                                        Button {
                                            node.settings.environment.removeAll { $0.id == variable.id }
                                        } label: { Image(systemName: "minus.circle") }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Quitar variable \(variable.name)")
                                    }
                                }.disabled(!canEdit)
                            }
                            if canEdit {
                                Button {
                                    node.settings.environment.append(WorkflowEnvironmentVariable())
                                } label: { Label("Variable", systemImage: "plus") }
                                    .buttonStyle(.plain)
                                    .disabled(node.settings.environment.count >= 50)
                            }
                            Text("Se guardan en el archivo del flujo, que Git puede commitear: no pongas contraseñas ni tokens.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        WorkflowSettingsCard(title: "Continuación", symbol: "arrow.right") {
                            destinationPicker("Siguiente bloque", selection: $node.next)
                        }
                    case .ai:
                        WorkflowSettingsCard(title: "Entrada", symbol: "arrow.down.doc") {
                            Text("Recibe el JSON del bloque anterior.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        WorkflowSettingsCard(title: "Prompt", symbol: "text.bubble") {
                            TextEditor(text: $node.ai.prompt)
                                .font(.system(size: Theme.zoom(11), design: .monospaced))
                                .frame(height: 95).disabled(!canEdit)
                        }
                        WorkflowSettingsCard(title: "Modelo", symbol: "sparkles") {
                            HStack(spacing: 10) {
                                Picker("Modelo", selection: $node.ai.model) {
                                    Text("Automático").tag("")
                                    ForEach(models) { model in Text(model.name).tag(model.id) }
                                    if !node.ai.model.isEmpty && !models.contains(where: { $0.id == node.ai.model }) {
                                        Text(node.ai.model).tag(node.ai.model)
                                    }
                                }.labelsHidden().frame(maxWidth: 270).disabled(!canEdit)
                                if !codexConnected {
                                    Button("Conectar Codex", action: openCodex)
                                }
                            }
                        }
                        WorkflowSettingsCard(title: "Resultado", symbol: "doc.badge.arrow.down") {
                            Text("Devuelve JSON con text y files. Cada archivo tiene name, content y mimeType; puede haber varios.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Los archivos se entregan al siguiente bloque. Este bloque no los guarda.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        WorkflowSettingsCard(title: "Continuación", symbol: "arrow.right") {
                            destinationPicker("Siguiente bloque", selection: $node.next)
                        }
                    case .files:
                        WorkflowSettingsCard(title: "Archivos de entrada", symbol: "curlybraces") {
                            TextField("Campo JSON, por ejemplo files o data.files", text: $node.fileSettings.sourcePath)
                                .font(.system(size: Theme.zoom(11), design: .monospaced)).disabled(!canEdit)
                            Text("Cada elemento necesita content; puede incluir name, mimeType y encoding (utf8 o base64).")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        WorkflowSettingsCard(title: "Ubicación", symbol: "folder") {
                            HStack(spacing: 8) {
                                TextField("Carpeta dentro del proyecto", text: $node.fileSettings.destination)
                                    .font(.system(size: Theme.zoom(11), design: .monospaced)).disabled(!canEdit)
                                Button("Elegir…", action: chooseFileDestination).disabled(!canEdit)
                            }
                            Text("Ruta relativa al proyecto. Vacío: carpeta principal.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        WorkflowSettingsCard(title: "Nombre si falta", symbol: "doc.text") {
                            TextField("archivo-{indice}.{extension}", text: $node.fileSettings.namePattern)
                                .font(.system(size: Theme.zoom(11), design: .monospaced)).disabled(!canEdit)
                            Text("Usa name si viene; si no, {indice} empieza en 1 y {extension} se obtiene de mimeType. Si existe, agrega (1), (2)…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        WorkflowSettingsCard(title: "Sin archivos", symbol: "tray") {
                            Picker("Cuando falta la lista o está vacía", selection: $node.fileSettings.emptyBehavior) {
                                ForEach(WorkflowEmptyFilesBehavior.allCases, id: \.self) { behavior in
                                    Text(behavior.title).tag(behavior)
                                }
                            }.disabled(!canEdit)
                            Text("Los errores individuales se informan en fileResults; el resto de los archivos continúa.")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("Probar nodo solo muestra rutas y resultados previstos; no escribe archivos.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        WorkflowSettingsCard(title: "Continuación", symbol: "arrow.right") {
                            destinationPicker("Siguiente bloque", selection: $node.next)
                        }
                    case .decision:
                        WorkflowSettingsCard(title: "Condición", symbol: "equal") {
                            HStack(spacing: 10) {
                                Text("Del paso anterior").font(.caption).foregroundStyle(.secondary)
                                Picker("Dato del paso anterior", selection: previousValueBinding) {
                                    Text("Campo del JSON").tag(WorkflowValueSource.jsonField)
                                    Text("Salida").tag(WorkflowValueSource.previousOutput)
                                    Text("Código de salida").tag(WorkflowValueSource.previousExitCode)
                                }.labelsHidden().frame(maxWidth: 160).disabled(!canEdit)
                                if node.condition.left.source != .previousExitCode {
                                    Text("Tipo").font(.caption).foregroundStyle(.secondary)
                                    Picker("Tipo", selection: $node.condition.valueType) {
                                        ForEach(WorkflowValueType.allCases, id: \.self) { type in
                                            Text(type.title).tag(type)
                                        }
                                    }.labelsHidden().frame(maxWidth: 90).disabled(!canEdit)
                                }
                            }
                            if node.condition.left.source == .jsonField {
                                TextField("Campo, por ejemplo stdout o data.count", text: $node.condition.left.value)
                                    .font(.system(size: Theme.zoom(11), design: .monospaced)).disabled(!canEdit)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Comparación").font(.caption).foregroundStyle(.secondary)
                                Picker("Comparación", selection: $node.condition.operation) {
                                    ForEach(WorkflowComparisonOperator.allCases, id: \.self) { operation in
                                        Text(operation.title).tag(operation)
                                    }
                                }.labelsHidden().frame(maxWidth: .infinity).disabled(!canEdit)
                                Text("con").font(.caption).foregroundStyle(.secondary)
                                Picker("Valor de referencia", selection: $node.condition.right.source) {
                                    Text("Valor fijo").tag(WorkflowValueSource.literal)
                                    Text("Variable de entorno").tag(WorkflowValueSource.environment)
                                }.labelsHidden().frame(maxWidth: .infinity).disabled(!canEdit)
                                TextField(node.condition.right.source == .environment ? "Nombre de variable" : "Valor",
                                          text: $node.condition.right.value)
                                    .font(.system(size: Theme.zoom(11), design: .monospaced)).disabled(!canEdit)
                            }
                            if node.condition.left.source == .previousOutput,
                               node.condition.valueType == .text {
                                Text("El texto se compara alfabéticamente y distingue mayúsculas.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                }
                        }
                        WorkflowSettingsCard(title: "Ramas", symbol: "arrow.triangle.branch") {
                            VStack(alignment: .leading, spacing: 8) {
                                destinationPicker("Sí · se cumple", selection: $node.next)
                                destinationPicker("No · no se cumple", selection: $node.no)
                            }
                        }
                    case .start, .event, .schedule:
                        WorkflowSettingsCard(title: "Disparador", symbol: symbol) {
                            Picker("Tipo de inicio", selection: $node.kind) {
                                Text("Manual").tag(WorkflowKind.start)
                                Text("Evento").tag(WorkflowKind.event)
                                Text("Horario").tag(WorkflowKind.schedule)
                            }.disabled(!canEdit)
                            Text(node.kind == .start ? "Inicia el flujo al pulsar Ejecutar."
                                 : "Podés probar este disparador manualmente desde el grafo.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        WorkflowSettingsCard(title: "Continuación", symbol: "arrow.right") {
                            destinationPicker("Siguiente bloque", selection: $node.next)
                        }
                    case .end:
                        WorkflowSettingsCard(title: "Finalización", symbol: "stop.fill") {
                            Text("Este bloque termina la ejecución del flujo.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(10)
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir carpeta"
        panel.directoryURL = rootURL
        guard panel.runModal() == .OK, let chosen = panel.url?.standardizedFileURL else { return }
        let rootPath = rootURL.standardizedFileURL.path
        if chosen.path == rootPath { node.settings.workingDirectory = "" }
        else if chosen.path.hasPrefix(rootPath + "/") {
            node.settings.workingDirectory = String(chosen.path.dropFirst(rootPath.count + 1))
        } else { node.settings.workingDirectory = chosen.path }
    }

    private func chooseFileDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir carpeta"
        panel.directoryURL = rootURL
        guard panel.runModal() == .OK, let chosen = panel.url?.resolvingSymlinksInPath().standardizedFileURL else { return }
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        if chosen.path == rootPath { node.fileSettings.destination = "" }
        else if chosen.path.hasPrefix(rootPath + "/") {
            node.fileSettings.destination = String(chosen.path.dropFirst(rootPath.count + 1))
        }
    }

    private var previousValueBinding: Binding<WorkflowValueSource> {
        Binding(get: { node.condition.left.source }, set: { source in
            node.condition.left.source = source
            if source == .jsonField && node.condition.left.value.isEmpty {
                node.condition.left.value = "stdout"
            }
            if source == .previousExitCode {
                node.condition.valueType = .number
                if node.condition.right.source == .literal { node.condition.right.value = "0" }
            }
        })
    }

    private func destinationPicker(_ label: String, selection: Binding<UUID?>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                Text("Sin conexión").tag(Optional<UUID>.none)
                ForEach(choices.filter { $0.id != node.id && !$0.kind.isTrigger }) { item in
                    Text(item.title).tag(Optional(item.id))
                }
            }.labelsHidden().frame(maxWidth: 220).disabled(!canEdit)
            Spacer(minLength: 0)
        }
    }
}

private struct WorkflowSettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @State private var expanded = true
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: Theme.zoom(9), weight: .semibold)).frame(width: 12)
                    Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 16)
                    Text(title).font(.system(size: Theme.zoom(11), weight: .semibold))
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).padding(10)
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 7) { content }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct WorkflowJSONPane: View {
    let title: String
    let source: String?
    let json: String
    let example: Bool
    var branchOutcome: String? = nil
    var tested = false
    var editableJSON: Binding<String>? = nil
    @State private var viewMode = 0
    @State private var branchIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: Theme.zoom(11), weight: .semibold))
                if let source { Text("· \(source)").lineLimit(1).foregroundStyle(.secondary) }
                Spacer()
            }.font(.system(size: Theme.zoom(10))).padding(12)
            Divider()
            HStack {
                Picker("Vista", selection: $viewMode) {
                    Text("JSON").tag(0)
                    Text("Árbol").tag(1)
                }.pickerStyle(.segmented).frame(width: 150)
                Spacer()
                if editableJSON != nil { Text("Entrada de prueba").font(.caption2).foregroundStyle(.secondary) }
                else if example { Text("Ejemplo").font(.caption2).foregroundStyle(.secondary) }
            }.padding(10)
            if branchOutcome != nil {
                Picker("Rama", selection: $branchIndex) {
                    Text("Sí / A").tag(0)
                    Text("No / B").tag(1)
                }.pickerStyle(.segmented).padding(.horizontal, 10).padding(.bottom, 8)
            }
            if tested && !hasBranchData {
                Label("Esta rama no recibió datos en esta prueba.", systemImage: "arrow.triangle.branch")
                    .font(.system(size: Theme.zoom(11))).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else if viewMode == 0, let editableJSON {
                TextEditor(text: editableJSON)
                    .font(.system(size: Theme.zoom(11), design: .monospaced))
                    .padding(.horizontal, 8)
            } else { GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    Group {
                        if viewMode == 0 {
                            Text(displayJSON).font(.system(size: Theme.zoom(11), design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            WorkflowJSONTree(name: "{}", value: WorkflowJSON.decode(displayJSON))
                        }
                    }
                    .frame(minWidth: geometry.size.width - 24,
                           minHeight: geometry.size.height - 12, alignment: .topLeading)
                    .padding(.horizontal, 12)
                }
            } }
        }.background(Theme.background)
            .onAppear { branchIndex = branchOutcome == "No" ? 1 : 0 }
            .onChange(of: branchOutcome) { _, newValue in
                branchIndex = newValue == "No" ? 1 : 0
            }
            .onChange(of: tested) { _, isTested in
                if isTested { branchIndex = branchOutcome == "No" ? 1 : 0 }
            }
    }

    private var hasBranchData: Bool {
        guard let branchOutcome else { return true }
        return (branchIndex == 0) == (branchOutcome == "Sí")
    }

    private var displayJSON: String {
        guard branchOutcome != nil else { return json }
        return hasBranchData ? json : "{}"
    }
}

private struct WorkflowJSONTree: View {
    let name: String
    let value: Any
    @State private var expanded = true

    var body: some View {
        Group {
            if let object = value as? [String: Any] {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(object.keys.sorted(), id: \.self) { key in
                        WorkflowJSONTree(name: key, value: object[key]!)
                            .padding(.leading, 11)
                    }
                } label: { Text("\(name)  {\(object.count)}") }
            } else if let items = value as? [Any] {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(items.indices, id: \.self) { index in
                        WorkflowJSONTree(name: "[\(index)]", value: items[index])
                            .padding(.leading, 11)
                    }
                } label: { Text("\(name)  [\(items.count)]") }
            } else {
                HStack(spacing: 8) {
                    Text(name).foregroundStyle(Theme.accent)
                    Text(leaf).foregroundStyle(.secondary).textSelection(.enabled)
                }.lineLimit(2)
            }
        }.font(.system(size: Theme.zoom(11), design: .monospaced))
    }

    private var leaf: String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return String(describing: value)
    }
}
