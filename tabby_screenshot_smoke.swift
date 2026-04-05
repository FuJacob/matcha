import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
@preconcurrency import Vision

enum SmokeError: LocalizedError {
    case noFrontmostApp
    case noWindow(pid_t)
    case noImage

    var errorDescription: String? {
        switch self {
        case .noFrontmostApp:
            return "No frontmost application found."
        case .noWindow(let pid):
            return "No on-screen window found for PID \(pid)."
        case .noImage:
            return "Capture returned no image."
        }
    }
}

func currentShareableContent() async throws -> SCShareableContent {
    try await withCheckedThrowingContinuation { continuation in
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            guard let content else {
                continuation.resume(throwing: SmokeError.noImage)
                return
            }
            continuation.resume(returning: content)
        }
    }
}

func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            guard let image else {
                continuation.resume(throwing: SmokeError.noImage)
                return
            }
            continuation.resume(returning: image)
        }
    }
}

func ocrText(from image: CGImage) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations
                    .sorted {
                        if abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.02 {
                            return $0.boundingBox.minY > $1.boundingBox.minY
                        }
                        return $0.boundingBox.minX < $1.boundingBox.minX
                    }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                continuation.resume(returning: lines.joined(separator: "\n"))
            }

            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.012

            do {
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@main
struct SmokeMain {
    static func main() async {
        do {
            guard CGPreflightScreenCaptureAccess() else {
                print("SCREEN_CAPTURE_PERMISSION=false")
                print("RESULT=blocked")
                return
            }

            guard let app = NSWorkspace.shared.frontmostApplication else {
                throw SmokeError.noFrontmostApp
            }

            let pid = app.processIdentifier
            let content = try await currentShareableContent()
            let window = content.windows.first(where: {
                $0.owningApplication?.processID == pid && $0.isActive && $0.isOnScreen
            }) ?? content.windows.first(where: {
                $0.owningApplication?.processID == pid && $0.isOnScreen
            })

            guard let window else {
                throw SmokeError.noWindow(pid)
            }

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width.rounded(.up))
            config.height = Int(window.frame.height.rounded(.up))
            config.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await captureImage(filter: filter, configuration: config)
            let text = try await ocrText(from: image)

            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let outputURL = URL(fileURLWithPath: "/tmp/tabby_screenshot_smoke.png")
            if let tiff = nsImage.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: outputURL)
            }

            let preview = String(text.prefix(240)).replacingOccurrences(of: "\n", with: " | ")
            print("SCREEN_CAPTURE_PERMISSION=true")
            print("FRONTMOST_APP=\(app.localizedName ?? "Unknown")")
            print("WINDOW_TITLE=\(window.title ?? "<nil>")")
            print("IMAGE_SIZE=\(image.width)x\(image.height)")
            print("OCR_CHAR_COUNT=\(text.count)")
            print("OCR_PREVIEW=\(preview)")
            print("IMAGE_PATH=/tmp/tabby_screenshot_smoke.png")
            print("RESULT=ok")
        } catch {
            print("RESULT=failed")
            print("ERROR=\(error.localizedDescription)")
        }
    }
}
