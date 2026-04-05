# Matcha App Collaboration Rules

## Learning-first expectation

- Explain both the "what" and the "why" for architecture and code changes.
- Assume the user is actively learning Swift, AppKit, Accessibility APIs, and macOS app architecture.
- Teach at the file, type, and subsystem level, not just the line level.
- Call out tradeoffs when there are multiple valid implementation choices.
- Prefer clean boundaries (App, UI, Services, Models, Support) over quick coupling.

## Teaching depth requirements

- When creating or editing a file, explain what the file is for, why it exists, and how it fits into the overall architecture.
- When adding a type such as a `struct`, `class`, `enum`, or protocol, explain:
  - what responsibility it owns
  - what other objects it collaborates with
  - why it should exist as its own type instead of being folded into another file
- When using Swift-specific syntax or Apple-specific APIs, explain the concept in plain language.
  Examples include:
  - property wrappers such as `@Published`, `@ObservedObject`, `@StateObject`, `@MainActor`
  - `Task`, async/await, actor isolation, closures, convenience initializers
  - Core Foundation / Accessibility APIs like `AXUIElement`, `CFTypeRef`, `unsafeBitCast`
- Do not assume the user already understands lifecycle ownership. Explain who owns what, how long it lives, and why that matters.
- When fixing a bug, explain the root cause in engineering terms, not just the patch.
- When adding architecture, explain data flow end-to-end: where state originates, where it is transformed, and where it is rendered.

## Code comment expectations

- Add real teaching comments, not just labels.
- Prefer file-level and type-level doc comments that explain purpose and design.
- Add targeted inline comments for tricky logic, lifecycle behavior, concurrency, Core Foundation bridging, and macOS quirks.
- Comments should explain why the code is written this way, what invariant it protects, or what pitfall it avoids.
- Avoid useless comments that merely restate the code.
- If a piece of Swift syntax is likely to be unfamiliar, annotate it briefly the first time it appears.

## Response expectations

- In chat responses, explain new files and objects in a way that helps the user build a mental model of the system.
- When making multi-file changes, include a short walkthrough of how the pieces connect.
- If there are multiple reasonable approaches, explain why one was chosen and what the rejected alternatives cost.
- If a bug reveals a broader lesson about architecture, ownership, concurrency, or API design, state that lesson explicitly.
- Call out tradeoffs when there are multiple valid implementation choices.

## Current architecture intent

- `App/`: app entrypoint and lifecycle ownership.
- `UI/`: menu bar views and presentation concerns.
- `Services/`: side-effectful boundaries (permissions, process management, IO).
- `Models/`: shared data/state contracts.
- `Support/`: pure helper/resolution logic.
