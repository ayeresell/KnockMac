// KnockMacTests/ActionConfigCodableTests.swift
import XCTest
@testable import KnockMac

final class ActionConfigCodableTests: XCTestCase {

    func testRunShortcutConfigRoundTrip() throws {
        let original = RunShortcutAction.Config(shortcutName: "Toggle DND")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RunShortcutAction.Config.self, from: data)
        XCTAssertEqual(decoded.shortcutName, "Toggle DND")
    }
}
