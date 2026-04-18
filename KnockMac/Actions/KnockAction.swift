// KnockMac/Actions/KnockAction.swift
import Foundation

/// One thing that fires on a confirmed double-knock.
/// Implementations are value types and may carry config as stored properties.
protocol KnockAction: Sendable {
    /// Optional secondary line for menu rendering — e.g. the chosen shortcut
    /// name or app display name. `nil` when no extra context is meaningful.
    var subtitle: String? { get }

    /// Side-effecting work. May be called on the main actor.
    @MainActor
    func perform()
}

extension KnockAction {
    var subtitle: String? { nil }
}

/// Static metadata about an action, used by the registry, picker UI, and
/// menu bar. Decoupled from the action instance so the catalog can be
/// enumerated without instantiating actions that need config.
struct ActionDescriptor: Sendable {
    let id: String
    let title: String
    let systemImage: String
    let requiresConfiguration: Bool
    /// Build an instance from the persisted config blob. May throw if the
    /// blob is malformed; the registry catches and falls back to screenshot.
    let make: @Sendable (Data?) throws -> any KnockAction
}
