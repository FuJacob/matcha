# Tabby

Tabby lives in the menu bar and gives local inline autocomplete in whatever app you are typing in. Press Tab to accept.

## What It Does

- Reads focused text context via Accessibility
- Watches keyboard input (Input Monitoring)
- Shows ghost text near the caret
- Optionally uses screenshot context hints
- Runs local GGUF models

## Current State

- Works, but still very WIP
- UX is still being tuned
- Models are download-on-demand now

## Quick Start

1. Open tabby.xcodeproj
2. Run the tabby scheme
3. Grant permissions when prompted
4. Download whichever model(s) you want from Welcome or the menu

CLI build:

```bash
xcodebuild -project tabby.xcodeproj -scheme tabby -configuration Debug -sdk macosx build
```

## Permissions

- Accessibility: read focused input and caret
- Input Monitoring: detect typing and Tab acceptance
- Screen Recording: optional, for screenshot context

## Model Strategy

Bundling giant models inside the app package is painful, so this project does not depend on that.

- Ship app separately
- Download models after install
- Update models independently from app updates

Downloaded models are stored in Application Support under the runtime folder.

## Project Layout

- tabby/App: lifecycle and composition
- tabby/UI: menu and welcome screens
- tabby/Services: runtime, permissions, tracking, overlays, downloads
- tabby/Models: shared state/config contracts
- tabby/Support: helper utilities

## Why This Exists

Wanted autocomplete that feels native in normal desktop apps, not another browser tab.
