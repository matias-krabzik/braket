import AppKit
@testable import Krabzik
import XCTest

@MainActor final class SettingsCloseTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    func testUnchangedSettingsCloseWithoutPromptAndRestoreModalPolicy() async {
        let coordinator = SettingsCloseCoordinator(), settings = window()
        let original = settings.preventsApplicationTerminationWhenModal
        defer { coordinator.detach()
        settings.orderOut(nil) }
        coordinator.choose = { XCTFail("No debe preguntar si no hay cambios")
        return .cancel }
        coordinator.attach(settings, hasChanges: { false }, save: { XCTFail() }, discard: { XCTFail() }, dismiss: { XCTFail() })
        XCTAssertFalse(settings.preventsApplicationTerminationWhenModal)
        let allowed = await coordinator.prepareToClose()
        XCTAssertTrue(allowed)
        XCTAssertFalse(settings.isVisible)
        coordinator.detach()
        XCTAssertEqual(settings.preventsApplicationTerminationWhenModal, original)
    }

    func testSaveAndDiscardResolveDraftBeforeClosing() async {
        for choice in [SettingsCloseCoordinator.Choice.save, .discard] {
            let coordinator = SettingsCloseCoordinator(), settings = window()
            var stored = 14, draft = 18
            coordinator.choose = { choice }
            coordinator.attach(settings, hasChanges: { draft != stored }, save: {
                XCTAssertTrue(settings.isVisible)
                stored = draft
            }, discard: {
                XCTAssertTrue(settings.isVisible)
                draft = stored
            }, dismiss: { XCTFail() })
            let allowed = await coordinator.prepareToClose()
            XCTAssertTrue(allowed)
            XCTAssertEqual(draft, stored)
            XCTAssertEqual(stored, choice == .save ? 18 : 14)
            XCTAssertFalse(settings.isVisible)
            coordinator.detach()
        }
    }

    func testCancelKeepsSettingsAndDraftAndAllowsRetry() async {
        let coordinator = SettingsCloseCoordinator(), settings = window()
        defer { coordinator.detach()
        settings.orderOut(nil) }
        var saved = false
        coordinator.choose = { .cancel }
        coordinator.attach(settings, hasChanges: { true }, save: { saved = true }, discard: { XCTFail() }, dismiss: { XCTFail() })
        let cancelled = await coordinator.prepareToClose()
        XCTAssertFalse(cancelled)
        XCTAssertTrue(settings.isVisible)
        XCTAssertFalse(saved)
        coordinator.choose = { .save }
        let retried = await coordinator.prepareToClose()
        XCTAssertTrue(retried)
        XCTAssertTrue(saved)
    }

    func testSheetWaitsForActualDismissalAndRejectsOverlappingClose() async {
        let coordinator = SettingsCloseCoordinator(), parent = window(), settings = window()
        defer { coordinator.detach()
        parent.orderOut(nil)
        settings.orderOut(nil) }
        parent.beginSheet(settings, completionHandler: nil)
        var requested = false, completed = false
        coordinator.attach(settings, hasChanges: { false }, save: { XCTFail() }, discard: { XCTFail() }, dismiss: {
            requested = true
        })
        let task = Task { let result = await coordinator.prepareToClose()
        completed = true
        return result }
        for _ in 0..<10 where !requested { await Task.yield() }
        XCTAssertTrue(requested)
        XCTAssertFalse(completed, "El reinicio espera el cierre real de la hoja")
        let duplicate = await coordinator.prepareToClose()
        XCTAssertFalse(duplicate)
        parent.endSheet(settings)
        let allowed = await task.value
        XCTAssertTrue(allowed)
        XCTAssertNil(settings.sheetParent)
    }

    func testWorkspaceSettingsSheetRegistersAndDismissesThroughSwiftUI() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Settings restart")
        await qa.openProject(url)
        await qa.mount()
        qa.controller.showingSettings = true
        let opened = await qa.settle(until: { qa.controller.settingsClose.window?.sheetParent != nil })
        XCTAssertTrue(opened)
        let settings = try XCTUnwrap(qa.controller.settingsClose.window)
        XCTAssertFalse(settings.preventsApplicationTerminationWhenModal)
        let closed = await qa.controller.settingsClose.prepareToClose()
        XCTAssertTrue(closed)
        XCTAssertFalse(qa.controller.showingSettings)
        XCTAssertNil(settings.sheetParent)
    }

    func testNestedConnectionEditorIsNotDiscarded() async {
        let coordinator = SettingsCloseCoordinator(), settings = window(), child = window()
        defer { settings.endSheet(child)
        coordinator.detach()
        settings.orderOut(nil)
        child.orderOut(nil) }
        settings.beginSheet(child, completionHandler: nil)
        coordinator.choose = { XCTFail()
        return .discard }
        coordinator.attach(settings, hasChanges: { true }, save: { XCTFail() }, discard: { XCTFail() }, dismiss: { XCTFail() })
        let allowed = await coordinator.prepareToClose()
        XCTAssertFalse(allowed)
        XCTAssertTrue(settings.attachedSheet === child)
    }
}
