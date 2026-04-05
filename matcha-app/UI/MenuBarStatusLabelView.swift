import SwiftUI

/// This label lives in its own view because `MenuBarExtra` does not automatically observe
/// plain properties hanging off `AppDelegate`. By observing the models directly here,
/// SwiftUI knows when to redraw the menu bar item.
struct MenuBarStatusLabelView: View {
    @ObservedObject var focusModel: FocusTrackingModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: focusModel.menuBarSymbolName)
            Text(focusModel.menuBarStatusText)
        }
    }
}
