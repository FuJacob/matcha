# Tabby


<p align="center">
<img width="128" alt="logo (2)" src="https://github.com/user-attachments/assets/8a67095e-4d03-4055-8d4c-8871335152dd" />
</p>


## Video Demo

[https://www.youtube.com/watch?v=CGduGREZtlI&t=176s](https://www.youtube.com/watch?v=CGduGREZtlI&t=176s)

## Hackathon Prompt

**Build something that gives people time back in their day using AI.**

When I read that prompt, I asked myself what actually steals time from my day. Then I realized, typing is one.

I am a slower typer, but I need to type all sorts of things all day, for example, messages, docs, notes, emails, commits, and random drafts.

**One might suggest using an AI tool like ChatGPT or Gemini.**

But in practice, switching to a separate app, starting a conversation, and getting back a block of text breaks the natural flow of writing. It forces constant context switching and small manual edits.

**Well, how about AI dictation tools like Wispr Flow?**

They seem better, but they depend on a quiet environment, and speaking often moves faster than my thoughts. When I’m trying to carefully shape a message, dictation can feel rushed rather than helpful.

**That led to an idea: what if we had inline AI autocomplete that works in any app.**

## Solution

Tabby is a menu bar app that adds local AI autocomplete to any text field you are already in.

- suggestion appears as ghost text overlay near your caret
- press Tab to accept each word
- keep typing and truly flow.

No browser hop. No copy/paste loop. No speaking out loud.

## Why This Gives Time Back

Tabby saves time in the small moments that happen constantly:

- finishing common sentence patterns
- reducing typo/rewrite loops
- removing context-switch overhead
- keeping writing flow in one place, no need to move writing into a different editor

A few seconds saved per message adds up quickly over a full day.

## How It Works (High Level)

- Tabby is a macOS menu bar app built in Swift, with SwiftUI for UI and AppKit/Accessibility APIs for system integration.
- Focus detection runs through Accessibility: we find the active editable element, validate required capabilities, and extract text value, selection range, and caret bounds.
- Caret anchoring uses AX range bounds and fallback heuristics so ghost text can be placed near the live insertion point across different apps.
- Input monitoring uses a global key tap to detect typing/navigation and Tab acceptance, then debounces generation to avoid noisy triggers.
- Prompting supports two modes:
  - Guided mode: structured inline instructions plus optional screen-context hints.
  - Prefix Only mode: raw prefix continuation with no extra instruction framing.
- Models are local GGUF files running in-process via llama.cpp through LlamaSwift (no remote API endpoint dependency).
- Models are downloaded on demand after install and loaded from the local runtime folder, so app updates and model updates stay independent.
- Suggestion flow is continuous: generate a tail, render ghost text at the caret, accept with Tab in chunks, and reject stale outputs when context changes.
- Optional visual context pipeline: frontmost window screenshot -> OCR -> compact hint -> injected only as background context when enabled.

## Quick Demo Flow For Judges

1. Open Tabby.
2. Type in any supported text field.
3. See ghost text suggestion.
4. Press Tab to accept.
5. Keep typing without leaving your app.

## Run Locally

1. Open source code in XCode
2. Build the project
3. Activate necessary permissions in macOS
4. Download GGUF models into runtime folder
5. Enjoy!

CLI build:

```bash
xcodebuild -project tabby.xcodeproj -scheme tabby -configuration Debug -sdk macosx build
```

## What’s Next

- Improve compatibility across more macOS apps, since some editors still break focus detection or place ghost overlays in the wrong position.
- Make generation faster by optimizing runtime settings and tightening prompt construction so suggestions arrive with lower latency.
- Add memory persistence so Tabby can remember user writing patterns and useful context across sessions.
- Add deeper personalization controls (tone, style, brevity, domain preferences) so suggestions feel tailored per user.

## Installation (DMG)

1. Download the latest `Tabby.dmg` from GitHub Releases.
2. Open the DMG.
3. Drag `Tabby.app` into `Applications`.
4. Open `Applications` and launch Tabby.
5. Grant permissions when prompted:
  - Accessibility (required)
  - Input Monitoring (required)
  - Screen Recording (optional, only for visual context features)
6. Download a model from the Welcome screen, or add your own `.gguf` into the model folder.
7. If you manually add a model file, press **Refresh Model List** in Tabby.

If macOS blocks launch on first open, use one of these:
- Right click `Tabby.app` -> **Open**.
- Or go to **System Settings -> Privacy & Security** and click **Open Anyway**.

## Local Development Setup (In Depth)

### Prerequisites

1. macOS machine (Apple Silicon recommended for local model performance).
2. Xcode (latest stable) installed.
3. Xcode Command Line Tools installed.
4. Git installed.

### 1) Clone and Open

1. Clone the repository.
2. Open `tabby.xcodeproj` in Xcode.
3. Select the `tabby` scheme.

### 2) Signing and Build

1. In Xcode target settings, set your signing team under **Signing & Capabilities**.
2. Build and run from Xcode.
3. For CLI builds, run:

```bash
xcodebuild -project tabby.xcodeproj -scheme tabby -configuration Debug -sdk macosx build
```

### 3) First-Run Permissions

1. Enable **Accessibility** so Tabby can read focused field/caret context.
2. Enable **Input Monitoring** so Tabby can detect typing and Tab acceptance.
3. Optionally enable **Screen Recording** for visual-context enhancement in guided flows.

### 4) Model Setup

1. Open Tabby and use the built-in model download buttons.
2. Or manually place any `.gguf` file in the runtime folder:

```text
~/Library/Application Support/Tabby/LlamaRuntime
```

3. Press **Refresh Model List** in the app.
4. Select your model from the Model picker.

### 5) Recommended Defaults (Current)

1. Model: Gemma 3n (recommended) when available.
2. Prompt mode: Prefix Only (recommended).
3. Suggestion length: 3-7 words (recommended).

### 6) Troubleshooting

1. No suggestions appearing:
  - Re-check Accessibility and Input Monitoring permissions.
2. Model missing in picker:
  - Confirm file extension is `.gguf` and click **Refresh Model List**.
3. Overlay placement issues in specific apps:
  - Switch focus away and back, then retry typing.
