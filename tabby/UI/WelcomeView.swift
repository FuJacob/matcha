import SwiftUI

/// File overview:
/// Renders the compact first-run welcome screen. The copy is intentionally short: explain what
/// Tabby does, how acceptance works, and which permissions the app depends on.
///
/// The view stays presentation-focused. It does not own persistence or window lifecycle; those
/// behaviors live in `WelcomeCoordinator`.
struct WelcomeView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager

    let onDismiss: () -> Void
    let onOpenAccessibility: () -> Void
    let onOpenInputMonitoring: () -> Void
    let onOpenModelsFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            permissionsSection
            modelsSection
            actions
        }
        .padding(22)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))

                Image(systemName: "pawprint.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Tabby")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)

                Text("Local autocomplete for any macOS text field.")
                    .font(.system(size: 13.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.secondary)

                Text("Type normally. Press Tab to accept.")
                    .font(.system(size: 13.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)

            WelcomePermissionRow(
                title: "Accessibility",
                subtitle: "Read focused field and caret.",
                granted: permissionManager.accessibilityGranted,
                buttonTitle: "Open",
                action: onOpenAccessibility
            )

            WelcomePermissionRow(
                title: "Input Monitoring",
                subtitle: "Capture typing and Tab acceptance.",
                granted: permissionManager.inputMonitoringGranted,
                buttonTitle: "Open",
                action: onOpenInputMonitoring
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text("Everything runs locally.")
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.secondary)

            Spacer(minLength: 0)

            Button("Got it") {
                onDismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)

            Text("Download models after install. You can add only what you need.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(Color.secondary)

            ForEach(modelDownloadManager.models) { model in
                let state = modelDownloadManager.state(for: model)

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayName)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary)

                        Text(state.statusText)
                            .font(.system(size: 11.5, weight: .regular, design: .rounded))
                            .foregroundStyle(modelDownloadStatusColor(for: state))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button(downloadButtonTitle(for: state)) {
                        modelDownloadManager.download(model)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDownloadButtonDisabled(for: state))
                }
            }

            HStack(spacing: 10) {
                Button("Open Model Folder") {
                    onOpenModelsFolder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Refresh Model List") {
                    modelDownloadManager.refreshModelStates()
                    runtimeModel.refreshAvailableModels()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func downloadButtonTitle(for state: ModelDownloadState) -> String {
        switch state {
        case .idle:
            return "Download"
        case .downloading:
            return "Downloading"
        case .downloaded:
            return "Installed"
        case .failed:
            return "Retry"
        }
    }

    private func isDownloadButtonDisabled(for state: ModelDownloadState) -> Bool {
        switch state {
        case .downloading, .downloaded:
            return true
        case .idle, .failed:
            return false
        }
    }

    private func modelDownloadStatusColor(for state: ModelDownloadState) -> Color {
        switch state {
        case .downloaded:
            return .green
        case .downloading:
            return .blue
        case .failed:
            return .red
        case .idle:
            return .secondary
        }
    }
}

private struct WelcomePermissionRow: View {
    let title: String
    let subtitle: String
    let granted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.secondary)
                .font(.system(size: 12, weight: .regular))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)

                Text(subtitle)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 0)

            if granted {
                Text("Granted")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.secondary)
            } else {
                Button(buttonTitle) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
