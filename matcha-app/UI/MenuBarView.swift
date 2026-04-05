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

                if let backendName = runtimeModel.diagnostics.backendName {
                    Text("Backend: \(backendName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let status = runtimeModel.diagnostics.lastLoadStatus {
                    Text("Status: \(status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let contextWindow = runtimeModel.diagnostics.contextWindowTokens {
                    Text("Context: \(contextWindow) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let batchSize = runtimeModel.diagnostics.batchSize {
                    Text("Batch: \(batchSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let threadCount = runtimeModel.diagnostics.threadCount {
                    Text("Threads: \(threadCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let lastError = runtimeModel.diagnostics.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
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

                if let requestPreview = suggestionModel.latestRequestPreview, !requestPreview.isEmpty {
                    Text("Request")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(requestPreview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Overlay")
                    .font(.headline)

                Text(suggestionModel.overlayState.shortLabel)
                    .font(.subheadline)
                    .foregroundStyle(overlayStatusColor)

                Text(suggestionModel.latestOverlayMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let visibleText = suggestionModel.overlayState.visibleText, !visibleText.isEmpty {
                    Text("Visible Text")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(visibleText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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

    private var overlayStatusColor: Color {
        switch suggestionModel.overlayState {
        case .visible:
            return .green
        case .hidden:
            return .secondary
        }
    }
}
