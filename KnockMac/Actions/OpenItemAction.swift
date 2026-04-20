// KnockMac/Actions/OpenItemAction.swift
import Foundation
import AppKit

struct OpenItemAction: KnockAction {
    enum Kind: String, Codable, Sendable { case app, url }

    struct Config: Codable, Equatable, Sendable {
        var kind: Kind
        /// Bundle identifier for `.app`, absolute URL string for `.url`.
        var value: String
    }

    let config: Config

    var subtitle: String? {
        switch config.kind {
        case .app:
            // Resolve a friendlier display name from the bundle URL when available.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.value) {
                return FileManager.default.displayName(atPath: url.path)
            }
            return config.value
        case .url:
            return config.value
        }
    }

    static let descriptor = ActionDescriptor(
        id: "openItem",
        title: "Open App / URL",
        systemImage: "arrow.up.right.square",
        requiresConfiguration: true,
        make: { data in
            guard let data else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "missing config"))
            }
            let cfg = try JSONDecoder().decode(Config.self, from: data)
            return OpenItemAction(config: cfg)
        }
    )

    @MainActor
    func perform() {
        switch config.kind {
        case .app:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.value) else {
                print("[OpenItem] no app for bundle id '\(config.value)'")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .url:
            guard let url = URL(string: config.value) else {
                print("[OpenItem] invalid url '\(config.value)'")
                return
            }
            NSWorkspace.shared.open(url)
        }
    }
}
