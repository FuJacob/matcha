import CoreGraphics
import Foundation
@preconcurrency import Vision

/// File overview:
/// Runs OCR over a captured window screenshot and returns a reading-order text excerpt.
/// This is the bridge between raw image capture and the existing text-only local LLM runtime.
///
/// We deliberately downsample very large screenshots before OCR. The goal is not archival fidelity;
/// it is fast, good-enough semantic extraction for autocomplete context.

struct ExtractedScreenText: Sendable {
    let text: String
    let lineCount: Int
}

enum ScreenTextExtractionError: LocalizedError {
    case noRecognizedText
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecognizedText:
            return "No usable visible text was recognized in the screenshot."
        case let .ocrFailed(message):
            return "Screenshot OCR failed: \(message)"
        }
    }
}

struct ScreenTextExtractor {
    let maxImageDimension: Int
    let maxRecognizedCharacters: Int

    init(
        maxImageDimension: Int = VisualContextConfiguration.default.maxImageDimension,
        maxRecognizedCharacters: Int = VisualContextConfiguration.default.maxRecognizedCharacters
    ) {
        self.maxImageDimension = maxImageDimension
        self.maxRecognizedCharacters = maxRecognizedCharacters
    }

    /// Performs OCR asynchronously so the main actor is not blocked by Vision processing.
    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        let preparedImage = downsampledImageIfNeeded(image)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(throwing: ScreenTextExtractionError.ocrFailed(error.localizedDescription))
                        return
                    }

                    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                    let orderedLines = observations
                        .sorted {
                            if abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.02 {
                                return $0.boundingBox.minY > $1.boundingBox.minY
                            }

                            return $0.boundingBox.minX < $1.boundingBox.minX
                        }
                        .compactMap { $0.topCandidates(1).first?.string }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }

                    let joinedText = orderedLines.joined(separator: "\n")
                    let cappedText = String(joinedText.prefix(maxRecognizedCharacters))

                    guard !cappedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.resume(throwing: ScreenTextExtractionError.noRecognizedText)
                        return
                    }

                    continuation.resume(returning: ExtractedScreenText(text: cappedText, lineCount: orderedLines.count))
                }

                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.012

                do {
                    let handler = VNImageRequestHandler(cgImage: preparedImage, options: [:])
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: ScreenTextExtractionError.ocrFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Keeps OCR latency bounded on very large Retina windows by scaling the image to a reasonable
    /// max dimension before text recognition.
    private func downsampledImageIfNeeded(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let largestDimension = max(width, height)

        guard largestDimension > maxImageDimension else {
            return image
        }

        let scale = CGFloat(maxImageDimension) / CGFloat(largestDimension)
        let targetWidth = max(Int(CGFloat(width) * scale), 1)
        let targetHeight = max(Int(CGFloat(height) * scale), 1)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }
}
