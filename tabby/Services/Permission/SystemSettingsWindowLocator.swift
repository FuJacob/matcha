import AppKit
import CoreGraphics
import Foundation

/// Snapshot of the frontmost System Settings window in AppKit coordinate space.
///
/// `CGWindowListCopyWindowInfo` reports global bounds in Core Graphics coordinates, which use a
/// different Y-axis origin from AppKit. This snapshot stores the converted frame plus the visible
/// screen frame needed to clamp overlay placement safely on multi-monitor setups.
struct SystemSettingsWindowSnapshot: Equatable {
    let processIdentifier: pid_t
    let frame: CGRect
    let visibleFrame: CGRect
}

/// Finds the active System Settings window so the onboarding overlay can stay visually attached to
/// the correct privacy pane as the user moves or resizes it.
enum SystemSettingsWindowLocator {
    static let bundleIdentifier = "com.apple.systempreferences"

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    static func frontmostWindow() -> SystemSettingsWindowSnapshot? {
        guard isFrontmost else {
            return nil
        }

        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .max(by: { activationPriority(of: $0) < activationPriority(of: $1) }) else {
            return nil
        }

        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            .zero
        ) as? [[String: Any]] else {
            return nil
        }

        let candidateWindows = windowInfo.compactMap { info -> SystemSettingsWindowSnapshot? in
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == application.processIdentifier,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else {
                return nil
            }

            let coreGraphicsFrame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            let convertedGeometry = appKitGeometry(from: coreGraphicsFrame)
            let frame = convertedGeometry.frame
            guard frame.width > 320, frame.height > 240 else {
                return nil
            }

            return SystemSettingsWindowSnapshot(
                processIdentifier: ownerPID,
                frame: frame,
                visibleFrame: convertedGeometry.visibleFrame
            )
        }

        return candidateWindows.max(by: { area(of: $0.frame) < area(of: $1.frame) })
    }

    private static func activationPriority(of application: NSRunningApplication) -> Int {
        application.activationPolicy == .prohibited ? 0 : 1
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    /// Named container for per-screen AppKit and CoreGraphics geometry.
    /// Replaces a 3-member tuple so compactMap closures can name members explicitly.
    private struct ScreenGeometry {
        let frame: CGRect
        let visibleFrame: CGRect
        let displayBounds: CGRect
    }

    private static func appKitGeometry(from coreGraphicsFrame: CGRect) -> (frame: CGRect, visibleFrame: CGRect) {
        let screens = NSScreen.screens.compactMap { screen -> ScreenGeometry? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return ScreenGeometry(
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                displayBounds: CGDisplayBounds(displayID)
            )
        }

        let matchedScreen = screens
            .filter { $0.displayBounds.intersects(coreGraphicsFrame) }
            .max { lhs, rhs in
                lhs.displayBounds.intersection(coreGraphicsFrame).width
                    * lhs.displayBounds.intersection(coreGraphicsFrame).height
                    < rhs.displayBounds.intersection(coreGraphicsFrame).width
                    * rhs.displayBounds.intersection(coreGraphicsFrame).height
            }

        guard let matchedScreen else {
            let mainVisibleFrame = NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: coreGraphicsFrame.size)
            return (frame: coreGraphicsFrame, visibleFrame: mainVisibleFrame)
        }

        let localX = coreGraphicsFrame.minX - matchedScreen.displayBounds.minX
        let localY = coreGraphicsFrame.minY - matchedScreen.displayBounds.minY
        let frame = CGRect(
            x: matchedScreen.frame.minX + localX,
            y: matchedScreen.frame.maxY - localY - coreGraphicsFrame.height,
            width: coreGraphicsFrame.width,
            height: coreGraphicsFrame.height
        )

        return (frame: frame, visibleFrame: matchedScreen.visibleFrame)
    }
}
