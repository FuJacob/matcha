import AppKit
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
    let welcomeCoordinator: WelcomeCoordinator

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

                if runtimeModel.availableModels.isEmpty {
                    CompactStatusRow(
                        title: "Model",
                        value: "No bundled GGUF models found",
                        tone: .secondary
                    )
                } else {
                    ModelPickerRow(
                        title: "Model",
                        selection: selectedModelBinding,
                        models: runtimeModel.availableModels,
                        isDisabled: runtimePickerDisabled
                    )
                }

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

                if let acceptanceSummary {
                    CompactStatusRow(
                        title: "Accept",
                        value: acceptanceSummary,
                        tone: .secondary
                    )
                }
            }

            if let promptPreview {
                DebugPreviewCard(title: "Prompt", text: promptPreview)
            }

            if let fullSuggestionPreview {
                DebugPreviewCard(title: "Full Suggestion", text: fullSuggestionPreview)
            }

            if let outputPreview {
                DebugPreviewCard(title: outputPreviewTitle, text: outputPreview)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Show Welcome") {
                    welcomeCoordinator.showWelcome()
                }
                .controlSize(.small)

                Spacer(minLength: 0)

                Button("Quit Matcha") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
                .controlSize(.small)
            }
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
            return suggestionCoordinator.latestRemainingSuggestionPreview ?? suggestionCoordinator.latestSuggestionPreview

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
            return "Remaining Tail"
        default:
            return "Last Output"
        }
    }

    private var fullSuggestionPreview: String? {
        guard case .ready = suggestionCoordinator.state,
              let fullSuggestion = suggestionCoordinator.latestFullSuggestionPreview,
              !fullSuggestion.isEmpty
        else {
            return nil
        }

        let remainingSuggestion = suggestionCoordinator.latestRemainingSuggestionPreview ?? suggestionCoordinator.latestSuggestionPreview
        if remainingSuggestion == fullSuggestion {
            return nil
        }

        return fullSuggestion
    }

    private var runtimeSummaryText: String {
        let modelName = runtimeModel.selectedModelFilename
            ?? runtimeModel.diagnostics.modelFilePath.map { URL(fileURLWithPath: $0).lastPathComponent }

        switch runtimeModel.state {
        case .ready:
            return [modelName, "Ready"].compactMap { $0 }.joined(separator: " · ")

        case .starting:
            return modelName.map { "\($0) · Starting" } ?? "Starting runtime"

        case .loading:
            return modelName.map { "\($0) · Loading" } ?? "Loading model"

        case .failed(let message):
            return modelName.map { "\($0) · \(message)" } ?? message

        case .idle:
            return modelName.map { "\($0) · Idle" } ?? "Idle"
        }
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                runtimeModel.selectedModelFilename
                    ?? runtimeModel.availableModels.first?.filename
                    ?? ""
            },
            set: { filename in
                Task {
                    await runtimeModel.selectModel(filename)
                }
            }
        )
    }

    private var runtimePickerDisabled: Bool {
        switch runtimeModel.state {
        case .starting, .loading:
            return true
        case .idle, .ready, .failed:
            return false
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
            let accepted = suggestionCoordinator.latestAcceptedCharacterCount ?? 0
            let remaining = suggestionCoordinator.latestRemainingCharacterCount ?? 0
            return "Ready · \(accepted) accepted · \(remaining) remaining"
        }
    }

    private var acceptanceSummary: String? {
        if case .ready = suggestionCoordinator.state {
            return suggestionCoordinator.latestAcceptanceAction
        }

        guard let latestAcceptanceAction = suggestionCoordinator.latestAcceptanceAction,
              !latestAcceptanceAction.isEmpty
        else {
            return nil
        }

        let stageMessage = suggestionCoordinator.latestStageMessage
        if stageMessage.localizedCaseInsensitiveContains("accepted")
            || stageMessage.localizedCaseInsensitiveContains("typed")
            || stageMessage.localizedCaseInsensitiveContains("consumed") {
            return latestAcceptanceAction
        }

        return nil
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

private struct ModelPickerRow: View {
    let title: String
    let selection: Binding<String>
    let models: [RuntimeModelOption]
    let isDisabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 74, alignment: .leading)

            Picker(title, selection: selection) {
                ForEach(models) { model in
                    Text(model.displayName)
                        .tag(model.filename)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(isDisabled)

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
