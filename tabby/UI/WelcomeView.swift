import SwiftUI

/// File overview:
/// Renders the first-run welcome wizard as a multi-step flow.
///
/// Each step has a single purpose: welcome → permissions → engine choice → model download → done.
/// The "Continue" button on permission and model steps is gated on actual readiness so users
/// can't advance into a broken state. The view does not own persistence or window lifecycle;
/// those behaviors live in `WelcomeCoordinator`.
struct WelcomeView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService

    let onDismiss: () -> Void

    @State private var step: WelcomeStep = .welcome

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            switch step {
            case .welcome:
                welcomeStep
            case .permissions:
                permissionsStep
            case .chooseEngine:
                chooseEngineStep
            case .downloadModel:
                downloadModelStep
            case .done:
                doneStep
            }

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: step)
    }
}

// MARK: - Step Definitions

private enum WelcomeStep: Int, Comparable {
    case welcome
    case permissions
    case chooseEngine
    case downloadModel
    case done

    static func < (lhs: WelcomeStep, rhs: WelcomeStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Step 1: Welcome

private extension WelcomeView {
    var welcomeStep: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.06))

                Image(systemName: "pawprint.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 56, height: 56)

            VStack(spacing: 8) {
                Text("Welcome to Tabby")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("AI autocomplete for any macOS text field.\nType normally. Press Tab to accept.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Everything runs on your Mac.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)

            WelcomeButton(title: "Get Started") {
                step = .permissions
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Step 2: Permissions

private extension WelcomeView {
    var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            WelcomeStepHeader(
                title: "Grant Permissions",
                subtitle: "Tabby needs access to read what you're typing and where your cursor is."
            )

            VStack(spacing: 0) {
                WelcomePermissionRow(
                    title: "Accessibility",
                    subtitle: "Read focused field and caret position.",
                    granted: permissionManager.accessibilityGranted,
                    action: { permissionManager.openAccessibilitySettings() }
                )

                Divider().padding(.leading, 36)

                WelcomePermissionRow(
                    title: "Input Monitoring",
                    subtitle: "Capture typing and Tab acceptance.",
                    granted: permissionManager.inputMonitoringGranted,
                    action: { permissionManager.openInputMonitoringSettings() }
                )

                Divider().padding(.leading, 36)

                WelcomePermissionRow(
                    title: "Screen Recording",
                    subtitle: "Optional. Enables visual context for better suggestions.",
                    granted: permissionManager.screenRecordingGranted,
                    action: { permissionManager.openScreenRecordingSettings() },
                    isOptional: true
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )

            WelcomeNavigation(
                canGoBack: true,
                canContinue: requiredPermissionsGranted,
                disabledHint: "Grant Accessibility and Input Monitoring to continue.",
                onBack: { step = .welcome },
                onContinue: { step = .chooseEngine }
            )
        }
    }

    var requiredPermissionsGranted: Bool {
        permissionManager.accessibilityGranted && permissionManager.inputMonitoringGranted
    }
}

// MARK: - Step 3: Choose Engine

private extension WelcomeView {
    var chooseEngineStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            WelcomeStepHeader(
                title: "Choose Your Engine",
                subtitle: "You can change this anytime from the menu bar."
            )

            VStack(spacing: 10) {
                EngineOptionCard(
                    title: "Apple Intelligence",
                    description: "Built into macOS. No download needed.",
                    systemImage: "apple.logo",
                    isSelected: suggestionSettings.selectedEngine == .appleIntelligence,
                    isAvailable: foundationModelAvailabilityService.isAvailable,
                    unavailableReason: foundationModelAvailabilityService.isAvailable
                        ? nil
                        : "Requires a supported Mac and macOS version.",
                    action: { suggestionSettings.selectEngine(.appleIntelligence) }
                )

                EngineOptionCard(
                    title: "Local Open Source",
                    description: "Runs a Llama model on your Mac. One-time download.",
                    systemImage: "desktopcomputer",
                    isSelected: suggestionSettings.selectedEngine == .llamaOpenSource,
                    isAvailable: true,
                    unavailableReason: nil,
                    action: { suggestionSettings.selectEngine(.llamaOpenSource) }
                )
            }

            WelcomeNavigation(
                canGoBack: true,
                canContinue: true,
                onBack: { step = .permissions },
                onContinue: {
                    if suggestionSettings.selectedEngine == .llamaOpenSource {
                        step = .downloadModel
                    } else {
                        step = .done
                    }
                }
            )
        }
    }
}

// MARK: - Step 4: Download Model (Llama only)

private extension WelcomeView {
    var downloadModelStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            WelcomeStepHeader(
                title: "Download a Model",
                subtitle: "Pick a model to get started. You can add more later in Settings."
            )

            VStack(spacing: 8) {
                ForEach(modelDownloadManager.models) { model in
                    ModelDownloadRow(
                        model: model,
                        state: modelDownloadManager.state(for: model),
                        onDownload: { modelDownloadManager.download(model) }
                    )
                }
            }

            HStack(spacing: 10) {
                Button("Open Model Folder") {
                    modelDownloadManager.openModelsDirectory()
                }
                .controlSize(.small)

                Button("Refresh") {
                    modelDownloadManager.refreshModelStates()
                    runtimeModel.refreshAvailableModels()
                }
                .controlSize(.small)
            }

            WelcomeNavigation(
                canGoBack: true,
                canContinue: hasAtLeastOneModel,
                disabledHint: "Download at least one model to continue.",
                onBack: { step = .chooseEngine },
                onContinue: { step = .done }
            )
        }
    }

