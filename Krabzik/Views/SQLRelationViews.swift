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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
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
        let card = SQLRelationCard(record: record, scale: scale, theme: theme, open: open, close: close)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text(record.target.label).font(Theme.interfaceFont(12)).foregroundStyle(.secondary).lineLimit(1)
                if let result = record
                    .result {
                    Text("\(result.rows.count) " + (result.rows.count == 1 ? "registro" : "registros")).foregroundStyle(.secondary) }
                Spacer()
                Button { open(record.target) } label: { Label("Abrir en pestaña", systemImage: "arrow.up.forward.square") }
                    .buttonStyle(.plain).layoutPriority(1)
                        .help("Abrir la consulta del registro relacionado en una nueva pestaña · ⌘+clic en la fila")
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Cerrar detalle relacionado")
            }.font(Theme.interfaceFont(12)).padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if record.loading {
                HStack { ProgressView().controlSize(.small)
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
        }
        .font(Theme.interfaceFont(12))
        .background(Color(nsColor: EditorPalette.background(for: theme)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(nsColor: EditorPalette.background(for: theme)))
    }

    private func subtable(_ result: SQLResult) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(result.columns.indices, id: \.self) { index in
                        Text(result.columns[index]).font(Font(Theme.nativeCodeFont(scale: scale)).weight(.bold))
                            .frame(width: width(index, result: result), alignment: .leading).padding(8)
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
                                .frame(width: width(column, result: result), alignment: .leading).padding(8)
                                .overlay(alignment: .trailing) { Divider() }
                        }
                    }.contentShape(Rectangle()).onTapGesture {
                        if NSEvent.modifierFlags.contains(.command) { open(record.target) }
                    }.help("⌘+clic: abrir este registro en una nueva pestaña")
                }
            }
        }
    }
    private func width(_ column: Int, result: SQLResult) -> CGFloat {
        let font = Theme.nativeCodeFont(scale: scale)
        let content = ([result.columns[column]] + result.rows.prefix(10).map { column < $0.count ? $0[column] ?? "NULL" : "" })
        return min(320 * scale, max(100 * scale, content.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0))
    }
}

@MainActor final class SQLRelationMenuAction {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
}
