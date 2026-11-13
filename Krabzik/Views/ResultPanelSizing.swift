import SwiftUI

/// A persistent divider gives results a useful initial size without AppKit resetting it to the minimum.
struct WorkspaceVerticalSplit<Top: View, Bottom: View>: View {
    let showsBottom: Bool
    let isResults: Bool
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom
    @State private var fraction = 0.42
    @State private var initialDrag: Double?
    private var key: String { isResults ? "workspace.resultsFraction" : "workspace.processFraction" }

    var body: some View {
        GeometryReader { geometry in
            if showsBottom {
                let height = geometry.size.height
                let minimum = min(isResults ? 220.0 : 150.0, height * 0.45)
                let bottomHeight = min(max(minimum, height * fraction), max(minimum, height - 185))
                VStack(spacing: 0) {
                    top().frame(height: max(0, height - bottomHeight - 5))
                    Rectangle().fill(Theme.border).frame(height: 5)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if initialDrag == nil { initialDrag = bottomHeight }
                            let desired = (initialDrag ?? bottomHeight) - value.translation.height
                            fraction = min(max(minimum / max(1, height), desired / max(1, height)), 0.8)
                        }.onEnded { _ in
                            initialDrag = nil
                            UserDefaults.standard.set(fraction, forKey: key)
                        })
                        .accessibilityLabel("Altura de resultados")
                        .accessibilityAdjustableAction { direction in
                            fraction = min(0.8, max(0.2, fraction + (direction == .increment ? 0.05 : -0.05)))
                            UserDefaults.standard.set(fraction, forKey: key)
                        }
                    bottom().frame(height: bottomHeight)
                }
            } else { top() }
        }
        .onAppear { restore() }
        .onChange(of: isResults) { _, _ in restore() }
    }
    private func restore() {
        let saved = UserDefaults.standard.object(forKey: key) as? Double ?? (isResults ? 0.42 : 0.25)
        fraction = saved.isFinite ? min(0.8, max(0.2, saved)) : 0.42
    }
}
