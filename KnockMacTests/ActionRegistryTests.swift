// KnockMacTests/ActionRegistryTests.swift
import XCTest
@testable import KnockMac

final class ActionRegistryTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-action-registry-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testDefaultsToScreenshotWhenKeyAbsent() {
        let defaults = makeDefaults()
        let action = ActionRegistry.current(defaults: defaults)
        XCTAssertTrue(action is ScreenshotAction)
    }

    func testFallsBackToScreenshotForUnknownID() {
        let defaults = makeDefaults()
        defaults.set("nonsense", forKey: "selectedActionID")
        let action = ActionRegistry.current(defaults: defaults)
        XCTAssertTrue(action is ScreenshotAction)
    }

    func testReturnsLockScreenForLockScreenID() {
        let defaults = makeDefaults()
        defaults.set("lockScreen", forKey: "selectedActionID")
        let action = ActionRegistry.current(defaults: defaults)
        XCTAssertTrue(action is LockScreenAction)
    }

    func testReturnsRunShortcutWithDecodedConfig() throws {
        let defaults = makeDefaults()
        defaults.set("runShortcut", forKey: "selectedActionID")
        let cfg = RunShortcutAction.Config(shortcutName: "Toggle DND")
        defaults.set(try JSONEncoder().encode(cfg), forKey: "selectedActionConfig")

        let action = ActionRegistry.current(defaults: defaults)
        guard let shortcut = action as? RunShortcutAction else {
            XCTFail("expected RunShortcutAction, got \(type(of: action))")
            return
        }
        XCTAssertEqual(shortcut.config.shortcutName, "Toggle DND")
    }

    func testReturnsOpenItemWithDecodedConfig() throws {
        let defaults = makeDefaults()
        defaults.set("openItem", forKey: "selectedActionID")
        let cfg = OpenItemAction.Config(kind: .app, value: "com.apple.Calculator")
        defaults.set(try JSONEncoder().encode(cfg), forKey: "selectedActionConfig")

        let action = ActionRegistry.current(defaults: defaults)
        guard let open = action as? OpenItemAction else {
            XCTFail("expected OpenItemAction, got \(type(of: action))")
            return
        }
        XCTAssertEqual(open.config.kind, .app)
        XCTAssertEqual(open.config.value, "com.apple.Calculator")
    }

    func testFallsBackToScreenshotWhenConfigMalformed() {
        let defaults = makeDefaults()
        defaults.set("runShortcut", forKey: "selectedActionID")
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "selectedActionConfig")
        let action = ActionRegistry.current(defaults: defaults)
        XCTAssertTrue(action is ScreenshotAction, "malformed config should not brick the trigger")
    }

    func testCatalogContainsAllExpectedActions() {
        let ids = ActionRegistry.all.map(\.id)
        XCTAssertEqual(ids, ["screenshot", "lockScreen", "switchKeyboardLayout", "runShortcut", "openItem"])
    }

    func testReturnsSwitchKeyboardLayoutForID() {
        let defaults = makeDefaults()
        defaults.set("switchKeyboardLayout", forKey: "selectedActionID")
        let action = ActionRegistry.current(defaults: defaults)
        XCTAssertTrue(action is SwitchKeyboardLayoutAction)
    }
}
