import SwiftUI

/// A separate rail reserves space for row actions; it never covers result values.
final class SQLRelationRail: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SQLRelationButton: NSButton {
    var perform: ((NSEvent.ModifierFlags) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    override func resetCursorRects() { addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        hoverArea = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true
    needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false
    needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovering, isEnabled {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { perform?(NSApp.currentEvent?.modifierFlags ?? []) }
}

final class SQLRelationRowView: NSTableRowView {
    override var isFlipped: Bool { true }
    weak var grid: SQLGridTable?
    private var host: NSHostingView<SQLRelationCard>?
    var scale = 1.0
    func configure(record: SQLRelatedRecord?, scale: Double, theme: AppTheme,
                   open: @escaping (SQLRelatedTarget) -> Void, close: @escaping () -> Void) {
        self.scale = scale
        guard let record else { host?.removeFromSuperview()
        host = nil
        return }
        let width = max(0, (grid?.enclosingScrollView?.contentView.bounds.width ?? bounds.width) - 32)
        let card = SQLRelationCard(record: record, scale: scale, theme: theme, open: open, close: close, availableWidth: width)
        if let host { host.rootView = card }
        else {
            let host = NSHostingView(rootView: card)
            self.host = host
            addSubview(host)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let host, let clip = grid?.enclosingScrollView?.contentView else { return }
        addSubview(host, positioned: .above, relativeTo: nil)
        let width = max(0, clip.bounds.width - 32)
        if abs(host.rootView.availableWidth - width) > 0.5 {
            var card = host.rootView
            card.availableWidth = width
            host.rootView = card
        }
        host.frame = NSRect(x: clip.bounds.minX, y: 27 * scale, width: clip.bounds.width,
                            height: max(0, bounds.height - 27 * scale))
    }
}

struct SQLRelationCard: View {
    @Bindable var record: SQLRelatedRecord
    let scale: Double
    let theme: AppTheme
    let open: (SQLRelatedTarget) -> Void
    let close: () -> Void
    var availableWidth: CGFloat = .infinity

    private var layout: SQLRelationLayout { SQLRelationLayout(scale: scale, interfaceScale: Theme.settings.uiScale) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text(record.target.label).font(Theme.interfaceFont(12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { open(record.target) } label: { Label("Abrir en pestaña", systemImage: "arrow.up.forward.square") }
                    .buttonStyle(.plain).layoutPriority(1)
                        .help("Abrir la consulta del registro relacionado en una nueva pestaña · ⌘+clic en la fila")
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Cerrar detalle relacionado")
            }.font(Theme.interfaceFont(12)).padding(.horizontal, 12).frame(height: layout.headerHeight)
            Divider()
            if record.loading {
                HStack { WorkspaceProgress().controlSize(.small)
                Text("Cargando registro relacionado…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = record.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(12)
            } else if let result = record.result, !result.rows.isEmpty {
                subtable(result)
            } else {
                Text("No se encontró el registro relacionado.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 12) {
                if let elapsed = record.elapsed {
                    Label("\(Int((elapsed * 1000).rounded())) ms", systemImage: "clock")
                        .help("Duración total de la consulta relacionada, incluida la conexión y la lectura")
                } else { Text(record.loading ? "Cargando…" : "Consulta finalizada") }
                if let result = record.result {
                    Text("\(result.rows.count) " + (result.rows.count == 1 ? "registro" : "registros"))
                }
                Spacer()
                Label("Solo lectura", systemImage: "lock")
            }.font(Theme.interfaceFont(11)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: layout.footerHeight)
        }
        .font(Theme.interfaceFont(12))
        .background(Color(nsColor: EditorPalette.background(for: theme)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
        .workspaceReveal(record.loading)
        .padding(.horizontal, 16).padding(.vertical, layout.outerInset)
        .background(Color(nsColor: EditorPalette.background(for: theme)))
    }

    private func subtable(_ result: SQLResult) -> some View {
        let overflows = layout.tableWidth(result) > availableWidth + 0.5
        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(result.columns.indices, id: \.self) { index in
                        Text(result.columns[index]).font(Font(Theme.nativeCodeFont(scale: scale)).weight(.bold))
                            .frame(width: layout.columnWidth(index, result: result), height: layout.rowHeight, alignment: .leading)
                            .padding(.horizontal, 8 * scale)
                            .overlay(alignment: .trailing) { Divider() }
                    }
                }.background(Theme.bar)
                ForEach(result.rows.indices, id: \.self) { row in
                    Divider()
                    HStack(spacing: 0) {
                        ForEach(result.columns.indices, id: \.self) { column in
                            let value = column < result.rows[row].count ? result.rows[row][column] : nil
                            Text(value ?? "NULL").font(Font(Theme.nativeCodeFont(scale: scale)))
                                .foregroundStyle(value == nil ? .tertiary : .primary)
                                .lineLimit(1).textSelection(.enabled)
                                .frame(width: layout.columnWidth(column, result: result), height: layout.rowHeight, alignment: .leading)
                                .padding(.horizontal, 8 * scale)
                                .overlay(alignment: .trailing) { Divider() }
                        }
                    }.contentShape(Rectangle()).onTapGesture {
                        if NSEvent.modifierFlags.contains(.command) { open(record.target) }
                    }.help("⌘+clic: abrir este registro en una nueva pestaña")
                }
            }.padding(.bottom, overflows ? layout.scrollerSpace : 0)
        }.frame(height: layout.tableHeight(rows: result.rows.count, horizontalScroll: overflows))
    }

}

@MainActor final class SQLRelationMenuAction {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
}
