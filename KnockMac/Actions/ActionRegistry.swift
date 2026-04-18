// KnockMac/Actions/ActionRegistry.swift
import Foundation

enum ActionRegistry {

    /// Stable catalog. Order is the order shown in the picker UI.
    static let all: [ActionDescriptor] = [
        ScreenshotAction.descriptor,
        LockScreenAction.descriptor,
        RunShortcutAction.descriptor,
        OpenItemAction.descriptor,
    ]

    static let defaultActionID = "screenshot"
    static let selectedActionIDKey = "selectedActionID"
    static let selectedActionConfigKey = "selectedActionConfig"

    /// Returns the user's currently selected action.
    /// Falls back to `ScreenshotAction` if the stored ID is unknown or
    /// the config blob is malformed — defensive so a corrupted preference
    /// can never disable the trigger entirely.
    static func current(defaults: UserDefaults = .standard) -> any KnockAction {
        let id = defaults.string(forKey: selectedActionIDKey) ?? defaultActionID
        guard let descriptor = all.first(where: { $0.id == id }) else {
            return ScreenshotAction()
        }
        let configData = defaults.data(forKey: selectedActionConfigKey)
        do {
            return try descriptor.make(configData)
        } catch {
            print("[ActionRegistry] failed to instantiate \(id): \(error) — falling back to screenshot")
            return ScreenshotAction()
        }
    }

    static func descriptor(forID id: String) -> ActionDescriptor? {
        all.first(where: { $0.id == id })
    }
}
