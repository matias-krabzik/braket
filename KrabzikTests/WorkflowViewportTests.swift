@testable import Krabzik
import AppKit
import SwiftUI
import XCTest

@MainActor final class WorkflowViewportTests: XCTestCase {
    func testMouseTrackingKeepsExactPositionAtReleaseAndNextDrag() throws {
        let viewport = WorkflowNativeViewport(content: Text("Node"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = viewport
        viewport.layoutSubtreeIfNeeded()
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: viewport.convert(point, to: nil),
                                            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        viewport.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        for step in 1...200 {
            viewport.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100 + step, y: 100 + step)))
        }
        XCTAssertEqual(viewport.pan, CGPoint(x: 200, y: 200))
        XCTAssertEqual(viewport.host.frame.origin, viewport.pan)
        viewport.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 300, y: 300)))
        XCTAssertEqual(viewport.pan, CGPoint(x: 200, y: 200))
        viewport.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 300, y: 300)))
        viewport.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100, y: 100)))
        viewport.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100, y: 100)))
        XCTAssertEqual(viewport.pan, .zero)
        viewport.layout()
        XCTAssertEqual(viewport.host.frame.origin, .zero)
    }

    func testPanningDoesNotBecomeABackgroundClick() throws {
        let viewport = WorkflowNativeViewport(content: EmptyView())
        var clicks = 0
        viewport.clearConnection = { clicks += 1 }
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                                  modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 80, y: 30),
                                                  modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        viewport.mouseDown(with: down)
        viewport.mouseDragged(with: drag)
        viewport.mouseUp(with: drag)
        XCTAssertEqual(clicks, 0)
        viewport.mouseDown(with: down)
        viewport.mouseUp(with: down)
        XCTAssertEqual(clicks, 1)
    }
}
