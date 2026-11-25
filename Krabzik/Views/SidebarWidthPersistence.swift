import AppKit
import SwiftUI

/// Persiste solo los ajustes manuales: redimensionar la ventana no cambia la preferencia.
struct SidebarWidthPersistence: NSViewRepresentable {
    let databases: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.databases = databases
        return probe
    }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        private weak var split: NSSplitView?
        var databases = false
        private var key: String { databases ? "workspace.databaseSidebarWidth" : "workspace.sidebarWidth" }
        private var defaultWidth: CGFloat { databases ? 380 : 270 }

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
                    candidate.keepDividersBelowHeader()
                    let savedWidth = UserDefaults.standard.object(forKey: key) as? Double ?? defaultWidth
                    let width = savedWidth.isFinite ? min(420, max(230, savedWidth)) : defaultWidth
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
            UserDefaults.standard.set(Double(min(420, max(230, width))), forKey: key)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// Give the trailing process panel its preferred width after AppKit distributes the split's initial space.
struct ProcessPanelInitialWidth: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.applyWidth() }
        }
        private func applyWidth() {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count > 1 {
                    split.keepDividersBelowHeader()
                    split.layoutSubtreeIfNeeded()
                    let divider = split.arrangedSubviews.count - 2
                    split.setPosition(max(0, split.bounds.width - 700 - split.dividerThickness), ofDividerAt: divider)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private extension NSSplitView {
    /// Keep AppKit from extending sidebar and inspector dividers into the shared toolbar.
    func keepDividersBelowHeader() {
        guard let controller = delegate as? NSSplitViewController else { return }
        for item in controller.splitViewItems { item.allowsFullHeightLayout = false }
    }
}
