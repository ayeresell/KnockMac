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

    func testOpenItemConfigAppRoundTrip() throws {
        let original = OpenItemAction.Config(kind: .app, value: "com.apple.Calculator")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenItemAction.Config.self, from: data)
        XCTAssertEqual(decoded.kind, .app)
        XCTAssertEqual(decoded.value, "com.apple.Calculator")
    }

    func testOpenItemConfigURLRoundTrip() throws {
        let original = OpenItemAction.Config(kind: .url, value: "https://anthropic.com")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenItemAction.Config.self, from: data)
        XCTAssertEqual(decoded.kind, .url)
        XCTAssertEqual(decoded.value, "https://anthropic.com")
    }
}
