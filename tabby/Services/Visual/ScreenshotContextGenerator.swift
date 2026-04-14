import CoreGraphics
import Foundation

/// File overview:
/// Converts a newly focused input's surrounding screenshot into OCR text for prompt injection.
/// The pipeline is now intentionally direct: focused snapshot -> screenshot crop -> Apple OCR ->
/// normalized visible-text excerpt.
///
/// This keeps the visual-context subsystem fast and conceptually honest. If Tabby later gains
/// true multimodal support, this file remains the seam where OCR can be replaced.

enum ScreenshotContextGenerationError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message):
            return message
        }
    }
}

@MainActor
final class ScreenshotContextGenerator {
    private let screenshotService: WindowScreenshotService
    private let textExtractor: ScreenTextExtractor
    private let configuration: VisualContextConfiguration

    init(
        screenshotService: WindowScreenshotService? = nil,
        textExtractor: ScreenTextExtractor? = nil,
        configuration: VisualContextConfiguration? = nil
    ) {
        let actualConfig = configuration ?? .default
        self.screenshotService = screenshotService ?? WindowScreenshotService()
        self.textExtractor =
            textExtractor
            ?? ScreenTextExtractor(
                maxImageDimension: actualConfig.maxImageDimension,
                maxRecognizedCharacters: actualConfig.maxRecognizedCharacters
            )
        self.configuration = actualConfig
    }

    /// Captures a compact region around the focused input, runs OCR, and returns normalized visible
    /// text that can be injected directly into the completion prompt.
    func generateContext(
        for context: FocusedInputSnapshot,
        onStatusChange: (@Sendable (VisualContextStatus) async -> Void)? = nil
    ) async throws -> VisualContextExcerpt {
        log(
            "context-start app=\(context.applicationName) pid=\(context.processIdentifier) element=\(context.elementIdentifier)"
        )
        await onStatusChange?(.capturing)

        let screenshot: CapturedWindowScreenshot
        do {
            screenshot = try await screenshotService.captureSnapshot(
                around: context,
                snapshotDimension: configuration.snapshotDimension
            )
        } catch let error as WindowScreenshotError {
            log("context-capture-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            log("context-capture-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        log(
            "context-captured title=\(screenshot.windowTitle ?? "<untitled>") "
                + "image=\(screenshot.image.width)x\(screenshot.image.height)"
        )

        await onStatusChange?(.extractingText)

        let extractedText: String
        do {
            extractedText = try await textExtractor.extractText(from: screenshot.image).text
        } catch ScreenTextExtractionError.noRecognizedText {
            guard let windowTitle = screenshot.windowTitle,
                hasMeaningfulSignal(windowTitle)
            else {
                log("context-ocr-unavailable no-recognized-text-and-weak-window-title")
                throw ScreenshotContextGenerationError.unavailable(
                    "The screenshot did not contain enough visible text to build prompt context."
                )
            }

            let fallbackText = normalizeRecognizedText(windowTitle)
            log("context-ocr-empty using-window-title-fallback")
            return VisualContextExcerpt(text: fallbackText)
        } catch let error as ScreenTextExtractionError {
            log("context-ocr-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            log("context-ocr-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        let normalizedText = normalizeRecognizedText(extractedText)
        log("context-ocr-ready chars=\(normalizedText.count)")

        guard hasMeaningfulSignal(normalizedText) else {
            log("context-unavailable weak-screenshot-signal")
            throw ScreenshotContextGenerationError.unavailable(
                "The screenshot did not contain enough visible text to build prompt context."
            )
        }

        log("context-ready text=\(preview(normalizedText))")

        return VisualContextExcerpt(
            text: normalizedText
        )
    }

    /// OCR is noisy by nature. We normalize line whitespace and keep only a bounded excerpt so the
    /// completion prompt receives nearby visible text, not an unbounded UI dump.
    private func normalizeRecognizedText(_ rawText: String) -> String {
        let lines =
            rawText
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let joinedText = lines.joined(separator: "\n")
        return String(joinedText.prefix(configuration.maxRecognizedCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// We reject OCR text that is mostly punctuation or numeric noise because that would hurt
    /// the completion prompt more than help it.
    private func hasMeaningfulSignal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= configuration.minRecognizedCharacterCount else {
            return false
        }

        let letterCount = trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count
        return letterCount >= 4
    }

    private func log(_ message: String) {
        _ = message
    }

    private func preview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 80 {
            return compact
        }

        let cut = compact.index(compact.startIndex, offsetBy: 80)
        return "\(compact[..<cut])..."
    }
}
