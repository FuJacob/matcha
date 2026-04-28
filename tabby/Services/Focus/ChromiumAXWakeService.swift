import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Opportunistically wakes Chromium-family Accessibility trees before `FocusSnapshotResolver`
/// tries to interpret them.
///
/// Architectural role:
/// - `FocusTracker` decides *when* the frontmost app should be inspected.
/// - `ChromiumAXWakeService` performs the side effect needed to make Chromium/Electron apps expose
///   a usable tree in the first place.
/// - `FocusSnapshotResolver` stays pure with respect to host-app mutation and only interprets AX.
///
/// This separation matters because "pick the best AX node" and "mutate the host app so it exposes
/// more AX nodes" are different responsibilities with different failure modes.
@MainActor
final class ChromiumAXWakeService {
    /// Tunables for the wake-up loop.
    ///
    /// The timer in `FocusTracker` is already the coarse poll driver for this subsystem, so this
    /// configuration expresses *policy* rather than spinning up more timers here.
    struct Configuration {
        /// How long we wait for `AXChildren` to become non-empty after setting the wake flag before
        /// treating the attempt as a likely silent no-op.
        let confirmationTimeout: TimeInterval
        /// How long to back off before retrying a process whose wake attempt appears to have done
        /// nothing. This avoids hammering the target process on every focus poll tick.
        let retryCooldown: TimeInterval
        /// Defensive cap for walking Chromium descendants in search of renderer-owned AX elements.
        let maxRendererSearchDepth: Int
        /// Defensive cap on total nodes visited during the renderer walk.
        let maxRendererSearchNodes: Int

        static let standard = Configuration(
            confirmationTimeout: 0.3,
            retryCooldown: 0.5,
            maxRendererSearchDepth: 8,
            maxRendererSearchNodes: 250
        )
    }

    /// One PID can be in only one wake state at a time.
    private enum WakeStatus {
        case pending(startedAt: Date)
        case coolingDown(until: Date)
        case ready
    }

    /// The wake cache is process-scoped, not bundle-scoped, because Electron frequently replaces
    /// renderer processes underneath the same app bundle.
    private struct WakeRecord {
        let bundleIdentifier: String
        let targetDescription: String
        var status: WakeStatus
    }

    /// Represents one AX element whose owning process should receive the `AXManualAccessibility`
    /// flag. We keep the current element instance with the PID because the flag is set on AX
    /// elements, while the durable cache key is the process identifier.
    private struct WakeTarget {
        let processIdentifier: pid_t
        let element: AXUIElement
        let description: String
    }

    private let configuration: Configuration
    private var wakeRecords: [pid_t: WakeRecord] = [:]

    init(configuration: Configuration? = nil) {
        self.configuration = configuration ?? .standard
    }

    /// Applies Chromium-specific AX wake logic for the frontmost application when appropriate.
    ///
    /// The service is intentionally opportunistic: it primes the tree if needed, but it does not
    /// block focus polling while waiting for Chromium to comply. Later poll ticks will observe the
    /// now-awake tree through the normal resolver path.
    func prepareIfNeeded(for application: NSRunningApplication) {
        guard ChromiumAccessibilityBundleCatalog.contains(application.bundleIdentifier) else {
            return
        }

        let bundleIdentifier = application.bundleIdentifier ?? "unknown.bundle"
        let appElement = AXHelper.applicationElement(for: application.processIdentifier)
        let targets = wakeTargets(
            for: application.processIdentifier,
            appElement: appElement
        )

        for target in targets {
            advanceWakeState(
                for: target,
                bundleIdentifier: bundleIdentifier,
                now: Date()
            )
        }
    }

