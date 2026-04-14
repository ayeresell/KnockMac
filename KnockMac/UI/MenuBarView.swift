import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(appState.isActive ? .green : .secondary)
                Text("KnockMac")
                    .fontWeight(.semibold)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.isActive },
                    set: { _ in appState.toggle() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Status
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if let t = appState.lastKnockTime {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Screenshot at \(t.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            }

            Divider()

            // Action hint
            Text("Double-knock → screenshot")
                .font(.caption)
                .foregroundStyle(.tertiary)
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

    private var statusColor: Color {
        if !appState.sensorAvailable { return .orange }
        return appState.isActive ? .green : .gray
    }

    private var statusText: String {
        if !appState.sensorAvailable { return "Sensor not found" }
        return appState.isActive ? "Listening for knocks" : "Paused"
    }
}
