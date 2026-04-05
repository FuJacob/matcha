import SwiftUI

/// File overview:
/// Renders the compact first-run welcome screen. The copy is intentionally short: explain what
/// Tabby does, how acceptance works, and which permissions the app depends on.
///
/// The view stays presentation-focused. It does not own persistence or window lifecycle; those
/// behaviors live in `WelcomeCoordinator`.
struct WelcomeView: View {
    @ObservedObject var permissionManager: PermissionManager

    let onDismiss: () -> Void
    let onOpenAccessibility: () -> Void
    let onOpenInputMonitoring: () -> Void

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 18) {
                header
                stepsCard
                permissionsCard
                actions
            }
            .padding(22)
        }
        .frame(width: 420)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.16, blue: 0.11),
                Color(red: 0.05, green: 0.08, blue: 0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 180, height: 180)
                .blur(radius: 18)
                .offset(x: 58, y: -72)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Tabby")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)

                Text("Local ghost-text completion for macOS apps. Tabby watches the focused field, suggests the next words, and lets you accept them with `Tab` one chunk at a time.")
                    .font(.system(size: 13.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stepsCard: some View {
        WelcomeCard(title: "How It Works") {
            VStack(alignment: .leading, spacing: 10) {
                WelcomeStepRow(
                    number: "1",
                    title: "Type where you normally write",
                    detail: "Notes, Discord, Gmail, code editors, and other editable text inputs."
                )
                WelcomeStepRow(
                    number: "2",
                    title: "Watch for gray ghost text",
                    detail: "Tabby proposes the next words directly near your caret."
                )
                WelcomeStepRow(
                    number: "3",
                    title: "Press Tab to accept",
                    detail: "Each press accepts the next chunk. If you type your own text instead, Tabby adapts."
                )
            }
        }
    }

    private var permissionsCard: some View {
        WelcomeCard(title: "Permissions") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tabby only needs two macOS permissions to work correctly.")
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.76))

                WelcomePermissionRow(
                    title: "Accessibility",
                    subtitle: "Read the focused text field and caret position.",
                    granted: permissionManager.accessibilityGranted,
                    buttonTitle: "Open",
                    action: onOpenAccessibility
                )

                WelcomePermissionRow(
                    title: "Input Monitoring",
                    subtitle: "Listen for typing and `Tab` acceptance globally.",
                    granted: permissionManager.inputMonitoringGranted,
                    buttonTitle: "Open",
                    action: onOpenInputMonitoring
                )
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text("Everything runs locally on your Mac.")
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))

            Spacer(minLength: 0)

            Button("Got it") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color(red: 0.35, green: 0.78, blue: 0.45))
        }
    }
}

private struct WelcomeCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.88))

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct WelcomeStepRow: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color(red: 0.74, green: 0.92, blue: 0.72))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)

                Text(detail)
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)

                Text(subtitle)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.68))
            }

            Spacer(minLength: 0)

            if granted {
                Text("Granted")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
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
