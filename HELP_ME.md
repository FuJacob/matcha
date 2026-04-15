# Caret Geometry Handoff

This document is the handoff for the current caret-placement investigation in Tabby.

It is written for the next engineer picking up the Accessibility focus/geometry work, not for end users.

## Goal

Tabby needs to place ghost text at the real text insertion point across macOS apps using the current non-IME architecture.

Current product constraints:

- Stay on the normal app architecture.
- Do not switch to an Input Method / IME-based solution.
- Do not require the user to install and enable a custom input source.
- Primary OS boundary remains Accessibility.

That means the practical requirement is:

1. Resolve the focused editable AX node.
2. Resolve a real caret rect, not just a field frame.
3. Position overlay text off that caret rect.

## Core Problem

Some hosts expose real caret geometry through Accessibility. Others expose partial or misleading geometry.

The hardest failure mode is Chromium-based editors:

- The AX node often advertises text-related capabilities.
- The node may expose `AXSelectedTextMarkerRange` and marker-related parameterized attributes.
- But the live geometry calls do not consistently return a usable caret rect.

This creates a dangerous false positive:

- The element *looks* capable based on attribute names.
- But the actual bounds queries fail or return broad container geometry.
- If Tabby trusts that geometry, the overlay is visibly wrong.

The investigation so far has mostly been about separating:

- real caret geometry
- derived-but-still-plausible caret geometry
- fake/container geometry
- no real caret geometry at all

## Current Focus Pipeline

The relevant files are:

- `tabby/Services/Focus/FocusTracker.swift`
- `tabby/Services/Focus/FocusSnapshotResolver.swift`
- `tabby/Services/Focus/AXTextGeometryResolver.swift`
- `tabby/Support/AXHelper.swift`
- `tabby/Support/FocusCapabilityResolver.swift`
- `tabby/Services/Focus/FocusGeometryDebugLogger.swift`
- `tabby/Services/UI/FocusDebugOverlayController.swift`
- `tabby/Models/FocusModels.swift`
- `tabby/Models/FocusGeometryModels.swift`

High-level flow:

1. `FocusTracker` polls the focused AX element.
2. `FocusSnapshotResolver` searches nearby AX candidates and chooses the best editable target.
3. `AXTextGeometryResolver` tries multiple caret-geometry branches in priority order.
4. `FocusCapabilityResolver` decides whether the chosen candidate truly supports Tabby.
5. Debug logging and the overlay show what the resolver believed.

## Debugging Infrastructure Added

These were added during this investigation so the next engineer can continue from a better baseline.

### 1. Structured geometry diagnostics

Added `FocusGeometryDiagnostics` and related types in:

- `tabby/Models/FocusGeometryModels.swift`

This records:

- every attempted caret-resolution branch
- raw AX rect
- converted Cocoa rect
- final caret rect
- geometry quality
- plausibility
- branch notes

### 2. Reduced, high-signal geometry logger

Added and then trimmed:

- `tabby/Services/Focus/FocusGeometryDebugLogger.swift`

The logger now prints:

- one `[FocusGeometry]` summary line
- one `[FocusGeometry details]` block
- one `[FocusRelevantCandidates]` block

The noisy AX candidate dump was intentionally removed because it was hiding the useful information.

### 3. Visual debug overlay

Added:

- `tabby/Services/UI/FocusDebugOverlayController.swift`

This shows:

- input frame
- source rect
- caret rect
- the winning branch
- diagnostic notes

### 4. Launch-argument gated diagnostics

Wired through:

- `tabby/App/Core/AppDelegate.swift`

Useful debug launch arguments:

- `-tabby-log-focus-geometry`
- `-tabby-show-focus-debug-overlay`

## Branches Tabby Currently Tries

The current branch order in `AXTextGeometryResolver` is:

1. `AXBoundsForRange` on a zero-length current selection
2. `AXSelectedTextMarkerRange` + `AXBoundsForTextMarkerRange`
3. previous-character `AXBoundsForRange`
4. `AXFrame` estimate

This ordering is intentional:

- `BoundsForRange @ caret` is the cleanest direct caret signal.
- `AXTextMarker` is needed for browser-style hosts that do not behave like AppKit text controls.
- previous-character bounds are a valid derived fallback.
- field-frame estimation is diagnostic/weak and should not count as true caret support.

## Major Findings So Far

## Finding 1: `AXFrame` is not caret support

This was the most important architectural correction.

Earlier behavior treated a frame-based estimate as if it were enough to classify a field as supported. That was wrong.

What changed:

