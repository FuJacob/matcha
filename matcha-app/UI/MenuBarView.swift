import SwiftUI

struct MenuBarView: View {
    /// `@ObservedObject` listens to an external owner; the model lifetime is not owned by this view.
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @StateObject private var permissions = PermissionManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(.green)
                Text("Matcha")
                    .font(.headline)
            }

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(permissions.accessibilityGranted ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Accessibility: \(permissions.accessibilityGranted ? "Granted" : "Required")")
                    .font(.subheadline)
            }

            if !permissions.accessibilityGranted {
                Button("Open Accessibility Settings →") {
                    permissions.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Runtime")
                    .font(.headline)

                Text(runtimeModel.state.summary)
                    .font(.subheadline)
                    .foregroundStyle(runtimeStatusColor)

                if let health = runtimeModel.diagnostics.lastHealthStatus {
                    Text("Health: \(health)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let port = runtimeModel.diagnostics.serverPort {
                    Text("Port: \(port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let log = runtimeModel.diagnostics.recentServerLog, !log.isEmpty {
                ScrollView {
                    Text(log)
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
            }

            Divider()

            Button("Quit Matcha") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }

    private var runtimeStatusColor: Color {
        switch runtimeModel.state {
        case .ready:
            return .green
        case .failed:
            return .red
        case .starting, .loading:
            return .orange
        case .idle:
            return .secondary
        }
    }
}
