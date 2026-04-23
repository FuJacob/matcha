import SwiftUI

/// File overview:
/// Shared local-model installation UI used by onboarding and Settings.
///
/// Why this file exists:
/// the downloadable model catalog is product behavior, not onboarding-only behavior. Extracting it
/// here keeps the row layout, progress bar behavior, retry affordance, and folder actions in one
/// place so day-one and day-two install flows cannot drift apart.
struct DownloadableModelCatalogView: View {
    @ObservedObject var modelDownloadManager: ModelDownloadManager

    let onRefreshModels: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(modelDownloadManager.models) { model in
                DownloadableModelRow(
                    model: model,
                    state: modelDownloadManager.state(for: model),
                    onDownload: { modelDownloadManager.download(model) },
                    onCancel: { modelDownloadManager.cancel(filename: model.filename) }
                )
            }

            HStack(spacing: 12) {
                Button {
                    modelDownloadManager.openModelsDirectory()
                } label: {
                    Label("Add Your Own", systemImage: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    onRefreshModels()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Drop any .gguf model into the folder above.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// App Store-style model row with inline progress state.
/// This view intentionally renders from `ModelDownloadState` only, so onboarding and Settings
/// reflect the same source of truth without special-case UI logic.
private struct DownloadableModelRow: View {
    let model: DownloadableRuntimeModel
    let state: ModelDownloadState
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))

                    Text("(\(model.actualModelName))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text(metadataText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                }

                Spacer(minLength: 0)

                modelActionButton
            }

            if state.isDownloading {
                downloadProgressBar
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.3))
        )
    }

    @ViewBuilder
    private var modelActionButton: some View {
        switch state {
        case .idle:
            Button("Get") { onDownload() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .downloading(let progress):
            HStack(spacing: 6) {
                if let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.blue)
                        .frame(width: 40, alignment: .trailing)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 40)
                }
                // Plain SF Symbol button keeps the row compact and matches
                // the "Get"/"Retry" button affordance scale. Cancel is the
                // affirmative action while downloading, so it gets the same
                // visual weight as Get does in the idle state.
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            }
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
        case .failed:
            Button("Retry") { onDownload() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var metadataText: String {
        let installationStatus: String
        switch state {
        case .idle:
            installationStatus = "Not installed"
        case .downloading:
            installationStatus = state.statusText
        case .downloaded:
            installationStatus = "Installed"
        case .failed:
            installationStatus = state.statusText
        }

        return "\(installationStatus)  •  \(model.approximateSizeLabel)"
    }

    private var statusColor: Color {
        switch state {
        case .downloaded: return .green
        case .downloading: return .blue
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    @ViewBuilder
    private var downloadProgressBar: some View {
        if let progress = state.progressFraction {
            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .tint(.blue)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.blue)
        }
    }
}
