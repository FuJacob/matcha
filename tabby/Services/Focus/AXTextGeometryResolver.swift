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
/// How the caret rect was determined. Exact and derived positions are trustworthy for ghost
/// text placement; estimated positions are computed from field geometry and character counts —
/// too imprecise to anchor an overlay, but enough to signal that a field exists.
enum CaretGeometryQuality {
    case exact
    case derived
    case estimated

    var label: String {
        switch self {
        case .exact: return "exact"
        case .derived: return "derived"
        case .estimated: return "estimated"
        }
    }
}

/// Pairs a caret rect with the method that produced it, so callers can decide
/// whether to trust the position or search for a better geometry source.
struct CaretGeometryResult {
    let rect: CGRect
    let quality: CaretGeometryQuality
}

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
    ) -> CaretGeometryResult? {
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
            return CaretGeometryResult(
                rect: normalizedCaretRect(fromZeroLengthRangeRect: cocoaRect),
                quality: .exact
            )
        }

        // Branch 1.5: Chromium / WebKit AXTextMarker fallback.
        // Apps like Discord/Chrome fail NSRange queries but return a correct bounding box
        // when we ask for the caret via their internal AXTextMarkerRange objects.
        if let markerRect = AXHelper.textMarkerCaretRect(on: element), !markerRect.isEmpty {
            let cocoaRect = AXHelper.validatedCocoaTextRect(
                fromAccessibilityRect: markerRect,
                anchorFrame: cocoaAnchorFrame
            )
            return CaretGeometryResult(
                rect: normalizedCaretRect(fromZeroLengthRangeRect: cocoaRect),
                quality: .exact
            )
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
            return CaretGeometryResult(
                rect: CGRect(x: cocoaRect.maxX, y: cocoaRect.minY, width: 2, height: cocoaRect.height),
                quality: .derived
            )
        }

        // Branch 2.5: Child text-run proportional estimation.
        // Gmail, Outlook, and other Chromium editors fail BoundsForRange entirely but expose
        // AXStaticText children with tight per-text-run AXFrames. Walk those children to find
        // which one contains the caret, then estimate position proportionally within its frame.
        if let parentText = textValue, !parentText.isEmpty {
            if let result = resolveCaretFromChildTextRuns(
                element: element,
                parentSelection: selection,
                parentText: parentText
            ) {
                return result
            }
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
                return CaretGeometryResult(
                    rect: CGRect(x: clampedX, y: cocoaRect.minY, width: 2, height: cocoaRect.height),
                    quality: .estimated
                )
            }
            return CaretGeometryResult(rect: cocoaRect, quality: .estimated)
        }

        return nil
    }

    /// Walks AXStaticText children of a text container to find the one containing the caret,
    /// then estimates caret position proportionally within that child's AXFrame. This is the
    /// primary caret resolution path for Gmail, Outlook, and other Chromium editors where
    /// BoundsForRange fails but per-text-run child frames are precise.
    private func resolveCaretFromChildTextRuns(
        element: AXUIElement,
        parentSelection: NSRange,
        parentText: String
    ) -> CaretGeometryResult? {
        let children = AXHelper.childElements(of: element)
        guard !children.isEmpty else { return nil }

        // Collect AXStaticText children with text and frames.
        var textRuns: [(text: String, frame: CGRect)] = []
        for child in children {
            let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: child)
            guard role == kAXStaticTextRole as String else { continue }
            guard let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: child),
                  !text.isEmpty else { continue }
            guard let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: child),
                  !frame.isEmpty else { continue }
            textRuns.append((text, frame))
        }

        guard !textRuns.isEmpty else { return nil }

        // Find which child contains the caret by matching parent selection against cumulative
        // text lengths. AX selections use UTF-16 offsets, so we match on NSString length.
        let caretOffset = parentSelection.location
        var cumulative = 0
        for run in textRuns {
            let runLen = (run.text as NSString).length
            if caretOffset <= cumulative + runLen {
                let localOffset = caretOffset - cumulative
                let fraction = runLen > 0 ? CGFloat(localOffset) / CGFloat(runLen) : 1.0
                let cocoaFrame = AXHelper.cocoaRect(fromAccessibilityRect: run.frame)
                let caretX = cocoaFrame.minX + fraction * cocoaFrame.width
                return CaretGeometryResult(
                    rect: CGRect(x: caretX, y: cocoaFrame.minY, width: 2, height: cocoaFrame.height),
                    quality: .derived
                )
            }
            cumulative += runLen
        }

        // Caret is past all children (e.g. newline not included in child text).
        // Use the last child's trailing edge.
        let lastFrame = AXHelper.cocoaRect(fromAccessibilityRect: textRuns.last!.frame)
        return CaretGeometryResult(
            rect: CGRect(x: lastFrame.maxX, y: lastFrame.minY, width: 2, height: lastFrame.height),
            quality: .derived
        )
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
