import SwiftUI

struct MenuBarView: View {
    @ObservedObject var permissionManager: PermissionManager
    /// `@ObservedObject` listens to an external owner; the model lifetime is not owned by this view.
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var focusModel: FocusTrackingModel
    @ObservedObject var suggestionModel: SuggestionDebugModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: focusModel.menuBarSymbolName)
                    .foregroundStyle(focusStatusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matcha")
                        .font(.headline)
                    Text("Input: \(focusModel.menuBarStatusText)")
                        .font(.subheadline)
                        .foregroundStyle(focusStatusColor)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(permissionManager.accessibilityGranted ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Accessibility: \(permissionManager.accessibilityGranted ? "Granted" : "Required")")
                    .font(.subheadline)
            }

            if !permissionManager.accessibilityGranted {
                Button("Open Accessibility Settings →") {
                    permissionManager.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(permissionManager.inputMonitoringGranted ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Input Monitoring: \(permissionManager.inputMonitoringGranted ? "Granted" : "Required")")
                    .font(.subheadline)
            }

            if !permissionManager.inputMonitoringGranted {
                Button("Open Input Monitoring Settings →") {
                    permissionManager.openInputMonitoringSettings()
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Focus")
                    .font(.headline)

                Text(focusModel.snapshot.applicationName)
                    .font(.subheadline)

                Text(focusModel.snapshot.capabilitySummary)
                    .font(.caption)
                    .foregroundStyle(focusStatusColor)

                if let inspection = focusModel.snapshot.inspection {
                    Text("Focused: \(inspection.focusedRoleSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Resolved: \(inspection.resolvedRoleSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !inspection.missingCapabilities.isEmpty {
                        Text("Missing: \(inspection.missingCapabilitySummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let context = focusModel.snapshot.context {
                    Text("Selection: \(context.selection.location), \(context.selection.length)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(context.textPreview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Suggestion")
                    .font(.headline)

                Text(suggestionModel.state.shortLabel)
                    .font(.subheadline)
                    .foregroundStyle(suggestionStatusColor)

                if let detail = suggestionModel.state.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Stage: \(suggestionModel.latestStageMessage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let generation = suggestionModel.latestGenerationNumber {
                    Text("Generation: \(generation)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let promptPreview = suggestionModel.latestPromptPreview, !promptPreview.isEmpty {
                    Text("Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(promptPreview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }

                if let rawOutput = suggestionModel.latestRawModelOutput, !rawOutput.isEmpty {
                    Text("Raw Output")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(rawOutput)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let preview = suggestionModel.latestSuggestionPreview, !preview.isEmpty {
                    Text("Accepted Output")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let latencyMilliseconds = suggestionModel.latestLatencyMilliseconds {
                    Text("Latency: \(latencyMilliseconds) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Quit Matcha") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 380)
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

    private var focusStatusColor: Color {
        switch focusModel.snapshot.capability {
        case .supported:
            return .green
        case .blocked:
            return .orange
        case .unsupported:
            return .red
        }
    }

    private var suggestionStatusColor: Color {
        switch suggestionModel.state {
        case .ready:
            return .green
        case .failed:
            return .red
        case .disabled, .debouncing:
            return .orange
        case .generating:
            return .blue
        case .idle:
            return .secondary
        }
    }
}
