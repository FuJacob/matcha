import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Resolves the most usable editable candidate around the current AX focus and materializes a
/// stable `FocusSnapshot`. This keeps AX candidate search and snapshot assembly separate from the
/// timer-driven polling shell in `FocusTracker`.
@MainActor
struct FocusSnapshotResolver {
    private let geometryResolver: AXTextGeometryResolver

    init(geometryResolver: AXTextGeometryResolver? = nil) {
        // Construct the default geometry helper inside the actor-isolated initializer for the same
        // reason described in `FocusTracker`: default argument evaluation is not actor-isolated.
        self.geometryResolver = geometryResolver ?? AXTextGeometryResolver()
    }

    /// Resolves the best editable candidate around the focused AX node and materializes a focus snapshot.
    func resolveSnapshot(
        focusedElement: AXUIElement,
        application: NSRunningApplication
    ) -> FocusSnapshot {
        let applicationName = application.localizedName ?? "Unknown"
        let bundleIdentifier = application.bundleIdentifier ?? "unknown.bundle"
        let focusedRole = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: focusedElement) ?? "Unknown"
        let focusedSubrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: focusedElement)
        let focusedElementIdentifier = AXHelper.elementIdentifier(for: focusedElement, bundleIdentifier: bundleIdentifier)

        let candidates = candidateElements(around: focusedElement).map {
            candidateSnapshot(for: $0, bundleIdentifier: bundleIdentifier)
        }
        let resolution = FocusCapabilityResolver.resolve(candidates: candidates.map(\.resolverCandidate))
        let selectedCandidate = resolution.bestDiagnosticCandidate.flatMap { candidate in
            candidates.first(where: { $0.elementIdentifier == candidate.elementIdentifier })
        }
        let inspection = FocusInspectionSnapshot(
            focusedElementIdentifier: focusedElementIdentifier,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            resolvedElementIdentifier: selectedCandidate?.elementIdentifier,
            resolvedRole: selectedCandidate?.role,
            resolvedSubrole: selectedCandidate?.subrole,
            missingCapabilities: resolution.resolvedCandidate == nil ? resolution.missingCapabilities : []
        )

        guard let resolvedCandidate = selectedCandidate,
              resolution.resolvedCandidate != nil
        else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported(resolution.unsupportedReason),
                context: nil,
                inspection: inspection
            )
        }

        guard let selection = resolvedCandidate.selection else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        guard selection.location >= 0, selection.length >= 0 else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is invalid."),
                context: nil,
                inspection: inspection
            )
        }

        let value = resolvedCandidate.textValue ?? ""
        // `NSRange` coming from AX is expressed in UTF-16 code units, which is why the code below
        // uses `NSString` instead of slicing a native Swift `String` directly.
        guard selection.location <= value.utf16.count else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range exceeds the current field value."),
                context: nil,
                inspection: inspection
            )
        }

        guard let caretRect = resolvedCandidate.caretRect else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Caret bounds are unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        let nsValue = value as NSString
        let safeSelectionLocation = min(selection.location, nsValue.length)
        let trailingStart = min(selection.location + selection.length, nsValue.length)
        let context = FocusedInputSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(application.processIdentifier),
            elementIdentifier: resolvedCandidate.elementIdentifier,
            role: resolvedCandidate.role,
            subrole: resolvedCandidate.subrole,
            caretRect: caretRect,
            inputFrameRect: resolvedCandidate.inputFrameRect,
            precedingText: nsValue.substring(to: safeSelectionLocation),
            trailingText: nsValue.substring(from: trailingStart),
            selection: selection,
            isSecure: resolvedCandidate.isSecure
        )

        if resolvedCandidate.isSecure {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Secure text input is active."),
                context: context,
                inspection: inspection
            )
        }

        if selection.length > 0 {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Text is currently selected."),
                context: context,
                inspection: inspection
            )
        }

        return FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: .supported,
            context: context,
            inspection: inspection
        )
    }

    private func candidateElements(around focusedElement: AXUIElement) -> [AXUIElement] {
        var ordered: [AXUIElement] = []
        var seen = Set<String>()

        func append(_ element: AXUIElement?) {
            guard let element else {
                return
            }

            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else {
                return
            }

            ordered.append(element)
        }

        append(focusedElement)

        var ancestors: [AXUIElement] = []
        var currentElement = focusedElement
        for _ in 0 ..< 2 {
            guard let parent = AXHelper.parentElement(of: currentElement) else {
                break
            }

            ancestors.append(parent)
            append(parent)
            currentElement = parent
        }

        // The heuristic search order is:
        // 1. focused node
        // 2. a couple of ancestors
        // 3. children of those nodes
        //
        // This is a pragmatic compromise for apps that focus a wrapper element instead of the real
        // editable text node. We do not try to walk the entire AX tree.
        for node in [focusedElement] + ancestors {
            for child in AXHelper.childElements(of: node) {
                append(child)
            }
        }

        return ordered
    }

    /// Extracts the AX properties Tabby needs from one candidate element near the current focus.
    private func candidateSnapshot(for element: AXUIElement, bundleIdentifier: String) -> AXFocusCandidate {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "Unknown"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let supportedAttributes = Set(AXHelper.attributeNames(on: element))
        let supportedParameterizedAttributes = Set(AXHelper.parameterizedAttributeNames(on: element))
        let explicitEditableFlag = supportedAttributes.contains("AXEditable")
            ? AXHelper.boolValue(for: "AXEditable" as CFString, on: element)
            : nil
        let textValue = supportedAttributes.contains(kAXValueAttribute as String)
            ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
            : nil
        let selection = supportedAttributes.contains(kAXSelectedTextRangeAttribute as String)
            ? AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
            : nil
        let inputFrameRect = supportedAttributes.contains("AXFrame")
            ? geometryResolver.resolveInputFrameRect(for: element)
            : nil
        let caretRect = selection.flatMap {
            geometryResolver.resolveCaretRect(
                for: element,
                selection: $0,
                supportsBoundsForRange: supportedParameterizedAttributes.contains(kAXBoundsForRangeParameterizedAttribute as String),
                supportsFrame: supportedAttributes.contains("AXFrame"),
                cocoaAnchorFrame: inputFrameRect,
                textValue: textValue
            )
        }
        let isSecure = isSecureElement(element: element, role: role, subrole: subrole)
        let elementIdentifier = AXHelper.elementIdentifier(for: element, bundleIdentifier: bundleIdentifier)
        let resolverCandidate = FocusCapabilityCandidate(
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            editableHintScore: AXHelper.editabilityHintScore(role: role, explicitEditableFlag: explicitEditableFlag),
            hasStrongEditabilitySignal: AXHelper.hasStrongEditabilitySignal(role: role, explicitEditableFlag: explicitEditableFlag),
            isKnownReadOnlyRole: AXHelper.isKnownReadOnlyRole(role),
            hasTextValue: textValue != nil,
            hasSelectionRange: selection != nil,
            hasCaretBounds: caretRect != nil,
            isSecure: isSecure
        )

        return AXFocusCandidate(
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            textValue: textValue,
            selection: selection,
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            isSecure: isSecure,
            resolverCandidate: resolverCandidate
        )
    }

    /// Detects secure inputs so Tabby can intentionally refuse to operate in sensitive fields.
    private func isSecureElement(element: AXUIElement, role: String, subrole: String?) -> Bool {
        // There is no single universal secure-input flag across all host apps, so we fall back to
        // conservative string matching on the AX metadata that browsers and native apps commonly expose.
        let secureMarkers = [
            role.lowercased(),
            subrole?.lowercased() ?? "",
            AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)?.lowercased() ?? "",
            AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element)?.lowercased() ?? "",
        ]

        return secureMarkers.contains { marker in
            marker.contains("secure") || marker.contains("password")
        }
    }
}

/// AX data read from one candidate element near the current focus.
/// This keeps candidate search state local to the resolver instead of leaking it into the tracker.
private struct AXFocusCandidate {
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let textValue: String?
    let selection: NSRange?
    let caretRect: CGRect?
    let inputFrameRect: CGRect?
    let isSecure: Bool
    let resolverCandidate: FocusCapabilityCandidate
}
