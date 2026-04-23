# Contributing To Tabby

Thanks for helping improve Tabby. This guide assumes you are comfortable with Swift and macOS
development, but not necessarily familiar with this codebase yet.

## Project Context

Tabby is a macOS menu bar app that provides on-device inline autocomplete in other apps. Most
changes touch one of these product areas:

- [Quality](https://github.com/FuJacob/tabby/issues/13): make suggestions feel native to the user's context.
- [Control](https://github.com/FuJacob/tabby/issues/14): let users shape when and how Tabby runs.
- [Trust](https://github.com/FuJacob/tabby/issues/15): make install, update, and model handling safe and legible.
- [Compat](https://github.com/FuJacob/tabby/issues/16): work reliably across more apps and text surfaces.

Before changing app behavior, read [ARCHITECTURE.md](ARCHITECTURE.md). It explains the main
ownership boundaries:

- `tabby/App/`: app lifecycle, composition, and coordinators.
- `tabby/UI/`: SwiftUI presentation.
- `tabby/Services/`: side effects, async work, OS APIs, and runtime boundaries.
- `tabby/Models/`: shared value types and contracts.
- `tabby/Support/`: pure rules and low-level helpers.

If you are coming from JavaScript or TypeScript, [SWIFT_FOR_JS_DEVELOPERS.md](SWIFT_FOR_JS_DEVELOPERS.md)
maps the Swift and macOS concepts used in this repo to familiar web-development ideas.

## Development Prerequisites

You need:

- macOS 26.0 or later for running the app and tests.
- Xcode with Command Line Tools installed.
- A local Apple development team configured in Xcode if you want to run the signed app from the IDE.
- SwiftLint for local lint checks. The CI workflow installs it with Homebrew when missing.

Apple Silicon is strongly recommended for local model-runtime work.

## Local Setup

Clone the repo and open the project:

```sh
git clone git@github.com:FuJacob/tabby.git
cd tabby
open tabby.xcodeproj
```

In Xcode, select the `tabby` scheme. If you run from Xcode, set your signing team under
Signing & Capabilities.

## Build

For a local compile check:

```sh
xcodebuild \
  -project tabby.xcodeproj \
  -scheme tabby \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`CODE_SIGNING_ALLOWED=NO` keeps the command useful on machines that do not have the project owner's
signing certificate. Use Xcode with your own team selected when you need to launch the app locally.

## Run

From Xcode:

1. Select the `tabby` scheme.
2. Choose your Mac as the run destination.
3. Build and run.
4. Complete onboarding.
5. Grant Accessibility and Input Monitoring when prompted.
6. Pick Apple Intelligence if available, or use the Open Source engine with a downloaded GGUF model.

Some host apps expose incomplete Accessibility data. If a suggestion does not appear or the overlay is
misplaced, start by reading the focus and geometry notes in [ARCHITECTURE.md](ARCHITECTURE.md).

## Test

Run the unit test suite:

```sh
xcodebuild test \
  -project tabby.xcodeproj \
  -scheme tabby \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

The test workflow runs on a macOS 26 runner because the app's deployment target is macOS 26.0.

## Lint

Run SwiftLint locally:

```sh
swiftlint --reporter github-actions-logging
```

The current CI gate is warnings-only. Treat warnings as cleanup work, but do not bury functional PRs
in unrelated style rewrites.

## Making Changes

Prefer the smallest change that fits the architecture:

1. Put deterministic rules in `tabby/Support/`.
2. Put OS, runtime, IO, and permission boundaries in `tabby/Services/`.
3. Put orchestration in `tabby/App/Coordinators/`.
4. Put rendering and user controls in `tabby/UI/`.

When changing autocomplete behavior, preserve the separation between request construction,
generation, normalization, session reconciliation, overlay presentation, and insertion. That makes
the behavior easier to test and keeps Accessibility-specific failures from spreading across the app.

## Pull Request Checklist

Before opening a PR:

- Link the issue the PR addresses.
- Explain what changed and why.
- Include screenshots or recordings for visible UI changes.
- Run the relevant local command:
  - build for compile-only changes
  - tests for pure logic or pipeline behavior
  - SwiftLint for style-sensitive changes
- Call out skipped validation and why it was skipped.
- Keep unrelated refactors out of the PR.
- Update docs when changing setup, release, permissions, user-facing behavior, or architecture.

## CI Expectations

PRs into `main` run:

- Build: `xcodebuild` compile check.
- Tests: `xcodebuild test`.
- Lint: SwiftLint warnings surfaced as GitHub annotations.

If CI fails, fix the root cause in the same PR when it is related to your change. If the failure is
unrelated infrastructure noise, note that clearly in the PR.