- `FocusCapabilityResolver` now scores geometry using `FocusCaretGeometryQuality`.
- Only `.exact` and `.derived` satisfy the caret requirement.
- `.estimated` no longer counts as real caret capability.

Why this matters:

- It prevents Tabby from claiming “supported” when it only knows the field frame.
- It turns a subtle placement bug into an explicit unsupported-state, which is more honest and easier to debug.

Relevant file:

- `tabby/Support/FocusCapabilityResolver.swift`

## Finding 2: Chrome sometimes returned the whole editable box as “caret” geometry

This was a real bug in Tabby’s interpretation.

Observed behavior:

- In Chrome, the `AXTextMarker` branch sometimes returned a rect roughly equal to the whole input area.
- Example shape: width and height close to the full field frame.
- Tabby was collapsing that rect to its left edge and calling the result an exact caret.

That produced clearly wrong overlay placement.

What changed:

- `AXTextGeometryResolver` now compares marker rects against the anchor input frame.
- If the marker rect materially matches the field container, it is treated as a broad container/line fragment, not exact caret geometry.
- The resolver then attempts adjacent-marker derivation instead.

Relevant file:

- `tabby/Services/Focus/AXTextGeometryResolver.swift`

## Finding 3: Attribute presence is not the same as runtime usability

This is the main lesson from Chrome.

The logs show cases where the selected candidate advertises:

- `boundsForRange=true`
- `selectedMarkerRange=true`
- `markerBounds=true`

But the actual live calls still produce:

- zero rect from `AXBoundsForRange`
- nil or unusable result from `AXBoundsForTextMarkerRange`
- failed adjacent-marker derivation

So the current rule is:

- capability names are hints
- actual geometry calls are the truth

This is why the geometry-quality model was necessary.

## Finding 4: Expanding candidate search was useful, but not the core Chrome fix

The local AX neighborhood search was widened in `FocusSnapshotResolver`:

- focused element
- up to 2 ancestors
- BFS into nearby descendants
- `maxDepth = 3`
- `maxNodes = 64`

This was worth doing because browser editors often focus a wrapper while the real editable node is nearby.

However, it did **not** solve the Chrome failure by itself.

Why:

- the logs already showed multiple nearby candidates with marker support
- the runtime geometry calls on those candidates still failed

So “search wider” was not the main bug. It improved the search space but did not produce a reliable caret in the failing Chrome surface.

Relevant file:

- `tabby/Services/Focus/FocusSnapshotResolver.swift`

## Finding 5: Xcode is a separate issue from Chrome

Xcode often resolves exact caret geometry correctly using `AXBoundsForRange`.

Representative behavior:

- `BoundsForRange @ caret = Exact`
- `previous char = Derived`
- `AXTextMarker = Unavailable`

This is normal and acceptable.

However, there are logs where Xcode still ends up as `capability=Unsupported` even though the geometry is exact.

That means:

- the geometry resolver is doing its job
- the later capability/snapshot validation is still rejecting something

This is a separate downstream bug and should not be mixed into the Chrome marker investigation.

Likely places to inspect:

- `FocusSnapshotResolver.resolveSnapshot(...)`
- the candidate chosen for `resolvedCandidate` vs the candidate used in the final context
- text value / selection range / secure / selection-length blocking logic

## Trials And Changes Already Landed

The following changes are already in the codebase.

## Trial 1: Add structured diagnostics and visual overlay

Status: landed

Purpose:

- Stop guessing.
- See exactly which branch won and what rect it used.

Outcome:

- High value.
- Keep this.

## Trial 2: Distinguish geometry quality

Status: landed

Added:

- `FocusCaretGeometryQuality.unavailable`
- `FocusCaretGeometryQuality.exact`
- `FocusCaretGeometryQuality.derived`
- `FocusCaretGeometryQuality.estimated`

Outcome:

- High value.
- This fixed a real classification bug.

## Trial 3: Widen local candidate search

Status: landed

Outcome:

- Useful improvement.
- Not enough on its own for Chromium.

## Trial 4: Detect broad/container marker rects

Status: landed

Outcome:

- High value.
- Prevented false “exact caret” wins on Chrome.

## Trial 5: Try adjacent-marker derivation for line/container marker rects

Status: landed

Outcome:

- Correct strategy.
- Sometimes succeeds in browser-style hosts.
- In the failing Chrome surface we are discussing, it still often fails.

## Trial 6: Try adjacent-marker derivation even when selected marker bounds are nil

Status: landed

This was important because the previous implementation gave up too early.

New behavior:

- if `AXSelectedTextMarkerRange` exists but its own bounds call fails
- Tabby still tries previous/next-marker derivation before returning unavailable

Outcome:

- Better diagnostic coverage.
- Need fresh logs after this change to see the exact failure note in Chrome.

## Chrome Logs: What They Mean

The latest Chrome logs mean:

- `BoundsForRange @ caret` returns zero rect
- selected candidate still exposes marker-related attributes
- marker branch is now not trusted when it only produces a broad/container rect
- current failing case ends with `AXFrame estimate`

Interpretation:

- We successfully removed one false positive
- but we still do not have reliable real caret geometry for that Chrome surface

The open question is now narrower:

- does adjacent-marker derivation ever produce usable geometry on this exact Chrome editor?
- or is this host simply refusing to provide enough AX geometry for a non-IME approach?

## Solutions Tried And Their Outcomes

## Worked

- structured branch diagnostics
- debug overlay
- geometry quality classification
- not treating `AXFrame` estimates as real support
- rejecting broad marker rects as exact caret geometry

## Partially Worked

- wider candidate search
- adjacent-marker derivation

## Did Not Solve Chrome By Themselves

- trusting advertised AX marker capabilities
- relying on `AXBoundsForRange` in Chrome
- relying on selected marker range bounds alone

## Things Intentionally Not Done

These were discussed and intentionally not taken as the solution:

- switching to an Input Method / IME architecture
- requiring the user to enable a custom keyboard/input source
- silently hiding the issue by pretending a low-confidence estimate is “good enough”

The product decision was explicit:

- either get the caret right
- or treat the field as unsupported

## What The Next Engineer Should Do

## 1. Re-run Chrome with the newest marker notes

The most important next log is the new `AXTextMarker range` note after the latest patch.

Specifically determine whether Chrome is now reporting:

- `AXSelectedTextMarkerRange was unavailable.`
- `AXSelectedTextMarkerRange existed, but AXBoundsForTextMarkerRange returned no usable rect.`
- `...and adjacent-marker derivation failed.`
- or a new `Derived` success

That will tell you whether the failure is:

- no marker range
- no marker bounds
- no adjacent marker traversal
- or failed glyph-range bounds

## 2. If adjacent-marker derivation still fails, instrument the marker pipeline one level deeper

Do not add giant noisy logs again.

Add narrow notes around:

- start marker extraction
- previous marker lookup
- next marker lookup
- range creation
- bounds lookup for derived marker ranges

The next engineer should be able to answer:

- which exact step in the marker pipeline fails
- on which host
- on which node

## 3. Treat Chrome and Xcode as separate bugs

Chrome bug:

- real caret geometry is often unavailable even though marker APIs are advertised

Xcode bug:

- real caret geometry exists
- yet focus capability sometimes ends as unsupported

Do not debug those together.

## 4. If Chrome still fails, inspect whether the “selected” candidate is the right marker host

The local search is already wider than before, but the selected candidate may still not be the node whose live marker calls succeed.

Good next checks:

- compare focused element vs resolved element over time
- compare the candidate that has the highest score vs the candidate whose marker calls actually succeed
- verify whether a nearby sibling/descendant consistently returns working marker traversal

Do this surgically. Do not revert to full AX tree spam.

## 5. Keep the hard rule about support

Do not weaken this rule during debugging:

- only `Exact` or `Derived` geometry counts as caret support

That rule protects the user experience and keeps the logs honest.

## Files Modified During This Investigation

These are the main files that changed:

- `tabby/Models/FocusGeometryModels.swift`
- `tabby/Models/FocusModels.swift`
- `tabby/Services/Focus/AXTextGeometryResolver.swift`
- `tabby/Services/Focus/FocusSnapshotResolver.swift`
- `tabby/Services/Focus/FocusGeometryDebugLogger.swift`
- `tabby/Services/UI/FocusDebugOverlayController.swift`
- `tabby/Support/AXHelper.swift`
- `tabby/Support/FocusCapabilityResolver.swift`
- `tabby/App/Core/AppDelegate.swift`

## Recommended Immediate Next Step

Run the failing Chrome repro again with:

- `-tabby-log-focus-geometry`
- optionally `-tabby-show-focus-debug-overlay`

Then capture only:

- the `[FocusGeometry]` line
- the `[FocusGeometry details]` block
- the `AXTextMarker range` note

That should be enough to decide whether the remaining work is:

- deeper marker-path debugging
- choosing a different nearby AX node
- or accepting that this exact Chrome surface does not expose usable caret geometry through Accessibility alone

