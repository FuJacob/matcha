import SwiftUI

/// File overview:
/// Renders an in-depth operator guide that explains Tabby's capabilities, recommended defaults,
/// and model-management workflow. The guide is intentionally static copy so users can open it at
/// any time from the menu without depending on runtime state.
struct GuideView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GuideSectionCard(
                        title: "What Tabby Does",
                        bullets: [
                            "Tabby is local AI autocomplete for any supported macOS text field.",
                            "Ghost text appears near your caret while you type.",
                            "Press Tab to accept the next chunk without leaving your current app."
                        ]
                    )

                    GuideSectionCard(
                        title: "Model Management",
                        bullets: [
                            "Use the built-in download buttons to install curated GGUF models.",
                            "You can also add any custom .gguf file yourself: open the model folder, drop the file in, then press Refresh.",
                            "Any GGUF file in the runtime folder now appears in the model picker.",
                            "Gemma 3n is tagged as recommended because it balances quality and responsiveness well for inline writing."
                        ]
                    )

                    GuideSectionCard(
                        title: "Recommended Settings",
                        bullets: [
                            "Prompt mode: Prefix Only (recommended) for low-latency, direct continuation behavior.",
                            "Words: 3-7 (recommended) because it gives useful completions while keeping acceptance friction low.",
                            "Model: Gemma 3n (recommended) as the first default when available on first run."
                        ]
                    )

                    GuideSectionCard(
                        title: "How Suggestions Work",
                        bullets: [
                            "Tabby tracks focused input fields through macOS Accessibility APIs.",
                            "Typing events trigger debounced generation so completions stay fresh instead of noisy.",
                            "When context changes, stale model output is dropped and the overlay is updated or hidden."
                        ]
                    )

                    GuideSectionCard(
                        title: "Permissions",
                        bullets: [
                            "Accessibility is required to read focused text context and caret position.",
                            "Input Monitoring is required to detect typing and Tab acceptance globally.",
                            "Screen Recording is optional and only used for visual-context augmentation in guided flows."
                        ]
                    )

                    GuideSectionCard(
                        title: "Troubleshooting",
                        bullets: [
                            "If a new model does not appear, confirm the file ends with .gguf and press Refresh.",
                            "If suggestions do not appear, re-check Accessibility and Input Monitoring permissions.",
                            "If overlay placement looks wrong in a specific app, switch apps and return to force fresh focus/caret sampling."
                        ]
                    )
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 10) {
                Text("Everything runs locally on your Mac.")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary)

                Spacer(minLength: 0)

                Button("Close Guide") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))

                Image(systemName: "book.pages.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text("Tabby Guide")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)

                Text("Everything you can do, how it works, and why the defaults are tuned this way.")
                    .font(.system(size: 13.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }
}

private struct GuideSectionCard: View {
    let title: String
    let bullets: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)

            ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                GuideBulletRow(text: bullet)
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
}

private struct GuideBulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.secondary)
                .padding(.top, 1)

            Text(text)
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
