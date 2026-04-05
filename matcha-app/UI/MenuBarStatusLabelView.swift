import SwiftUI

/// File overview:
/// Renders the tiny always-visible menu-bar label. This view stays intentionally separate from
/// the larger menu content so the label can redraw from focus state alone.
///
/// This label lives in its own view because `MenuBarExtra` does not automatically observe
/// plain properties hanging off `AppDelegate`. By observing the models directly here,
/// SwiftUI knows when to redraw the menu bar item.
struct MenuBarStatusLabelView: View {
    @ObservedObject var focusModel: FocusTrackingModel

    /// Renders the app icon reliably bounded to menu-bar dimensions (16x16 or 18x18).
    /// MenuBarExtra ignores SwiftUI `.frame` modifiers on nsImages, so we manually
    /// draw it into a hardcoded NSSize to prevent vertical overflow.
    private var menuIcon: NSImage {
        guard let original = NSImage(named: NSImage.applicationIconName) else { return NSImage() }
        // Copying the image via TIFF and mutating the .size ensures all Retina (2x/3x)
        // representations are preserved natively, unlike lockFocus redraws.
        guard let tiffData = original.tiffRepresentation,
              let crispIcon = NSImage(data: tiffData) else {
            return original
        }
        crispIcon.size = NSSize(width: 24, height: 24)
        return crispIcon
    }

    /// Mirrors the latest focus support state into the menu-bar icon and label.
    var body: some View {
        Image(nsImage: menuIcon)
    }
}