    /// Advances one PID through the small wake state machine.
    private func advanceWakeState(
        for target: WakeTarget,
        bundleIdentifier: String,
        now: Date
    ) {
        let hasChildren = !AXHelper.childElements(of: target.element).isEmpty

        if case .ready = wakeRecords[target.processIdentifier]?.status {
            return
        }

        if case let .pending(startedAt)? = wakeRecords[target.processIdentifier]?.status {
            if hasChildren {
                wakeRecords[target.processIdentifier] = WakeRecord(
                    bundleIdentifier: bundleIdentifier,
                    targetDescription: target.description,
                    status: .ready
                )
                return
            }

            if now.timeIntervalSince(startedAt) < configuration.confirmationTimeout {
                return
            }

            debugLog(
                "wake timeout bundle=\(bundleIdentifier) target=\(target.description)"
            )
            wakeRecords[target.processIdentifier] = WakeRecord(
                bundleIdentifier: bundleIdentifier,
                targetDescription: target.description,
                status: .coolingDown(until: now.addingTimeInterval(configuration.retryCooldown))
            )
            return
        }

        if case let .coolingDown(until)? = wakeRecords[target.processIdentifier]?.status,
           now < until
        {
            return
        }

        let result = AXHelper.setBoolValue(
            true,
            for: "AXManualAccessibility" as CFString,
            on: target.element
        )

        if result != .success {
            // Chromium sometimes returns transient AX errors while its window tree is still
            // materializing. Backing off and retrying later is safer than permanently marking the
            // process failed after one early write attempt.
            debugLog(
                "wake write failed bundle=\(bundleIdentifier) target=\(target.description) error=\(result.rawValue)"
            )
            wakeRecords[target.processIdentifier] = WakeRecord(
                bundleIdentifier: bundleIdentifier,
                targetDescription: target.description,
                status: .coolingDown(until: now.addingTimeInterval(configuration.retryCooldown))
            )
            return
        }

        let status: WakeStatus = hasChildren ? .ready : .pending(startedAt: now)
        wakeRecords[target.processIdentifier] = WakeRecord(
            bundleIdentifier: bundleIdentifier,
            targetDescription: target.description,
            status: status
        )
    }

    /// Builds the wake target list for one Chromium-family app.
    ///
    /// We always include the top-level app process. For Electron 28+ and similar shells we also
    /// walk down the tree and set the same flag on any renderer-owned AX element we encounter.
    /// The PID-level cache ensures each process is only woken once after a successful confirmation.
    private func wakeTargets(
        for applicationProcessIdentifier: pid_t,
        appElement: AXUIElement
    ) -> [WakeTarget] {
        var targets: [WakeTarget] = [
            WakeTarget(
                processIdentifier: applicationProcessIdentifier,
                element: appElement,
                description: "app(pid=\(applicationProcessIdentifier))"
            )
        ]

        var queue: [(element: AXUIElement, depth: Int)] = [(appElement, 0)]
        var visitedNodeCount = 0
        var seenElements = Set<String>()
        var seenProcesses: Set<pid_t> = [applicationProcessIdentifier]

        while !queue.isEmpty, visitedNodeCount < configuration.maxRendererSearchNodes {
            let (element, depth) = queue.removeFirst()
            let identity = AXHelper.elementIdentity(for: element)
            guard seenElements.insert(identity).inserted else {
                continue
            }

            visitedNodeCount += 1

            if let processIdentifier = AXHelper.processIdentifier(for: element),
               processIdentifier != applicationProcessIdentifier,
               seenProcesses.insert(processIdentifier).inserted
            {
                let role = AXHelper.stringValue(
                    for: kAXRoleAttribute as CFString,
                    on: element
                ) ?? "Unknown"
                targets.append(
                    WakeTarget(
                        processIdentifier: processIdentifier,
                        element: element,
                        description: "renderer(pid=\(processIdentifier), role=\(role))"
                    )
                )
            }

            guard depth < configuration.maxRendererSearchDepth else {
                continue
            }

            for child in AXHelper.childElements(of: element) {
                queue.append((child, depth + 1))
            }
        }

        return targets
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[ChromiumAXWake] \(message)")
        #endif
    }
}
