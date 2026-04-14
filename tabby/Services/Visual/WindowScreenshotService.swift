import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// File overview:
/// Captures a compact screenshot around the currently focused input using ScreenCaptureKit.
/// This is the screenshot boundary for prompt augmentation: raw pixels enter here, and the rest
/// of the app never has to know about window discovery, crop math, or coordinate conversion APIs.
///
/// We use ScreenCaptureKit instead of deprecated Core Graphics screenshot APIs because the app
/// targets a modern macOS SDK where `CGWindowListCreateImage` is no longer available.

struct CapturedWindowScreenshot {
    let image: CGImage
    let windowTitle: String?
}

enum WindowScreenshotError: LocalizedError {
    case screenRecordingPermissionMissing
    case noVisibleWindowForProcess(pid_t)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionMissing:
            return "Screen Recording permission is required to capture screenshot context."
        case let .noVisibleWindowForProcess(processIdentifier):
            return "No visible frontmost window was found for process \(processIdentifier)."
        case let .captureFailed(message):
            return "Unable to capture the frontmost window screenshot: \(message)"
        }
    }
}

struct WindowScreenshotService {
    /// Finds the most relevant visible window for the focused process and captures a square region
    /// around the focused input. The crop is expressed in global display points so the caller does
    /// not need to know anything about ScreenCaptureKit's capture coordinate system.
    func captureSnapshot(
        around context: FocusedInputSnapshot,
        snapshotDimension: Int
    ) async throws -> CapturedWindowScreenshot {
        let startedAt = Date()
        let processIdentifier = pid_t(context.processIdentifier)
        log("capture-start pid=\(processIdentifier)")

        guard CGPreflightScreenCaptureAccess() else {
            log("capture-blocked missing-screen-recording-permission pid=\(processIdentifier)")
            throw WindowScreenshotError.screenRecordingPermissionMissing
        }

        let shareableContent = try await currentShareableContent()
        let matchingWindow =
            shareableContent.windows.first(where: {
                $0.owningApplication?.processID == processIdentifier && $0.isActive && $0.isOnScreen
            })
            ?? shareableContent.windows.first(where: {
                $0.owningApplication?.processID == processIdentifier && $0.isOnScreen
            })

        guard let matchingWindow else {
            log("capture-no-window pid=\(processIdentifier)")
            throw WindowScreenshotError.noVisibleWindowForProcess(processIdentifier)
        }

        let sourceRect = snapshotRect(
            around: context,
            windowFrame: matchingWindow.frame,
            snapshotDimension: CGFloat(snapshotDimension)
        )
        let outputScale = backingScaleFactor(for: sourceRect)
        log(
            "capture-window-selected pid=\(processIdentifier) title=\(matchingWindow.title ?? "<untitled>") " +
                "window=\(Int(matchingWindow.frame.width.rounded(.up)))x\(Int(matchingWindow.frame.height.rounded(.up))) " +
                "crop=\(Int(sourceRect.width.rounded(.up)))x\(Int(sourceRect.height.rounded(.up)))"
        )

        let filter = SCContentFilter(desktopIndependentWindow: matchingWindow)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(Int((sourceRect.width * outputScale).rounded(.up)), 1)
        configuration.height = max(Int((sourceRect.height * outputScale).rounded(.up)), 1)
        configuration.showsCursor = false

        let image = try await captureImage(filter: filter, configuration: configuration)
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        log(
            "capture-success pid=\(processIdentifier) image=\(image.width)x\(image.height) " +
                "elapsed_ms=\(elapsedMilliseconds)"
        )
        return CapturedWindowScreenshot(image: image, windowTitle: matchingWindow.title)
    }

    /// Chooses the capture anchor. Small fields benefit from centering on the whole field, while
    /// large editors are better anchored on the caret so the crop stays near the current work area.
    private func snapshotRect(
        around context: FocusedInputSnapshot,
        windowFrame: CGRect,
        snapshotDimension: CGFloat
    ) -> CGRect {
        let anchorRect = preferredAnchorRect(for: context, snapshotDimension: snapshotDimension)
        let targetWidth = min(snapshotDimension, windowFrame.width)
        let targetHeight = min(snapshotDimension, windowFrame.height)
        let halfWidth = targetWidth / 2
        let halfHeight = targetHeight / 2

        let proposedX = anchorRect.midX - halfWidth
        let proposedY = anchorRect.midY - halfHeight
        let clampedX = min(max(proposedX, windowFrame.minX), windowFrame.maxX - targetWidth)
        let clampedY = min(max(proposedY, windowFrame.minY), windowFrame.maxY - targetHeight)

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: targetWidth,
            height: targetHeight
        ).integral
    }

    private func preferredAnchorRect(
        for context: FocusedInputSnapshot,
        snapshotDimension: CGFloat
    ) -> CGRect {
        if let inputFrameRect = context.inputFrameRect,
           !inputFrameRect.isEmpty,
           inputFrameRect.width <= snapshotDimension * 0.8,
           inputFrameRect.height <= snapshotDimension * 0.8
        {
            return inputFrameRect
        }

        return context.caretRect
    }

    private func backingScaleFactor(for rect: CGRect) -> CGFloat {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(midpoint) }) {
            return screen.backingScaleFactor
        }

        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    /// Wraps ScreenCaptureKit's callback API so the rest of the app can use structured concurrency.
    private func currentShareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: WindowScreenshotError.captureFailed(error.localizedDescription))
                    return
                }

                guard let content else {
                    continuation.resume(throwing: WindowScreenshotError.captureFailed("Shareable content was unavailable."))
                    return
                }

                continuation.resume(returning: content)
            }
        }
    }

    /// Captures one CGImage for the chosen window filter.
    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: WindowScreenshotError.captureFailed(error.localizedDescription))
                    return
                }

                guard let image else {
                    continuation.resume(throwing: WindowScreenshotError.captureFailed("ScreenCaptureKit returned no image."))
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    private func log(_ message: String) {
        _ = message
    }
}
