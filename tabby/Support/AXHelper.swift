import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Wraps the low-level Accessibility APIs behind Swift-friendly helpers for typed values,
/// tree traversal, element identity, and coordinate normalization. This file intentionally
/// contains the "ugly edge" of interacting with AX.
///
/// Wraps raw Accessibility APIs so the rest of the codebase can stay mostly Swift-native.
/// AX APIs traffic in loosely typed Core Foundation values, so this file is intentionally the "ugly edge".
enum AXHelper {
    private static let knownEditableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXSearchField",
        kAXComboBoxRole as String,
    ]

    private static let knownReadOnlyRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXImageRole as String,
        kAXButtonRole as String,
        "AXLink",
        kAXMenuItemRole as String,
    ]

    static func attributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let names else {
            return []
        }

        return names as? [String] ?? []
    }

    static func parameterizedAttributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyParameterizedAttributeNames(element, &names)
        guard result == .success, let names else {
            return []
        }

        return names as? [String] ?? []
    }

    /// Reads a string AX attribute when the underlying value is present and type-compatible.
    static func stringValue(for attribute: CFString, on element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(attribute, on: element) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    static func boolValue(for attribute: CFString, on element: AXUIElement) -> Bool? {
        guard let number = copyAttributeValue(attribute, on: element) as? NSNumber else {
            return nil
        }

        return number.boolValue
    }

    /// Reads an `AXValue`-backed range attribute such as the current selection.
    static func rangeValue(for attribute: CFString, on element: AXUIElement) -> NSRange? {
        guard let rawValue = copyAttributeValue(attribute, on: element),
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return NSRange(location: range.location, length: range.length)
    }

    /// Reads an `AXValue`-backed rectangle attribute such as `AXFrame`.
    static func rectValue(for attribute: CFString, on element: AXUIElement) -> CGRect? {
        guard let rawValue = copyAttributeValue(attribute, on: element),
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    /// Reads a parameterized rectangle attribute such as `AXBoundsForRange`.
    static func parameterizedRectValue(
        for attribute: CFString,
        range: NSRange,
        on element: AXUIElement
    ) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    /// Some applications (like Chromium and WebKit browsers) do not properly support `AXBoundsForRange`
    /// using `NSRange`. Instead, they use a private, undocumented Accessibility object called `AXTextMarker`.
    /// 
    /// To get the caret rect from these apps, we must:
    /// 1. Ask for `AXSelectedTextMarkerRange` (which returns an opaque `AXTextMarkerRange`).
    /// 2. Pass that marker range back to the element using `AXBoundsForTextMarkerRange`.
    /// 
    /// This bypasses the need to translate `NSRange` manually and forces the browser to resolve
    /// the physical layout of its own internal selection object.
    static func textMarkerCaretRect(on element: AXUIElement) -> CGRect? {
        // 1. Get the opaque AXTextMarkerRange that represents the current selection/caret.
        let selectedMarkerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
        var markerRangeValue: CFTypeRef?
        
        var result = AXUIElementCopyAttributeValue(element, selectedMarkerRangeAttribute, &markerRangeValue)
        guard result == .success, let markerRange = markerRangeValue else {
            return nil
        }
        
        // 2. Ask the element to compute the bounding box for that exact text marker range.
        let boundsForMarkerRangeAttribute = "AXBoundsForTextMarkerRange" as CFString
        var boundsValue: CFTypeRef?
        
        result = AXUIElementCopyParameterizedAttributeValue(element, boundsForMarkerRangeAttribute, markerRange, &boundsValue)
        guard result == .success, let bounds = boundsValue, CFGetTypeID(bounds) == AXValueGetTypeID() else {
            return nil
        }
        
        let axBounds = bounds as! AXValue
        guard AXValueGetType(axBounds) == .cgRect else {
            return nil
        }
        
        var rect = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &rect) else {
            return nil
        }
        
        return rect
    }

    static func copyAttributeValue(_ attribute: CFString, on element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }

        return value as AnyObject?
    }

    /// Returns the currently focused UI element from the system-wide AX object.
    static func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let element = value else {
            return nil
        }

        guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        // `AXUIElement` is a Core Foundation type, so this cast stays in the CF world rather than Swift class casting.
        return unsafeBitCast(element, to: AXUIElement.self)
    }

    static func parentElement(of element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(kAXParentAttribute as CFString, on: element) else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let values = copyAttributeValue(kAXChildrenAttribute as CFString, on: element) as? [AnyObject] else {
            return []
        }

        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    static func elementIdentity(for element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return "\(pid)-\(CFHash(element))"
    }

    /// Builds a stable identifier for an AX element by combining bundle identity and AX identity.
    static func elementIdentifier(for element: AXUIElement, bundleIdentifier: String) -> String {
        "\(bundleIdentifier)-\(elementIdentity(for: element))"
    }

    static func editabilityHintScore(role: String, explicitEditableFlag: Bool?) -> Int {
        var score = 0

        if explicitEditableFlag == true {
            score += 10
        }

        if isKnownEditableRole(role) {
            score += 1
        }

        return score
    }

    /// A strong editability signal is what separates a real input target from display text that merely exposes AX metadata.
    static func hasStrongEditabilitySignal(role: String, explicitEditableFlag: Bool?) -> Bool {
        explicitEditableFlag == true || isKnownEditableRole(role)
    }

    static func isKnownEditableRole(_ role: String) -> Bool {
        knownEditableRoles.contains(role)
    }

    static func isKnownReadOnlyRole(_ role: String) -> Bool {
        knownReadOnlyRoles.contains(role)
    }

    /// Converts raw Accessibility coordinates into global AppKit points via a simple Y-flip.
    /// Use this for element-level rects (AXFrame) that are reliably in Cocoa points.
    /// For text-range rects (BoundsForRange, TextMarker), use `validatedCocoaTextRect` instead.
    static func cocoaRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        guard !rect.isNull, rect != .zero else {
            return rect
        }

        let desktopBounds = desktopUnionFrame()
        guard !desktopBounds.isNull else {
            return rect
        }

        return CGRect(
            x: rect.origin.x,
            y: desktopBounds.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a text-range AX rect to Cocoa coordinates, using the element's AXFrame (already
    /// in Cocoa coordinates) as a ground-truth anchor to detect whether pixel-to-point scaling
    /// is needed. This replaces the old bundle-ID heuristic with empirical geometric validation:
    ///   1. Y-flip the raw rect (no scaling) and check if it lands inside the anchor.
    ///   2. If not, divide by the Retina backing scale factor, Y-flip, and recheck.
    ///   3. Whichever version falls near the anchor wins. Falls back to unscaled if neither fits.
    static func validatedCocoaTextRect(
        fromAccessibilityRect textRect: CGRect,
        anchorFrame cocoaAnchorFrame: CGRect?
    ) -> CGRect {
        guard !textRect.isNull, textRect != .zero else {
            return textRect
        }

        let desktopBounds = desktopUnionFrame()
        guard !desktopBounds.isNull else {
            return textRect
        }

        // Candidate A: plain Y-flip, assuming the AX rect is already in Cocoa points.
        let flipped = CGRect(
            x: textRect.origin.x,
            y: desktopBounds.maxY - textRect.origin.y - textRect.height,
            width: textRect.width,
            height: textRect.height
        )

        guard let anchor = cocoaAnchorFrame, !anchor.isEmpty else {
            // No anchor available — plain Y-flip is the safest default.
            return flipped
        }

        // Generous tolerance so padding, scrolling, and multi-line fields don't cause false negatives.
        let tolerance: CGFloat = 80
        let expandedAnchor = anchor.insetBy(dx: -tolerance, dy: -tolerance)

        if expandedAnchor.contains(CGPoint(x: flipped.midX, y: flipped.midY)) {
            return flipped
        }

        // Candidate B: divide by backing scale factor first (Chromium pixel-space workaround),
        // then Y-flip. Some apps return physical pixels for text ranges on Retina.
        let fallbackScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let scale: CGFloat = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(
                x: textRect.origin.x / fallbackScale,
                y: $0.frame.maxY - (textRect.origin.y / fallbackScale)
            ))
        })?.backingScaleFactor ?? fallbackScale

        let scaled = CGRect(
            x: textRect.origin.x / scale,
            y: textRect.origin.y / scale,
            width: textRect.width / scale,
            height: textRect.height / scale
        )
        let scaledFlipped = CGRect(
            x: scaled.origin.x,
            y: desktopBounds.maxY - scaled.origin.y - scaled.height,
            width: scaled.width,
            height: scaled.height
        )

        if expandedAnchor.contains(CGPoint(x: scaledFlipped.midX, y: scaledFlipped.midY)) {
            return scaledFlipped
        }

        // Neither candidate landed near the anchor. Return unscaled as best-effort.
        return flipped
    }

    /// Union of all connected screen frames — used for AX top-left → Cocoa bottom-left conversion.
    private static func desktopUnionFrame() -> CGRect {
        NSScreen.screens
            .map(\.frame)
            .reduce(into: CGRect.null) { $0 = $0.union($1) }
    }
}
