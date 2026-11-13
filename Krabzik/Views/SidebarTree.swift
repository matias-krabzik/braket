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
    var activate: (Value) -> Void = { _ in }
    @ViewBuilder let content: (Value) -> Content
    @State private var expanded: Set<String> = []
    @State private var selected: String?

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

    private func rowView(_ row: Row) -> some View {
        let open = expanded.contains(row.id)
        let depth = CGFloat(row.ancestors.count)
        return HStack(spacing: 0) {
            Color.clear.frame(width: Theme.zoom(depth * SidebarTreeStyle.indent + SidebarTreeStyle.iconLeading))
            content(row.node.value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Theme.zoom(SidebarTreeStyle.rowHeight))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selected = row.id
            activate(row.node.value)
        }
        .onTapGesture { selected = row.id }
        .accessibilityAddTraits(selected == row.id ? .isSelected : [])
        .background(alignment: .leading) {
            if selected == row.id {
                RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.14))
                    .padding(.leading, Theme.zoom(depth * SidebarTreeStyle.indent + SidebarTreeStyle.iconLeading))
                    .padding(.trailing, Theme.zoom(8)).padding(.vertical, Theme.zoom(2))
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
                    selected = row.id
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if open { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    }
                }
                .frame(width: Theme.zoom(16), height: Theme.zoom(18))
                .padding(.leading, Theme.zoom(depth * SidebarTreeStyle.indent + 8))
            }
        }
    }
}
