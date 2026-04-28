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
    private lazy var observerPulsePanel: NSPanel = makePanel()
    private var latestCaretRect: CGRect?
    private var pulseHideTask: Task<Void, Never>?

    func update(for snapshot: FocusSnapshot) {
        guard let context = snapshot.context else {
            hide()
            return
        }

        latestCaretRect = context.caretRect
        showCaretIndicator(context: context)
        showFrameOutline(context: context)
    }

    /// Flashes when an AX notification reaches `FocusTracker`.
    ///
    /// This answers a different question than the caret/frame overlay: "did the observer fire at all?"
    /// The snapshot may not visibly change for every notification, so this pulse is driven by the raw
    /// observer event instead of by `FocusSnapshot` updates.
    func flashAXObserverHit(event: FocusObserverEvent) {
        pulseHideTask?.cancel()

        let color = event.sequence.isMultiple(of: 2) ? Color.green : Color.cyan
        let contentView = NSHostingView(rootView: AXObserverPulseView(
            notificationName: event.displayName,
            sequence: event.sequence,
            color: color
        ))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        observerPulsePanel.alphaValue = 1
        observerPulsePanel.contentView = contentView
        observerPulsePanel.setFrame(
            CGRect(origin: pulseOrigin(for: contentSize), size: contentSize).integral,
            display: true
        )
        observerPulsePanel.orderFrontRegardless()

        pulseHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else {
                return
            }

            self?.observerPulsePanel.orderOut(nil)
            self?.pulseHideTask = nil
        }
    }

    func hide() {
        latestCaretRect = nil
        pulseHideTask?.cancel()
        pulseHideTask = nil
        caretPanel.orderOut(nil)
        framePanel.orderOut(nil)
        observerPulsePanel.orderOut(nil)
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

    private func pulseOrigin(for contentSize: CGSize) -> CGPoint {
        if let latestCaretRect {
            return CGPoint(
                x: latestCaretRect.maxX + 8,
                y: latestCaretRect.maxY + 4
            )
        }

        // If the observer fires before we have a supported caret snapshot, keep the pulse visible
        // near the top-right of the active screen so the debug signal is still discoverable.
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        return CGPoint(
            x: screenFrame.maxX - contentSize.width - 20,
            y: screenFrame.maxY - contentSize.height - 20
        )
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

private struct AXObserverPulseView: View {
    let notificationName: String
    let sequence: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text("AX \(sequence) \(notificationName)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.92))
        )
        .fixedSize()
    }
}
