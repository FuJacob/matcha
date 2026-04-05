import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Owns the tiny non-activating panel that marks supported inputs with a subtle Matcha icon.
/// Unlike the ghost-text overlay, this controller is focus-driven and anchors to the full input frame.
///
/// Keeping this as a separate controller preserves the architectural split between:
/// supported-field affordances and suggestion-specific UI.
@MainActor
final class ActivationIndicatorController {
    private let horizontalGap: CGFloat = 6
    private let screenInset: CGFloat = 2

    private lazy var contentView: NSHostingView<ActivationIndicatorView> = {
        NSHostingView(rootView: ActivationIndicatorView())
    }()

    private lazy var panel: ActivationIndicatorPanel = {
        let panel = ActivationIndicatorPanel(
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
        panel.contentView = contentView
        return panel
    }()

    private var lastInputFrameRect: CGRect?

    /// Sizes and positions the activation icon just outside the left edge of the supported input.
    func show(at inputFrameRect: CGRect) {
        guard !inputFrameRect.isEmpty else {
            hide(reason: "Activation indicator hidden because the input frame was empty.")
            return
        }

        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize
        let frame = CGRect(
            origin: origin(for: inputFrameRect, contentSize: contentSize),
            size: contentSize
        ).integral

        if lastInputFrameRect == inputFrameRect, panel.frame == frame, panel.isVisible {
            return
        }

        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        lastInputFrameRect = inputFrameRect
    }

    /// Hides the indicator when Matcha is not actively supporting the current field.
    func hide(reason _: String) {
        panel.orderOut(nil)
        lastInputFrameRect = nil
    }

    /// Anchors the icon outside-left and vertically centered, then clamps to the visible screen.
    private func origin(for inputFrameRect: CGRect, contentSize: CGSize) -> CGPoint {
        let proposedOrigin = CGPoint(
            x: inputFrameRect.minX - contentSize.width - horizontalGap,
            y: inputFrameRect.midY - (contentSize.height / 2)
        )

        guard let screen = screen(for: inputFrameRect) else {
            return proposedOrigin
        }

        let visibleFrame = screen.visibleFrame
        let clampedX = min(
            max(proposedOrigin.x, visibleFrame.minX + screenInset),
            visibleFrame.maxX - contentSize.width - screenInset
        )
        let clampedY = min(
            max(proposedOrigin.y, visibleFrame.minY + screenInset),
            visibleFrame.maxY - contentSize.height - screenInset
        )

        return CGPoint(x: clampedX, y: clampedY)
    }

    /// Chooses the screen that currently contains the center of the input field.
    private func screen(for inputFrameRect: CGRect) -> NSScreen? {
        let midpoint = CGPoint(x: inputFrameRect.midX, y: inputFrameRect.midY)

        if let containingScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) }) {
            return containingScreen
        }

        return NSScreen.screens.first(where: { $0.frame.intersects(inputFrameRect) })
    }
}

private final class ActivationIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ActivationIndicatorView: View {
    var body: some View {
        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .opacity(0.85)
            .padding(2)
            .fixedSize()
    }
}
