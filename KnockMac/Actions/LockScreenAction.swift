// KnockMac/Actions/LockScreenAction.swift
import Foundation

struct LockScreenAction: KnockAction {
    static let descriptor = ActionDescriptor(
        id: "lockScreen",
        title: "Lock / Sleep Display",
        systemImage: "lock.display",
        requiresConfiguration: false,
        make: { _ in LockScreenAction() }
    )

    @MainActor
    func perform() {
        let process = Process()
        process.launchPath = "/usr/bin/pmset"
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
        } catch {
            print("[LockScreen] failed to run pmset: \(error)")
        }
    }
}
