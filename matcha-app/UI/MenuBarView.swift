import Foundation
import SwiftUI

/// File overview:
/// Renders the compact operator-facing menu panel. It surfaces only the highest-signal runtime,
/// focus, and suggestion status plus conditional prompt/output previews for debugging.
///
struct MenuBarView: View {
    @ObservedObject var permissionManager: PermissionManager
    /// `@ObservedObject` listens to an external owner; the model lifetime is not owned by this view.
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var focusModel: FocusTrackingModel
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator

    /// Lays out the compact status panel and conditionally reveals debug payload previews.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 6) {
                PermissionStatusRow(
                    title: "Accessibility",
                    granted: permissionManager.accessibilityGranted
                )

                PermissionStatusRow(
                    title: "Input Monitoring",
                    granted: permissionManager.inputMonitoringGranted
                )
            }

            if !permissionManager.accessibilityGranted || !permissionManager.inputMonitoringGranted {
                permissionActions
            }

            VStack(alignment: .leading, spacing: 8) {
                CompactStatusRow(
                    title: "Runtime",
                    value: runtimeSummaryText,
                    tone: runtimeStatusColor
                )

                CompactStatusRow(
                    title: "Focus",
                    value: focusSummaryText,
                    tone: focusStatusColor
                )

                CompactStatusRow(
                    title: "Suggestion",
                    value: suggestionSummaryText,
                    tone: suggestionStatusColor
                )
            }

            if let promptPreview {
                DebugPreviewCard(title: "Prompt", text: promptPreview)
            }

            if let outputPreview {
                DebugPreviewCard(title: outputPreviewTitle, text: outputPreview)
            }

            Divider()

            Button("Quit Matcha") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: focusModel.menuBarSymbolName)
                .font(.title3)
                .foregroundStyle(focusStatusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Matcha")
                    .font(.headline)

                Text("Input \(focusModel.menuBarStatusText)")
                    .font(.subheadline)
                    .foregroundStyle(focusStatusColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var permissionActions: some View {
        HStack(spacing: 8) {
            if !permissionManager.accessibilityGranted {
                Button("Open Accessibility") {
                    permissionManager.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if !permissionManager.inputMonitoringGranted {
                Button("Open Input Monitoring") {
                    permissionManager.openInputMonitoringSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var promptPreview: String? {
        guard case .generating = suggestionCoordinator.state,
              let prompt = suggestionCoordinator.latestPromptPreview,
              !prompt.isEmpty
        else {
            return nil
        }

        return prompt
    }

    private var outputPreview: String? {
        switch suggestionCoordinator.state {
        case .ready:
            return suggestionCoordinator.latestSuggestionPreview

        case .failed:
            return suggestionCoordinator.latestRawModelOutput

        case .idle where suggestionCoordinator.latestStageMessage.localizedCaseInsensitiveContains("empty"):
            return suggestionCoordinator.latestRawModelOutput ?? suggestionCoordinator.latestSuggestionPreview

        default:
            return nil
        }
    }

    private var outputPreviewTitle: String {
        switch suggestionCoordinator.state {
        case .ready:
            return "Output"
        default:
            return "Last Output"
        }
    }

    private var runtimeSummaryText: String {
        let modelName = runtimeModel.diagnostics.modelFilePath.map { URL(fileURLWithPath: $0).lastPathComponent }

        switch runtimeModel.state {
        case .ready:
            return [modelName, "Ready"].compactMap { $0 }.joined(separator: " · ")

        case .starting:
            return "Starting runtime"

        case .loading:
            return modelName.map { "\($0) · Loading" } ?? "Loading model"

        case .failed(let message):
            return message

        case .idle:
            return modelName.map { "\($0) · Idle" } ?? "Idle"
        }
    }

    private var focusSummaryText: String {
        let appName = focusModel.snapshot.applicationName

        switch focusModel.snapshot.capability {
        case .supported:
            return "\(appName) · Supported"
        case let .blocked(reason), let .unsupported(reason):
            return "\(appName) · \(reason)"
        }
    }

    private var suggestionSummaryText: String {
        switch suggestionCoordinator.state {
        case .idle:
            return "No active suggestion"

        case let .disabled(reason), let .failed(reason):
            return reason

        case .debouncing:
            return "Waiting for typing to settle"

        case .generating:
            return "Generating"

        case .ready:
            return "Ready to accept with Tab"
        }
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
        switch suggestionCoordinator.state {
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

private struct PermissionStatusRow: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? Color.green : Color.red)
                .frame(width: 7, height: 7)

            Text("\(title): \(granted ? "Granted" : "Required")")
                .font(.caption)
                .foregroundStyle(granted ? Color.primary : Color.red)
                .lineLimit(1)
        }
    }
}

private struct CompactStatusRow: View {
    let title: String
    let value: String
    let tone: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 74, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(tone)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }
}

private struct DebugPreviewCard: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(5)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
