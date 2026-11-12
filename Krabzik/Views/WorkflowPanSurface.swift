import AppKit
import SwiftUI

struct WorkflowConnectionDrawing {
    let path: Path
    let color: Color
    let opacity: Double
    let lineWidth: CGFloat
}

/// AppKit owns mouse tracking. A pan changes one hosting-view origin without
/// publishing SwiftUI state or reconstructing the editor at mouse-event frequency.
struct WorkflowPanSurface<Content: View>: NSViewRepresentable {
    let zoom: CGFloat
    let interactionRects: [CGRect]
    let connections: [WorkflowConnectionDrawing]
    let clearConnection: () -> Void
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> WorkflowNativeViewport<Content> {
        WorkflowNativeViewport(content: content)
    }

    func updateNSView(_ view: WorkflowNativeViewport<Content>, context: Context) {
        view.host.rootView = content
        view.zoom = zoom
        view.interactionRects = interactionRects
        view.connections = connections
        view.clearConnection = clearConnection
        view.needsDisplay = true
    }
}

final class WorkflowNativeViewport<Content: View>: NSView {
    let host: NSHostingView<Content>
    var zoom: CGFloat = 1
    var interactionRects: [CGRect] = []
    var connections: [WorkflowConnectionDrawing] = []
    var clearConnection: () -> Void = {}
    private(set) var pan = CGPoint.zero
    private var dragStart: CGPoint?
    private var initialPan = CGPoint.zero
    private var didDrag = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(content: Content) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        host.clipsToBounds = false
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        host.frame = CGRect(origin: pan, size: bounds.size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let graphPoint = CGPoint(x: local.x - pan.x, y: local.y - pan.y)
        if interactionRects.contains(where: { $0.contains(graphPoint) }) {
            return super.hitTest(point) ?? self
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        initialPan = pan
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
        guard didDrag || hypot(delta.x, delta.y) >= 3 else { return }
        didDrag = true
        setPan(CGPoint(x: initialPan.x + delta.x, y: initialPan.y + delta.y))
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { clearConnection() }
        dragStart = nil
    }

    override func scrollWheel(with event: NSEvent) {
        setPan(CGPoint(x: pan.x + event.scrollingDeltaX, y: pan.y + event.scrollingDeltaY))
    }

    func setPan(_ point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pan = point
        host.setFrameOrigin(point)
        needsDisplay = true
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let step = 24 * zoom
        let xOffset = (bounds.width / 2 + pan.x - 550 * zoom).truncatingRemainder(dividingBy: step)
        let yOffset = (bounds.height / 2 + pan.y - 200 * zoom).truncatingRemainder(dividingBy: step)
        context.setFillColor(NSColor(Theme.accent).withAlphaComponent(0.2).cgColor)
        for x in stride(from: xOffset, through: bounds.width, by: step) {
            for y in stride(from: yOffset, through: bounds.height, by: step) {
                context.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        context.fillPath()
        context.saveGState()
        context.translateBy(x: pan.x, y: pan.y)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for connection in connections {
            context.addPath(connection.path.cgPath)
            context.setStrokeColor(NSColor(connection.color).withAlphaComponent(connection.opacity).cgColor)
            context.setLineWidth(connection.lineWidth)
            context.strokePath()
        }
        context.restoreGState()
    }
}
