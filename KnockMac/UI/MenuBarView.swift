import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: KnockController
    @AppStorage(ActionRegistry.selectedActionIDKey)
    private var selectedActionID: String = ActionRegistry.defaultActionID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("KnockMac")
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            actionMenu

            Divider()

            Button("Settings…") {
                OnboardingWindowManager.shared.showSettings()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 240)
    }

    private var actionMenu: some View {
        Menu {
            ForEach(ActionRegistry.all, id: \.id) { descriptor in
                Button {
                    selectAction(descriptor)
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                            .opacity(selectedActionID == descriptor.id ? 1 : 0)
                        Text(menuLabel(for: descriptor))
                    }
                }
                .disabled(descriptor.requiresConfiguration && !isConfigured(descriptor))
            }
            Divider()
            Button("Configure…") {
                OnboardingWindowManager.shared.showSettings(startAtStep: 3)
            }
        } label: {
            Text("Action: \(currentActionLabel)")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var currentActionLabel: String {
        guard let descriptor = ActionRegistry.descriptor(forID: selectedActionID) else {
            return "Screenshot"
        }
        let action = ActionRegistry.current()
        if let subtitle = action.subtitle {
            return "\(descriptor.title): \(subtitle)"
        }
        return descriptor.title
    }

    private func menuLabel(for descriptor: ActionDescriptor) -> String {
        if selectedActionID == descriptor.id {
            let action = ActionRegistry.current()
            if let subtitle = action.subtitle {
                return "\(descriptor.title): \(subtitle)"
            }
        }
        return descriptor.title
    }

    private func isConfigured(_ descriptor: ActionDescriptor) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: ActionRegistry.selectedActionConfigKey) else {
            return false
        }
        // Only the *currently selected* action's config is stored; for others
        // we have no per-action persistence in v1, so they read as unconfigured
        // until the user re-runs the picker.
        return descriptor.id == selectedActionID && (try? descriptor.make(data)) != nil
    }

    private func selectAction(_ descriptor: ActionDescriptor) {
        if descriptor.requiresConfiguration && !isConfigured(descriptor) {
            OnboardingWindowManager.shared.showSettings(startAtStep: 3)
            return
        }
        selectedActionID = descriptor.id
        NotificationCenter.default.post(name: NSNotification.Name("ActionChanged"), object: nil)
    }
}
