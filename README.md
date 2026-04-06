# Tabby

Tabby is a local-first AI autocomplete assistant for macOS that works directly inside the apps where people already write.

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## Project Purpose

People spend a lot of their day typing emails, messages, notes, and other small bits of writing. The frustrating part is that most AI tools still make you leave what you are doing, go to another window, write a prompt, and then bring the result back.

Tabby is our attempt to make that feel natural by bringing inline autocomplete directly into any app you already type in.

The core product goal is simple: keep the user in flow.

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## What Tabby Does

- Watches the currently focused text field across macOS apps.
- Suggests short continuations as ghost text near the caret.
- Lets users accept suggestions with Tab in-place.
- Optionally uses screenshot-derived context hints to improve relevance.
- Runs local model inference in-process for low-latency autocomplete.

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## High-Level Tech Stack

- Language: Swift
- UI: SwiftUI + AppKit (menu bar app + lightweight overlay windows)
- System integration: macOS Accessibility APIs, CGEventTap (Input Monitoring)
- Visual context pipeline: ScreenCaptureKit + Vision OCR
- LLM runtime: llama.cpp via LlamaSwift
- Concurrency and state: Swift Concurrency, Combine, MainActor-isolated services

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## How It Works

1. Focus tracking
   - Tabby polls and resolves the active text input context (field identity, caret location, surrounding text).
2. Input monitoring
   - Global key events are classified into typing/navigation/shortcut intent.
   - Suggestion generation is gated to completed word boundaries to avoid half-typed prompt anchors.
3. Prompt construction
   - The prompt is built from a short trailing prefix window plus optional ScreenContextHints.
4. Model inference
   - A local llama runtime generates a short continuation constrained by the selected word range.
5. Normalization and validation
   - Output is normalized, stale generations are dropped, and only fresh context-matching suggestions are surfaced.
6. Inline UX
   - Ghost text is rendered near the caret.
   - Tab accepts the next chunk while preserving session consistency.

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## Project Structure

```text
matcha-app/
  App/        # Composition root, lifecycle, coordinator models
  UI/         # Menu bar and presentation components
  Services/   # Runtime, permissions, focus/input capture, OCR, overlay, insertion
  Models/     # Shared state and request/response contracts
  Support/    # Helpers for AX and runtime/file resolution
  LlamaRuntime/ # Local model artifacts
```

Architecture follows clear boundaries:

- App owns lifecycle and dependency composition.
- Services own side effects and OS integration.
- Models define stable contracts between components.
- UI reads published state and renders status/controls.

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## Local Development

### Prerequisites

- macOS development machine
- Xcode (recent stable version)
- Local model files available in LlamaRuntime/

### Run

1. Open matcha-app.xcodeproj in Xcode.
2. Select the matcha-app scheme.
3. Build and run.
4. Grant required permissions when prompted.

Optional CLI build:

```bash
xcodebuild -project matcha-app.xcodeproj -scheme matcha-app -configuration Debug -sdk macosx build
```

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## Required macOS Permissions

- Accessibility: Read focused element metadata and caret context.
- Input Monitoring: Observe global key events for inline acceptance behavior.
- Screen Recording: Capture frontmost window for screenshot-derived context hints.

Without these permissions, Tabby falls back gracefully and disables affected features.

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## Privacy and Data Handling

- Inference is local to the device runtime.
- Screenshot context is processed to produce short hints for prompt quality.
- The app is designed for local-first operation rather than cloud-roundtrip workflows.

If you plan to distribute externally, add a formal Privacy Policy and explicit retention guarantees.

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## Current Product Behavior

- Suggestion length is user-configurable (word-range presets).
- Prompt context is intentionally short to reduce repetition and stale continuation drift.
- Generation is triggered on completed word boundaries to improve output quality.
- Activation and visual-context status are surfaced in menu bar and indicator UI.

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## Contributing

Contributions are welcome. For larger feature work, prefer small PRs that keep boundaries clean across App, UI, Services, Models, and Support.

Suggested contribution pattern:

1. Open an issue with goal and UX impact.
2. Propose architecture changes before implementation.
3. Submit incremental PRs with clear verification notes.

![rainbow line](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png)

## Status

Tabby is actively evolving toward production-grade cross-app autocomplete on macOS, with emphasis on flow-preserving UX, local inference, and robust system integration.
