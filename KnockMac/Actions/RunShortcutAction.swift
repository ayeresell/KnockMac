// KnockMac/Actions/RunShortcutAction.swift
import Foundation

struct RunShortcutAction: KnockAction {
    struct Config: Codable, Equatable, Sendable {
        var shortcutName: String
    }

    let config: Config

    var subtitle: String? { config.shortcutName }

    static let descriptor = ActionDescriptor(
        id: "runShortcut",
        title: "Run Shortcut",
        systemImage: "wand.and.stars",
        requiresConfiguration: true,
        make: { data in
            guard let data else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "missing config"))
            }
            let cfg = try JSONDecoder().decode(Config.self, from: data)
            return RunShortcutAction(config: cfg)
        }
    )

    @MainActor
    func perform() {
        let process = Process()
        process.launchPath = "/usr/bin/shortcuts"
        process.arguments = ["run", config.shortcutName]
        do {
            try process.run()
        } catch {
            print("[RunShortcut] failed to run shortcut '\(config.shortcutName)': \(error)")
        }
    }

    /// Lists the names of installed shortcuts. Synchronous Process call —
    /// invoke off the main thread (e.g. inside a Task) before showing the picker.
    static func availableShortcuts() -> [String] {
        let process = Process()
        process.launchPath = "/usr/bin/shortcuts"
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } catch {
            print("[RunShortcut] failed to list shortcuts: \(error)")
            return []
        }
    }
}
