import AppKit
import SwiftUI

/// Persiste solo los ajustes manuales: redimensionar la ventana no cambia la preferencia.
struct SidebarWidthPersistence: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        private weak var split: NSSplitView?
        private let key = "workspace.sidebarWidth"

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            var ancestor = superview
            while let view = ancestor {
                if let candidate = view as? NSSplitView, candidate.isVertical {
                    guard split !== candidate else { return }
                    NotificationCenter.default.removeObserver(self)
                    split = candidate
                    let savedWidth = UserDefaults.standard.object(forKey: key) as? Double ?? 270
                    let width = savedWidth.isFinite ? min(360, max(270, savedWidth)) : 270
                    candidate.layoutSubtreeIfNeeded()
                    candidate.setPosition(width, ofDividerAt: 0)
                    NotificationCenter.default.addObserver(self, selector: #selector(resized),
                                                           name: NSSplitView.didResizeSubviewsNotification, object: candidate)
                    return
                }
                ancestor = view.superview
            }
        }

        @objc private func resized() {
            guard let split, let width = split.subviews.first?.frame.width,
                  NSApp.currentEvent?.type == .leftMouseDragged || NSApp.currentEvent?.type == .leftMouseUp else { return }
            UserDefaults.standard.set(Double(min(360, max(270, width))), forKey: key)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
