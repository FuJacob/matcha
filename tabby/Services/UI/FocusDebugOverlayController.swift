import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Renders Tabby's developer overlay windows:
/// - a caret-aligned geometry marker
/// - an input-frame outline
/// - a persistent top-right diagnostics HUD
///
/// The controller is intentionally a renderer. It does not read settings, runtime state, or
/// suggestion state directly. `AppDelegate` composes those sources into
/// `DeveloperDiagnosticsOverlaySnapshot` and hands the snapshot here. That boundary keeps visual
/// debugging separate from the autocomplete state machine.
@MainActor
final class FocusDebugOverlayController {
    private lazy var caretPanel: NSPanel = makePanel()
    private lazy var framePanel: NSPanel = makePanel()
    private lazy var hudPanel: NSPanel = makePanel()

    private var latestFocusSnapshot: FocusSnapshot?
    private var latestDiagnosticsSnapshot = DeveloperDiagnosticsOverlaySnapshot.disabled
    private var axPulseActive = false
    private var pulseHideTask: Task<Void, Never>?

    /// Renders the current diagnostics overlay state. Passing a disabled snapshot hides all panels.
    func render(
        focusSnapshot: FocusSnapshot,
        diagnostics: DeveloperDiagnosticsOverlaySnapshot
    ) {
        latestFocusSnapshot = focusSnapshot
        latestDiagnosticsSnapshot = diagnostics

        guard diagnostics.overlaysEnabled else {
            hide()
            return
        }

        if case .supported = focusSnapshot.capability, let context = focusSnapshot.context {
            showCaretIndicator(context: context)
            showFrameOutline(context: context)
        } else {
            caretPanel.orderOut(nil)
            framePanel.orderOut(nil)
        }

        showHUD(diagnostics: diagnostics)
    }

    /// Temporarily brightens the AX row in the HUD when a raw AXObserver notification arrives.
    ///
    /// The pulse is driven by notification delivery, not by snapshot changes, because many AX
    /// notifications legitimately resolve to the same focused field state.
    func flashAXObserverHit() {
        guard latestDiagnosticsSnapshot.overlaysEnabled else {
            return
        }

        pulseHideTask?.cancel()
        axPulseActive = true
        showHUD(diagnostics: latestDiagnosticsSnapshot)

        pulseHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else {
                return
            }

            self?.axPulseActive = false
            if let snapshot = self?.latestDiagnosticsSnapshot {
                self?.showHUD(diagnostics: snapshot)
            }
            self?.pulseHideTask = nil
        }
    }

    func hide() {
        pulseHideTask?.cancel()
        pulseHideTask = nil
        axPulseActive = false
        caretPanel.orderOut(nil)
        framePanel.orderOut(nil)
        hudPanel.orderOut(nil)
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

    // MARK: - HUD

    private func showHUD(diagnostics: DeveloperDiagnosticsOverlaySnapshot) {
        let contentView = NSHostingView(rootView: DeveloperDiagnosticsHUDView(
            snapshot: diagnostics,
            axPulseActive: axPulseActive
        ))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize
        let origin = topRightOrigin(for: contentSize)

        hudPanel.alphaValue = 1
        hudPanel.contentView = contentView
        hudPanel.setFrame(CGRect(origin: origin, size: contentSize).integral, display: true)
        hudPanel.orderFrontRegardless()
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
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func indicatorColor(for source: String) -> Color {
        if source.contains("exact") { return .green }
        if source.contains("derived") { return .yellow }
        return .red
    }

    private func topRightOrigin(for contentSize: CGSize) -> CGPoint {
        let referenceRect = latestFocusSnapshot?.context?.caretRect
        let screen = referenceRect.flatMap(screen(for:)) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        return CGPoint(
            x: screenFrame.maxX - contentSize.width - 18,
            y: screenFrame.maxY - contentSize.height - 18
        )
    }

    private func screen(for rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.intersects(rect)
        }
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

private struct DeveloperDiagnosticsHUDView: View {
    let snapshot: DeveloperDiagnosticsOverlaySnapshot
    let axPulseActive: Bool

    private let columns = [
        GridItem(.flexible(minimum: 94), spacing: 6),
        GridItem(.flexible(minimum: 94), spacing: 6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            contextRow
            completionStrip
            axObserverRow
            configGrid
            recentEvents
        }
        .frame(width: 300, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("TABBY DEV")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Text(snapshot.loggingEnabled ? "LOG ON" : "LOG OFF")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(snapshot.loggingEnabled ? .green : .white.opacity(0.62))
        }
    }

    /// Shows the OCR/context status. Persists across completion cycles — OCR fires once
    /// per focused field, so it stays green (or shows failure) even as new keystrokes begin.
    private var contextRow: some View {
        HStack(spacing: 8) {
            // Larger dot than the completion strip because this is session-level signal
            Circle()
                .fill(color(for: snapshot.contextItem.status))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text("CONTEXT")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))

                Text(snapshot.contextItem.message ?? "Waiting for first focus…")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(color(for: snapshot.contextItem.status).opacity(0.12))
        )
    }

    /// Per-completion-cycle dots. Resets to grey on every new keystroke cycle so stale
    /// success indicators from the last completion don't mislead during a new one.
    private var completionStrip: some View {
        HStack(spacing: 5) {
            ForEach(snapshot.completionItems) { item in
                VStack(spacing: 3) {
                    Circle()
                        .fill(color(for: item.status))
                        .frame(width: 7, height: 7)

                    Text(item.stage.displayName.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity)
                .help(item.message ?? item.status.displayName)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    private var axObserverRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(axPulseActive ? Color.green : Color.cyan.opacity(0.55))
                .frame(width: axPulseActive ? 10 : 7, height: axPulseActive ? 10 : 7)

            Text(axObserverText)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(axPulseActive ? Color.green.opacity(0.28) : Color.cyan.opacity(0.12))
        )
    }

    private var configGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(snapshot.fields) { field in
                VStack(alignment: .leading, spacing: 1) {
                    Text(field.label.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))

                    Text(field.value)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private var recentEvents: some View {
        if !snapshot.recentEvents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("RECENT")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))

                ForEach(snapshot.recentEvents) { event in
                    HStack(alignment: .top, spacing: 6) {
                        // Fixed-width stage badge so columns line up
                        Text(event.stage.displayName.uppercased())
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .foregroundStyle(color(for: event.status))
                            .frame(width: 44, alignment: .leading)

                        // Status dot
                        Circle()
                            .fill(color(for: event.status))
                            .frame(width: 5, height: 5)
                            .padding(.top, 1.5)

                        // Full message — let it wrap to a second line if needed
                        Text(event.message)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var axObserverText: String {
        guard let event = snapshot.latestAXObserverEvent else {
            return "AX observer waiting"
        }

        return "AX \(event.sequence) \(event.displayName)"
    }

    private func color(for status: DeveloperDiagnosticsStatus) -> Color {
        switch status {
        case .idle:
            return .white.opacity(0.32)
        case .running:
            return .cyan
        case .succeeded:
            return .green
        case .skipped:
            return .yellow
        case .failed:
            return .red
        case .cancelled:
            return .orange
        case .stale:
            return .purple
        }
    }
}
