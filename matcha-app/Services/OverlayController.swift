import AppKit
import Foundation
import SwiftUI

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

    func showSuggestion(_ text: String, at caretRect: CGRect) {
        guard !text.isEmpty else {
            hide(reason: "Overlay not shown because the suggestion was empty.")
            return
        }

        let contentView = NSHostingView(rootView: GhostSuggestionView(text: text))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        // The first version keeps positioning intentionally simple: render just to the right of
        // the caret and vertically center the ghost text against the reported caret height.
        let origin = CGPoint(
            x: caretRect.maxX + 6,
            y: caretRect.minY + max((caretRect.height - contentSize.height) / 2, 0)
        )
        let frame = CGRect(origin: origin, size: contentSize)

        panel.contentView = contentView
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()
        state = .visible(text: text, caretRect: caretRect)
    }

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
        Text(text)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Color.secondary.opacity(0.78))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
    }
}