    var hasAtLeastOneModel: Bool {
        modelDownloadManager.models.contains { model in
            modelDownloadManager.state(for: model) == .downloaded
        } || !runtimeModel.availableModels.isEmpty
    }
}

// MARK: - Step 5: Done

private extension WelcomeView {
    var doneStep: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.12))

                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 56, height: 56)

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("Tabby is ready. Start typing in any text field\nand suggestions will appear automatically.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 6) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .foregroundStyle(.secondary)

                Text("Look for Tabby in your menu bar.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            WelcomeButton(title: "Start Using Tabby") {
                onDismiss()
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Shared Components

/// Consistent header for wizard steps with a title and subtitle.
private struct WelcomeStepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            Text(subtitle)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

/// Primary action button used on the welcome and done steps.
private struct WelcomeButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// Back + Continue navigation bar used on middle wizard steps.
/// "Continue" can be disabled with a tooltip hint explaining what's needed.
private struct WelcomeNavigation: View {
    var canGoBack: Bool = false
    var canContinue: Bool = true
    var disabledHint: String? = nil
    var onBack: (() -> Void)? = nil
    let onContinue: () -> Void

    var body: some View {
        HStack {
            if canGoBack, let onBack {
                Button("Back") {
                    onBack()
                }
                .controlSize(.large)
            }

            Spacer(minLength: 0)

            Button("Continue") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue)
            .help(canContinue ? "" : (disabledHint ?? ""))
        }
    }
}

/// One permission row in the permissions step. Shows a live indicator + Grant button.
private struct WelcomePermissionRow: View {
    let title: String
    let subtitle: String
    let granted: Bool
    let action: () -> Void
    var isOptional: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(granted ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))

                    if isOptional {
                        Text("Optional")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if granted {
                Text("Granted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button("Grant") {
                    action()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Selectable card for the engine choice step. Unavailable engines are shown
/// but grayed out with an explanation so the user understands their options.
private struct EngineOptionCard: View {
    let title: String
    let description: String
    let systemImage: String
    let isSelected: Bool
    let isAvailable: Bool
    let unavailableReason: String?
    let action: () -> Void

    var body: some View {
        Button(action: {
            if isAvailable {
                action()
            }
        }) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(isAvailable ? .primary : .tertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isAvailable ? .primary : .tertiary)

                    if let unavailableReason, !isAvailable {
                        Text(unavailableReason)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if isSelected && isAvailable {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tint)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected && isAvailable ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.quaternary.opacity(0.5)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected && isAvailable ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }
}

/// One downloadable model row in the download step.
private struct ModelDownloadRow: View {
    let model: DownloadableRuntimeModel
    let state: ModelDownloadState
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))

                Text(state.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 0)

            Button(buttonTitle) {
                onDownload()
            }
            .controlSize(.small)
            .disabled(isButtonDisabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private var buttonTitle: String {
        switch state {
        case .idle:
            return "Download"
        case .downloading:
            return "Downloading…"
        case .downloaded:
            return "Installed"
        case .failed:
            return "Retry"
        }
    }

    private var isButtonDisabled: Bool {
        switch state {
        case .downloading, .downloaded:
            return true
        case .idle, .failed:
            return false
        }
    }

    private var statusColor: Color {
        switch state {
        case .downloaded: return .green
        case .downloading: return .blue
        case .failed: return .red
        case .idle: return .secondary
        }
    }
}
