import ApplicationServices
import CoreGraphics
import Foundation

/// File overview:
/// Resolves caret and input-frame geometry from AX elements. This file centralizes the fragile
/// browser/native heuristics used to place overlays and activation indicators correctly.
///
/// Separating geometry heuristics from `FocusTracker` makes compatibility bugs easier to reason
/// about: if the wrong element is selected, the resolver layer is at fault; if the right element
/// is selected but the caret anchor is wrong, this geometry layer is the place to debug.
@MainActor
struct AXTextGeometryResolver {
    /// Resolves the full input frame that the activation indicator uses as its visual anchor.
    /// This is intentionally separate from caret resolution because the indicator tracks field
    /// support, not the exact text insertion point.
    func resolveInputFrameRect(for element: AXUIElement) -> CGRect? {
        guard let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element), !frame.isEmpty else {
            return nil
        }

        return AXHelper.cocoaRect(fromAccessibilityRect: frame)
    }

    /// Finds the best caret anchor available, preferring bounds-for-range and falling back to element frame.
    /// `cocoaAnchorFrame` is the element's AXFrame already converted to Cocoa coordinates — it serves
    /// as the ground-truth reference for detecting whether text-range rects need pixel-to-point scaling.
    func resolveCaretRect(
        for element: AXUIElement,
        selection: NSRange,
        supportsBoundsForRange: Bool,
        supportsFrame: Bool,
        cocoaAnchorFrame: CGRect?,
        textValue: String? = nil
    ) -> CGRect? {
        // Branch 1: Zero-length BoundsForRange at the caret position — ideal case.
        if supportsBoundsForRange,
           let rect = AXHelper.parameterizedRectValue(
               for: kAXBoundsForRangeParameterizedAttribute as CFString,
               range: NSRange(location: selection.location, length: 0),
               on: element
           ), !rect.isEmpty {
            let cocoaRect = AXHelper.validatedCocoaTextRect(
                fromAccessibilityRect: rect,
                anchorFrame: cocoaAnchorFrame
            )
            return normalizedCaretRect(fromZeroLengthRangeRect: cocoaRect)
        }

        // Branch 1.5: Chromium / WebKit AXTextMarker fallback.
        // Apps like Discord/Chrome fail NSRange queries but return a correct bounding box
        // when we ask for the caret via their internal AXTextMarkerRange objects.
        if let markerRect = AXHelper.textMarkerCaretRect(on: element), !markerRect.isEmpty {
            let cocoaRect = AXHelper.validatedCocoaTextRect(
                fromAccessibilityRect: markerRect,
                anchorFrame: cocoaAnchorFrame
            )
            return normalizedCaretRect(fromZeroLengthRangeRect: cocoaRect)
        }

        // Branch 2: BoundsForRange on the character before the caret, then shift to its trailing edge.
        if supportsBoundsForRange,
           selection.location > 0,
           let rect = AXHelper.parameterizedRectValue(
               for: kAXBoundsForRangeParameterizedAttribute as CFString,
               range: NSRange(location: selection.location - 1, length: 1),
               on: element
           ), !rect.isEmpty {
            let cocoaRect = AXHelper.validatedCocoaTextRect(
                fromAccessibilityRect: rect,
                anchorFrame: cocoaAnchorFrame
            )
            return CGRect(x: cocoaRect.maxX, y: cocoaRect.minY, width: 2, height: cocoaRect.height)
        }

        // Branch 3: AXFrame fallback — no text-range data available, estimate from element bounds.
        if supportsFrame,
           let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element), !frame.isEmpty {
            let cocoaRect = AXHelper.cocoaRect(fromAccessibilityRect: frame)
            if cocoaRect.width > 10, let text = textValue {
                let nsText = text as NSString
                let prefix = nsText.substring(to: min(selection.location, nsText.length))
                let estimatedWidthPerChar: CGFloat = 8.0
                let estimatedX = cocoaRect.minX + (CGFloat(prefix.count) * estimatedWidthPerChar)
                let clampedX = min(estimatedX, cocoaRect.maxX)
                return CGRect(x: clampedX, y: cocoaRect.minY, width: 2, height: cocoaRect.height)
            }
            return cocoaRect
        }

        return nil
    }

    /// Some browser-based editors return a full line fragment for a zero-length range instead of
    /// a narrow caret box. Collapse those wide rects back down to a caret-like anchor.
    private func normalizedCaretRect(fromZeroLengthRangeRect rect: CGRect) -> CGRect {
        guard !rect.isEmpty else {
            return rect
        }

        let normalizedWidth: CGFloat = 2
        if rect.width <= 6 {
            return CGRect(x: rect.minX, y: rect.minY, width: normalizedWidth, height: rect.height)
        }

        return CGRect(x: rect.minX, y: rect.minY, width: normalizedWidth, height: rect.height)
    }
}
