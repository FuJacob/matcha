import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Owns the non-activating floating panel that renders ghost text near the caret. AppKit window
/// behavior stays isolated here so the coordinator only has to reason about overlay state.
///
/// Owns the transparent floating panel that renders ghost text near the caret.
/// Keeping window management here prevents AppKit concerns from leaking into the
/// suggestion state machine.
@MainActor
final class OverlayController {
    var onStateChange: ((OverlayState) -> Void)?

    private(set) var state: OverlayState = .hidden(reason: "Overlay idle.") {
        didSet {
            onStateChange?(state)
        }
    }

    private lazy var panel: OverlayPanel = {
        let panel = OverlayPanel(
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
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }()

    /// Sizes and positions the overlay next to the reported caret bounds for the current field.
    func showSuggestion(_ text: String, at caretRect: CGRect) {
        guard !text.isEmpty else {
            hide(reason: "Overlay not shown because the suggestion was empty.")
            return
        }

        let contentView = NSHostingView(rootView: GhostSuggestionView(text: text))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        // Prefer a caret-adjacent anchor and align against the upper portion of the reported
        // text rect. Browser editors often report a taller line fragment than a native caret box,
        // and centering against that fragment makes ghost text sit visibly too low.
        let origin = CGPoint(
            x: caretRect.maxX + 6,
            y: caretRect.minY + max(caretRect.height - contentSize.height - 1, 0)
        )
        let frame = CGRect(origin: origin, size: contentSize)

        panel.contentView = contentView
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()
        state = .visible(text: text, caretRect: caretRect)
    }

    /// Hides the floating panel and records why the overlay is no longer visible.
    func hide(reason: String) {
        panel.orderOut(nil)
        state = .hidden(reason: reason)
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct GhostSuggestionView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.78))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)

            GhostKeycap(label: "Tab")
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct GhostKeycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.secondary.opacity(0.72))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}
