import AppKit
import Foundation
import SwiftUI

/// Gated behind `-tabby-debug-caret-overlay`. Shows a bright colored line at the resolved caret
/// position and a label indicating the geometry source and quality. This lets you visually verify
/// that the caret rect aligns with the real blinking cursor in the host app.
@MainActor
final class FocusDebugOverlayController {
    static let launchArgument = "-tabby-debug-caret-overlay"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    private lazy var caretPanel: NSPanel = makePanel()
    private lazy var framePanel: NSPanel = makePanel()

    func update(for snapshot: FocusSnapshot) {
        guard let context = snapshot.context else {
            hide()
            return
        }

        showCaretIndicator(context: context)
        showFrameOutline(context: context)
    }

    func hide() {
        caretPanel.orderOut(nil)
        framePanel.orderOut(nil)
    }

    // MARK: - Caret indicator

    private func showCaretIndicator(context: FocusedInputSnapshot) {
        let color = indicatorColor(for: context.caretSource)
        let contentView = NSHostingView(rootView: CaretDebugView(
            source: context.caretSource,
            role: context.role,
            caretHeight: context.caretRect.height,
            color: color
        ))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        // Anchor the line at the caret position with the label floating above.
        let origin = CGPoint(
            x: context.caretRect.minX - 1,
            y: context.caretRect.minY
        )

        caretPanel.contentView = contentView
        caretPanel.setFrame(CGRect(origin: origin, size: contentSize).integral, display: true)
        caretPanel.orderFrontRegardless()
    }

    // MARK: - Input frame outline

    private func showFrameOutline(context: FocusedInputSnapshot) {
        guard let inputFrame = context.inputFrameRect, !inputFrame.isEmpty else {
            framePanel.orderOut(nil)
            return
        }

        let borderWidth: CGFloat = 1
        let inset = borderWidth / 2
        let contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.cyan.opacity(0.6), lineWidth: borderWidth)
                .padding(inset)
        )

        let expanded = inputFrame.insetBy(dx: -2, dy: -2)
        framePanel.contentView = contentView
        framePanel.setFrame(expanded.integral, display: true)
        framePanel.orderFrontRegardless()
    }

    // MARK: - Helpers

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        // Above activation indicator and ghost text so it's always visible during debugging.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func indicatorColor(for source: String) -> Color {
        if source.contains("exact") { return .green }
        if source.contains("derived") { return .yellow }
        return .red
    }
}

// MARK: - SwiftUI views

private struct CaretDebugView: View {
    let source: String
    let role: String
    let caretHeight: CGFloat
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(source) | \(role)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.85))
                )

            Rectangle()
                .fill(color)
                .frame(width: 2, height: caretHeight)
        }
        .fixedSize()
    }
}
