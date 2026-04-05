import CoreGraphics
import Foundation
import ScreenCaptureKit

/// File overview:
/// Captures the frontmost on-screen window for a given process using ScreenCaptureKit.
/// This is the screenshot boundary for prompt augmentation: raw pixels enter here, and the rest
/// of the app never has to know about window discovery or capture APIs.
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
    /// Finds the most relevant visible window for the focused process and captures it as a `CGImage`.
    /// We prefer active on-screen windows and then fall back to any visible window owned by the app.
    func captureFrontmostWindow(processIdentifier: pid_t) async throws -> CapturedWindowScreenshot {
        guard CGPreflightScreenCaptureAccess() else {
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
            throw WindowScreenshotError.noVisibleWindowForProcess(processIdentifier)
        }

        let filter = SCContentFilter(desktopIndependentWindow: matchingWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(matchingWindow.frame.width.rounded(.up))
        configuration.height = Int(matchingWindow.frame.height.rounded(.up))
        configuration.showsCursor = false

        let image = try await captureImage(filter: filter, configuration: configuration)
        return CapturedWindowScreenshot(image: image, windowTitle: matchingWindow.title)
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
}
