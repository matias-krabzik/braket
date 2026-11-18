import AppKit
import SwiftUI

/// Geometría compartida por los árboles AppKit y SwiftUI del explorador.
enum SidebarTreeStyle {
    static let indent: CGFloat = 18
    static let rowHeight: CGFloat = 29
    static let iconLeading: CGFloat = 30
    static let iconCenter: CGFloat = 42
    static let iconSize: CGFloat = 18

    static func disclosureSymbol(expanded: Bool) -> String { expanded ? "minus.square" : "plus.square" }

    /// Cada booleano indica si la rama correspondiente termina en este descendiente.
    static func guides(ancestors: [Bool], expanded: Bool, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let middle = height / 2
        for (level, last) in ancestors.enumerated() {
            let x = CGFloat(level) * indent + iconCenter
            let immediate = level == ancestors.count - 1
            if !last {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
            }
            if immediate {
                path.move(to: CGPoint(x: x, y: last ? 0 : middle - 4))
                path.addLine(to: CGPoint(x: x, y: middle - 4))
                path.addQuadCurve(to: CGPoint(x: x + 4, y: middle), control: CGPoint(x: x, y: middle))
                path.addLine(to: CGPoint(x: CGFloat(ancestors.count) * indent + iconLeading + 2, y: middle))
            }
        }
        if expanded {
            let x = CGFloat(ancestors.count) * indent + iconCenter
            path.move(to: CGPoint(x: x, y: middle + iconSize / 2 + 1))
            path.addLine(to: CGPoint(x: x, y: height))
        }
        return path
    }
}

final class SidebarDisclosureButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func update(expanded: Bool, name: String) {
        image = NSImage(systemSymbolName: SidebarTreeStyle.disclosureSymbol(expanded: expanded), accessibilityDescription: nil)
        let action = (expanded ? "Contraer " : "Expandir ") + name
        setAccessibilityLabel(action)
        toolTip = action
    }
}

private struct SidebarDisclosure: NSViewRepresentable {
    let name: String
    let expanded: Bool
    let toggle: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SidebarDisclosureButton {
        let button = SidebarDisclosureButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate)
        return button
    }
    func updateNSView(_ button: SidebarDisclosureButton, context: Context) {
        context.coordinator.toggle = toggle
        button.update(expanded: expanded, name: name)
    }
    final class Coordinator: NSObject {
        var toggle: (() -> Void)?
        @objc func activate() { toggle?() }
    }
}

/// Distingue los clics antes de cambiar la expansión: el primero no puede ocultar el segundo.
final class SidebarRowClickView: NSView {
    var singleClick: (() -> Void)?
    var doubleClick: (() -> Void)?
    private var pending: DispatchWorkItem?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // El menú contextual (también Control-clic) y las ayudas siguen perteneciendo a SwiftUI.
        guard let event = NSApp.currentEvent,
              [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type),
              !event.modifierFlags.contains(.control) else { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount > 1 { cancelPendingClick() }
    }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { cancelPendingClick()
        return }
        cancelPendingClick()
        if event.clickCount == 2 { doubleClick?() }
        else if event.clickCount == 1 {
            let work = DispatchWorkItem { [weak self] in self?.singleClick?() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }
    func cancelPendingClick() { pending?.cancel()
    pending = nil }
}

private struct SidebarRowClicks: NSViewRepresentable {
    let single: () -> Void
    let double: () -> Void
    func makeNSView(context: Context) -> SidebarRowClickView {
        let view = SidebarRowClickView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: SidebarRowClickView, context: Context) {
        view.singleClick = single
        view.doubleClick = double
    }
    static func dismantleNSView(_ view: SidebarRowClickView, coordinator: ()) { view.cancelPendingClick() }
}

struct SidebarTreeNode<Value>: Identifiable {
    let id: String
    let value: Value
    var children: [Self] = []
    var expandable = false
}

/// Árbol sin animaciones, con expansión estable por identificador y presentación independiente de los datos.
struct SidebarTree<Value, Content: View>: View {
    let nodes: [SidebarTreeNode<Value>]
    let name: (Value) -> String
    var menu: (Value) -> AnyView = { _ in AnyView(EmptyView()) }
    var activate: (Value) -> Bool = { _ in false }
    @ViewBuilder let content: (Value) -> Content
    @State private var expanded: Set<String> = []
    @State private var selected: String?
    private let persistenceKey: String

