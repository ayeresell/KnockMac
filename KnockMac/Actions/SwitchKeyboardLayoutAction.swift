// KnockMac/Actions/SwitchKeyboardLayoutAction.swift
import Foundation
import Carbon.HIToolbox

struct SwitchKeyboardLayoutAction: KnockAction {
    static let descriptor = ActionDescriptor(
        id: "switchKeyboardLayout",
        title: "Switch Keyboard Layout",
        systemImage: "keyboard",
        requiresConfiguration: false,
        make: { _ in SwitchKeyboardLayoutAction() }
    )

    @MainActor
    func perform() {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            print("[SwitchKeyboardLayout] failed to list input sources")
            return
        }

        // Keep only enabled, selectable keyboard layouts — excludes emoji picker,
        // input methods (IMEs) stay in the list only if the user has enabled them
        // as selectable keyboard inputs.
        let layouts = sources.filter { src in
            guard let enabledPtr  = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled),
                  let selectPtr   = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable),
                  let categoryPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory) else {
                return false
            }
            let enabled    = Unmanaged<CFBoolean>.fromOpaque(enabledPtr).takeUnretainedValue()
            let selectable = Unmanaged<CFBoolean>.fromOpaque(selectPtr).takeUnretainedValue()
            let category   = Unmanaged<CFString>.fromOpaque(categoryPtr).takeUnretainedValue() as String
            return CFBooleanGetValue(enabled)
                && CFBooleanGetValue(selectable)
                && category == (kTISCategoryKeyboardInputSource as String)
        }

        guard layouts.count >= 2 else {
            print("[SwitchKeyboardLayout] need ≥2 enabled layouts, got \(layouts.count)")
            return
        }

        guard let currentUnmanaged = TISCopyCurrentKeyboardInputSource() else {
            print("[SwitchKeyboardLayout] no current keyboard input source")
            return
        }
        let current = currentUnmanaged.takeRetainedValue()
        let currentID = Self.inputSourceID(current)

        let currentIndex = layouts.firstIndex { Self.inputSourceID($0) == currentID } ?? -1
        let nextIndex = (currentIndex + 1) % layouts.count
        let next = layouts[nextIndex]

        let status = TISSelectInputSource(next)
        if status != noErr {
            print("[SwitchKeyboardLayout] TISSelectInputSource failed: \(status)")
        }
    }

    private static func inputSourceID(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
