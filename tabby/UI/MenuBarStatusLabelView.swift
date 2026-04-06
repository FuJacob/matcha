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
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator

    /// Mirrors the latest focus support state into the menu-bar icon and label.
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "pawprint.fill")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .semibold))

            Text("\(suggestionCoordinator.totalTabAcceptedWordCount)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}
