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

    static let requiresPixelToPointScalingBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
        "com.tinyspeck.slackmacgap",
        "com.github.Electron",
        "com.valvesoftware.discord",
        "com.figma.Desktop",
        "com.superhuman.electronic-superman"
    ]

    /// Converts raw Accessibility coordinates into global AppKit points.
    /// Some applications (like Chromium-based browsers) incorrectly return raw physical 
    /// backing pixels for text ranges, so `isTextRect` allows conditionally scaling them back down.
    /// Normalizes raw Accessibility coordinates into global AppKit points and applies per-app scaling fixes.
    static func cocoaRect(fromAccessibilityRect rect: CGRect, bundleIdentifier: String, isTextRect: Bool) -> CGRect {
        guard !rect.isNull, rect != .zero else {
            return rect
        }

        var normalizedRect = rect

        // Chromium often returns physical pixels instead of Cocoa points for text ranges on Retina.
        if isTextRect && requiresPixelToPointScalingBundles.contains(bundleIdentifier) {
            // Find the screen this coordinate falls on (approximate) to determine the scale factor.
            let fallbackScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let scale: CGFloat = NSScreen.screens.first(where: {
                $0.frame.contains(CGPoint(x: rect.origin.x / fallbackScale, y: $0.frame.maxY - (rect.origin.y / fallbackScale)))
            })?.backingScaleFactor ?? fallbackScale
            
            normalizedRect = CGRect(
                x: rect.origin.x / scale,
                y: rect.origin.y / scale,
                width: rect.width / scale,
                height: rect.height / scale
            )
        }

        // Global AX Coordinates have a Top-Left origin relative to the PRIMARY screen.
        // AppKit Coordinates have a Bottom-Left origin relative to the PRIMARY screen.
        // Therefore, we solely use the primary screen's height to flip the Y axis.
        guard let primaryScreen = NSScreen.screens.first else {
            return normalizedRect
        }

        return CGRect(
            x: normalizedRect.origin.x,
            y: primaryScreen.frame.height - normalizedRect.origin.y - normalizedRect.height,
            width: normalizedRect.width,
            height: normalizedRect.height
        )
    }
}
