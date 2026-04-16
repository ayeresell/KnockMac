import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: KnockController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("KnockMac")
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            Button("Recalibrate…") {
                OnboardingWindowManager.shared.resetAndShow()
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
}
