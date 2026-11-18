import AppKit
@testable import Krabzik
import SwiftUI
import XCTest

@MainActor final class SidebarTreeInteractionTests: XCTestCase {
    func testDoubleClickActivatesTableWithoutTogglingAndSingleClickStillExpands() async throws {
        let key = "braket.sidebar.doubleClick.test." + UUID().uuidString
        UserDefaults.standard.set([String](), forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        var activations = 0
        let tree = SidebarTree(nodes: [SidebarTreeNode(id: "table", value: "customers",
                                                       children: [.init(id: "column", value: "id")], expandable: true)],
                               name: { $0 }, persistenceKey: key, activate: { _ in activations += 1
                               return true }) { Text($0) }
        let host = NSHostingView(rootView: tree.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        func click(count: Int) throws {
            func find(_ view: NSView) -> SidebarRowClickView? {
                if let row = view as? SidebarRowClickView { return row }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            let row = try XCTUnwrap(find(host))
            let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil,
                                                             eventNumber: count, clickCount: count,
                                                             pressure: type == .leftMouseDown ? 1 : 0))
                if type == .leftMouseDown { row.mouseDown(with: event) } else { row.mouseUp(with: event) }
            }
        }
        try click(count: 1)
        try await Task.sleep(for: .milliseconds(30))
        try click(count: 2)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key), [], "El doble clic no debe expandir ni contraer la tabla")
        try click(count: 1)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key), ["table"])
    }
}
