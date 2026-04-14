import CoreGraphics
import Foundation

/// File overview:
/// Adapts coordinator intent into overlay-controller actions. The coordinator still decides when
/// a suggestion should be visible, but this helper owns the small UX rules for whether the overlay
/// is actually changing and which status message should accompany that change.
///
/// This separation is useful because overlay bugs often mix two concerns:
/// "should ghost text be shown?" and "what AppKit action did we take?" Those questions now live in
/// different places.
@MainActor
struct SuggestionOverlayPresenter {
    private let overlayController: any SuggestionOverlayControlling

    init(overlayController: any SuggestionOverlayControlling) {
        self.overlayController = overlayController
    }

    /// Shows or repositions ghost text while preserving the previous overlay message when nothing changed.
    func present(text: String, at caretRect: CGRect, previousState: OverlayState) -> String? {
        guard !text.isEmpty else {
            return hide(reason: "Overlay hidden because the suggestion text was empty.")
        }

        guard previousState != .visible(text: text, caretRect: caretRect) else {
            return nil
        }

        overlayController.showSuggestion(text, at: caretRect)

        switch previousState {
        case let .visible(previousText, previousCaretRect) where previousText == text && previousCaretRect != caretRect:
            return "Moved ghost text to the latest caret position."

        default:
            return "Displayed ghost text near the caret."
        }
    }

    func hide(reason: String) -> String {
        overlayController.hide(reason: reason)
        return reason
    }
}
