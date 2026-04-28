import Foundation

/// File overview:
/// Centralizes the bundle identifiers that should receive Chromium-specific Accessibility wake-up
/// behavior.
///
/// Keeping this list in `Support/` is intentional. Whether a bundle *belongs* to the Chromium
/// compatibility set is a pure classification rule, while the act of touching Accessibility state
/// belongs in `Services/`. Splitting those concerns keeps the side-effectful wake service small
/// and gives us a pure seam that unit tests can pin down.
enum ChromiumAccessibilityBundleCatalog {
    /// Exact bundle identifiers for Chromium browsers and well-known Electron shells we actively
    /// test or expect to support.
    private static let exactMatches: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.vscodium",
        "com.hnc.Discord",
        "com.hnc.DiscordPTB",
        "com.hnc.DiscordCanary",
        "com.todesktop.230313mzl4w4u92",
        "com.linear",
    ]

    /// Prefix matches cover release channels that keep a stable family prefix while varying the
    /// suffix, such as Edge's Stable/Beta/Dev/Canary builds.
    private static let prefixMatches: [String] = [
        "com.microsoft.edgemac",
    ]

    /// Returns whether the provided bundle identifier should go through the Chromium AX wake path.
    static func contains(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }

        if exactMatches.contains(bundleIdentifier) {
            return true
        }

        return prefixMatches.contains { bundleIdentifier.hasPrefix($0) }
    }
}