    init(nodes: [SidebarTreeNode<Value>], name: @escaping (Value) -> String,
         menu: @escaping (Value) -> AnyView = { _ in AnyView(EmptyView()) },
         persistenceKey: String, activate: @escaping (Value) -> Bool = { _ in false }, @ViewBuilder content: @escaping (Value) -> Content) {
        self.nodes = nodes
        self.name = name
        self.menu = menu
        self.persistenceKey = persistenceKey
        self.activate = activate
        self.content = content
        let saved = UserDefaults.standard.stringArray(forKey: persistenceKey)
        _expanded = State(initialValue: Set(saved ?? nodes.filter { $0.expandable }.map(\.id)))
    }

    private struct Row: Identifiable {
        let node: SidebarTreeNode<Value>
        let ancestors: [Bool]
        var id: String { node.id }
    }

    private func rows(_ nodes: [SidebarTreeNode<Value>], ancestors: [Bool]? = nil) -> [Row] {
        nodes.enumerated().flatMap { index, node in
            let row = Row(node: node, ancestors: ancestors.map { $0 + [index == nodes.count - 1] } ?? [])
            guard expanded.contains(node.id) else { return [row] }
            return [row] + rows(node.children, ancestors: row.ancestors)
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows(nodes)) { row in rowView(row) }
        }
        .clipped()
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func toggle(_ row: Row) {
        selected = row.id
        guard row.node.expandable || !row.node.children.isEmpty else { return }
        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
        UserDefaults.standard.set(expanded.sorted(), forKey: persistenceKey)
    }

    private func activateRow(_ row: Row) {
        selected = row.id
        if !activate(row.node.value) { toggle(row) }
    }

    private func rowView(_ row: Row) -> some View {
        let open = expanded.contains(row.id)
        let depth = CGFloat(row.ancestors.count)
        let isSelected = selected == row.id
        let leading = depth * SidebarTreeStyle.indent + SidebarTreeStyle.iconLeading
        let horizontalInset: CGFloat = 7
        return HStack(spacing: 0) {
            Color.clear.frame(width: Theme.zoom(leading))
            content(row.node.value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Theme.zoom(horizontalInset))
        }
        .frame(height: Theme.zoom(SidebarTreeStyle.rowHeight))
        .contentShape(Rectangle())
        .overlay { SidebarRowClicks(single: { toggle(row) }, double: { activateRow(row) }) }
        .contextMenu { menu(row.node.value) }
        .accessibilityAction { activateRow(row) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .background(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.14))
                    .padding(.leading, Theme.zoom(leading - horizontalInset))
                    .padding(.vertical, Theme.zoom(2))
                    .allowsHitTesting(false)
            }
        }
        .background {
            Path(SidebarTreeStyle.guides(ancestors: row.ancestors,
                                         expanded: open && !row.node.children.isEmpty,
                                         height: SidebarTreeStyle.rowHeight))
                .scale(Theme.zoom(1), anchor: .topLeading)
                .stroke(.primary.opacity(0.19), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, dash: [1, 3]))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if row.node.expandable || !row.node.children.isEmpty {
                SidebarDisclosure(name: name(row.node.value), expanded: open) {
                    toggle(row)
                }
                .frame(width: Theme.zoom(16), height: Theme.zoom(18))
                .padding(.leading, Theme.zoom(depth * SidebarTreeStyle.indent + 8))
            }
        }
    }
}
