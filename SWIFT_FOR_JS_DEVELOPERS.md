# Swift And macOS For JavaScript Developers

This document is the shortest path from "I know JavaScript well" to "I can safely work on Tabby."

It is not a generic Swift tutorial. It explains the pieces you will actually touch in this codebase:

- Swift syntax that shows up constantly
- SwiftUI and AppKit ownership
- coordinators and why this app uses them
- `@MainActor`, `@Published`, `@ObservedObject`
- `NSObject`, `NSWindow`, delegates, and callbacks
- the macOS Accessibility tree and how Tabby reads text fields

Read this after [`README.md`](README.md), then read [`ARCHITECTURE.md`](ARCHITECTURE.md).

## The 30-second mental model

If you think in React or Node terms, Tabby is roughly this:

- `TabbyAppEnvironment` is the dependency container / composition root
- `AppDelegate` is the process-level controller that starts services and wires them together
- SwiftUI views render state, similar to React components
- coordinators own workflows and windows, similar to controller objects or route/state managers
- services talk to the OS, files, timers, runtime, screenshots, Accessibility APIs
- models are shared value types
- support files hold pure logic and low-level bridging helpers

The biggest architectural rule in this repo is:

- UI renders
- coordinators orchestrate
- services do side effects
- support files do pure logic

That rule matters because macOS app code gets unmaintainable very quickly when views start owning windows, timers, global hooks, or Accessibility logic directly.

## How to read this codebase

Start in this order:

1. [`tabby/App/Core/TabbyApp.swift`](tabby/App/Core/TabbyApp.swift)
2. [`tabby/App/Core/TabbyAppEnvironment.swift`](tabby/App/Core/TabbyAppEnvironment.swift)
3. [`tabby/App/Core/AppDelegate.swift`](tabby/App/Core/AppDelegate.swift)
4. [`ARCHITECTURE.md`](ARCHITECTURE.md)
5. [`tabby/App/Coordinators/SuggestionCoordinator.swift`](tabby/App/Coordinators/SuggestionCoordinator.swift) and the `SuggestionCoordinator+*.swift` files
6. [`tabby/Services/Focus/FocusTracker.swift`](tabby/Services/Focus/FocusTracker.swift)
7. [`tabby/Support/AXHelper.swift`](tabby/Support/AXHelper.swift)

If you only remember one thing, remember ownership:

- `TabbyAppEnvironment` creates the long-lived objects once
- `AppDelegate` retains them and starts them
- SwiftUI views observe them
- views do not create duplicate copies of runtime services

That is the main difference from a lot of JavaScript apps where object ownership is often more implicit.

## Swift syntax translated into JavaScript terms

### `struct` vs `class`

In Swift:

- `struct` is usually a value type
- `class` is usually a reference type

In JavaScript, almost everything object-like behaves by reference. In Swift, that is not true.

Practical rule for this repo:

- use `struct` for data values and UI views
- use `class` for long-lived stateful objects and services

Examples:

- `TabbyApp` is a `struct` because SwiftUI views are value-like descriptions of UI
- `AppDelegate` is a `class` because it owns long-lived services and lifecycle callbacks
- `RuntimeModelOption` is a `struct` because it is just data
- `SuggestionCoordinator` is a `class` because it owns state, subscriptions, and async work

### `enum`

Swift enums are much more powerful than JavaScript enums. They are closer to discriminated unions in TypeScript.

Example:

```swift
enum RuntimeBootstrapState {
    case idle
    case starting(String)
    case ready(String)
    case failed(String)
}
```

JavaScript/TypeScript equivalent:

```ts
type RuntimeBootstrapState =
  | { type: "idle" }
  | { type: "starting"; detail: string }
  | { type: "ready"; detail: string }
  | { type: "failed"; detail: string };
```

This is why enums are everywhere in Swift code. They are a very clean way to model product states.

### `extension`

An `extension` lets you add methods or computed properties to an existing type.

In Tabby, extensions are mostly used for file organization, not monkey-patching.

Example:

- [`tabby/App/Coordinators/SuggestionCoordinator.swift`](tabby/App/Coordinators/SuggestionCoordinator.swift) holds the type definition and shared state
- [`tabby/App/Coordinators/SuggestionCoordinator+Input.swift`](tabby/App/Coordinators/SuggestionCoordinator+Input.swift) adds input-related methods

That is roughly like:

- one file defines the class and fields
- other files add grouped methods to keep the source readable

Important tradeoff:

- this is good for large workflow types
- but it weakens privacy because Swift does not have a perfect "private across these files only" feature

So the repo uses discipline and comments to preserve boundaries.

### `protocol`

A Swift `protocol` is similar to a TypeScript interface.

Example idea:

- the coordinator depends on capability-shaped protocols instead of concrete implementations

Why:

- easier to swap implementations
- smaller boundaries
- easier reasoning about ownership

This is the same reason you might depend on an interface instead of a concrete class in a TypeScript backend.

### `guard`

`guard` is Swift's early-return tool.

Example:

```swift
guard let application = NSWorkspace.shared.frontmostApplication else {
    return .inactive
}
```

Think of it like:

```js
if (!application) {
  return inactive;
}
```

Swift code uses `guard` heavily to keep control flow flat.

### optionals: `String?`

`String?` means "this may be missing." It is like `string | null | undefined` in TypeScript, except Swift forces you to handle it explicitly.

Examples:

- `String?`
- `AXUIElement?`
- `CGRect?`

Common patterns:

```swift
if let value = maybeValue {
    // use value
}
```

```swift
guard let value = maybeValue else {
    return
}
```

This is one of Swift's best features. It prevents a lot of "cannot read property of undefined" style bugs.

### closures

A closure is just a function value.

Example from this repo:

```swift
modelDownloadManager.onModelDirectoryChanged = { [weak runtimeModel] in
    runtimeModel?.refreshAvailableModels()
}
```

JavaScript equivalent:

```js
modelDownloadManager.onModelDirectoryChanged = () => {
  runtimeModel?.refreshAvailableModels();
};
```

The `[weak runtimeModel]` part is a memory-management detail to avoid retain cycles. More on that later.

## SwiftUI in JavaScript terms

SwiftUI is the declarative UI layer in this app.

Very rough mapping:

- SwiftUI `View` ~= React component
- `body` ~= render function
- `@ObservedObject` ~= subscribe to an external observable store
- `@State` ~= local component state

Example from [`tabby/UI/MenuBarView.swift`](tabby/UI/MenuBarView.swift):

- it observes `permissionManager`, `runtimeModel`, `focusModel`, and `suggestionCoordinator`
- it computes a single status string from those sources
- it renders sections

This is similar to a React component that receives several stores and derives a display value.

Important difference:

- SwiftUI views are lightweight value descriptions
- long-lived work should not live inside them unless it is truly view-local

That is why Tabby pushes real lifecycle ownership into coordinators and services instead of putting everything in SwiftUI views.

## Property wrappers you will see everywhere

### `@ObservedObject`

This means a SwiftUI view is observing an object that can publish changes.

From [`tabby/UI/MenuBarView.swift`](tabby/UI/MenuBarView.swift):

```swift
@ObservedObject var runtimeModel: RuntimeBootstrapModel
```

Meaning:

- the view does not own `runtimeModel`
- it just listens to it
- when the object publishes changes, SwiftUI re-renders the view

In JavaScript terms, this is closer to subscribing to an external state container than creating local state.

### `@Published`

This marks properties inside an observable object that should emit updates.

From [`tabby/Models/RuntimeBootstrapModel.swift`](tabby/Models/RuntimeBootstrapModel.swift):

```swift
@Published private(set) var state: RuntimeBootstrapState
```

Meaning:

- the object owns `state`
- observers get notified when it changes
- `private(set)` means other types can read it but not write it

This is similar to a store field that can trigger subscribers.

### `@MainActor`

This is one of the most important Swift concurrency concepts in this app.

`@MainActor` means:

- this type or function is isolated to the main thread / UI actor
- access should happen on that actor

Why it matters in Tabby:

- UI state must be updated on the main thread
- AppKit and SwiftUI are main-thread-centric
- many permission and window APIs are not safe to mutate from background threads

If you think in browser terms:

- `@MainActor` is conceptually similar to "this code must run on the UI thread"

If you think in Node terms:

- it is a stronger, language-level guarantee than just "please call this on the right event loop"

Tradeoff:

- it simplifies reasoning about UI state
- but you must be careful not to do heavy blocking work on it

That is why heavy runtime work is pushed behind services and async tasks.

## Async work: `Task` and `async/await`

Swift's `Task` is roughly "start an async unit of work."

Example from [`tabby/Models/RuntimeBootstrapModel.swift`](tabby/Models/RuntimeBootstrapModel.swift):

- startup begins in a `Task`
- the model keeps a reference so duplicate startup does not happen

That is similar to storing an in-flight promise in JavaScript to avoid starting the same request twice.

Typical pattern:

- store the current task
- cancel/replace it when needed
- clear it when done

That pattern shows up in the suggestion pipeline a lot.

## Why this app uses coordinators

If you know frontend architecture, a coordinator is best thought of as a workflow owner.

It is not just a view model and not just a service.

A coordinator usually owns:

- the high-level workflow
- dependencies needed by that workflow
- when side effects happen
- how child services interact

Examples in this repo:

- `SuggestionCoordinator` owns the suggestion state machine
- `SettingsCoordinator` owns the settings window lifecycle
- `WelcomeCoordinator` owns onboarding presentation

### Why not put this in SwiftUI views?

Because SwiftUI views are the wrong place for:

- long-lived windows
- global key monitors
- process lifecycle
- Accessibility polling
- complex async orchestration

If you put those directly in views, you usually get:

- duplicate subscriptions
- lifecycle bugs
- harder-to-test code
- confusing ownership

So the coordinator pattern here is doing the same job a top-level controller or app service layer would do in a JavaScript desktop app.

### Concrete example: `SettingsCoordinator`

Read [`tabby/App/Coordinators/SettingsCoordinator.swift`](tabby/App/Coordinators/SettingsCoordinator.swift).

It owns:

- one `NSWindowController?`
- window creation
- "reuse existing settings window if already open"

It does not own:

- model download logic
- update logic
- settings UI rendering

That split is intentional.

If you were building this in Electron, `SettingsCoordinator` is conceptually close to:

- the object that manages one BrowserWindow
- ensures there is only one instance
- shows it when requested

## `NSObject`, `NSWindow`, delegates, and AppKit

This is where Swift gets confusing if you only know web development.

### AppKit

AppKit is the older native macOS UI framework.

SwiftUI is modern and declarative, but many macOS concepts still come from AppKit:

- app lifecycle
- windows
- menus
- responders
- delegates

Tabby uses both:

- SwiftUI for rendering views
- AppKit for app lifecycle and native window control

That is normal on macOS.

### `NSObject`

`NSObject` is the base class for many Objective-C / AppKit types.

When a Swift class inherits from `NSObject`, it usually means one of these:

- it needs to interact with AppKit / Objective-C APIs
- it needs delegate behavior
- it needs runtime features from Cocoa

Example:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate
```

That means:

- this is a Cocoa-compatible object
- it can receive app lifecycle callbacks from AppKit

### `NSWindow`

`NSWindow` is a real native macOS window.

In this repo:

- SwiftUI renders the content inside a window
- AppKit still owns the actual window object

That is why `SettingsCoordinator` creates an `NSWindow`, then wraps a SwiftUI view in `NSHostingController`.

Think of it as:

- AppKit owns the outer desktop window shell
- SwiftUI owns the inner content tree

### delegate pattern

AppKit loves delegates.

A delegate is just an object that receives lifecycle callbacks.

Example:

- `NSWindowDelegate`
- `NSApplicationDelegate`

JavaScript equivalent:

- registering callback handlers for lifecycle events on a framework object

Example from `SettingsCoordinator`:

- it conforms to `NSWindowDelegate`
- it receives `windowWillClose`
- it clears its retained window controller there

This is just event handling, but expressed through protocols and delegate methods.

## Combine: Swift's publisher/subscriber layer

You will see `Combine` imports in the app layer.

`Combine` is Apple's reactive subscription framework.

Very rough mapping:

- `@Published` creates a publisher
- `.sink { ... }` subscribes
- `AnyCancellable` is the subscription token you retain

Example from [`tabby/App/Core/AppDelegate.swift`](tabby/App/Core/AppDelegate.swift):

```swift
permissionManager.$inputMonitoringGranted
    .sink { [weak self] _ in
        self?.inputMonitor.refresh()
    }
    .store(in: &cancellables)
```

This is conceptually like:

```js
const unsubscribe = permissionManager.onInputMonitoringGranted(() => {
  inputMonitor.refresh();
});
subscriptions.push(unsubscribe);
```

The main thing to remember:

- if you do not retain the cancellable, the subscription dies

## Why some files are in `App`, `UI`, `Services`, `Models`, and `Support`

This repo uses folders as architecture signals.

### `App/`

Lifecycle ownership and orchestration.

Examples:

- `AppDelegate`
- `TabbyAppEnvironment`
- `SuggestionCoordinator`
- window coordinators

### `UI/`

Presentation only.

Examples:

- `MenuBarView`
- `SettingsView`
- welcome screen views

Rule:

- if a file mostly renders UI, it belongs here

### `Services/`

Side-effect boundaries.

Examples:

- `InputMonitor`
- `LlamaRuntimeManager`
- `ModelDownloadManager`
- `VisualContextCoordinator`

Rule:

- if it touches the OS, timers, files, network, runtime, screenshots, or async side effects, it is probably a service

### `Models/`

Shared value types and contracts.

Examples:

- runtime state enums
- suggestion models
- focus snapshots

### `Support/`

Pure logic or low-level helpers.

Examples:

- `AXHelper`
- request builders
- reconciler logic

This folder is deliberately where the "weird but reusable" code lives.

## The Accessibility tree: what it is and how Tabby uses it

This is the most important macOS-specific concept in the product.

### What is the AX tree?

AX means Accessibility.

macOS exposes a tree of UI elements for assistive technologies and automation-like features.

Think of it like a cross-process DOM for native apps.

That is not literally what it is, but it is the closest mental model for a web developer.

Examples of AX elements:

- text fields
- text areas
- buttons
- windows
- groups
- static text

Each element exposes:

- a role, like `AXTextField`
- attributes, like text value or selected range
- sometimes parameterized queries, like "bounds for this text range"

### Why Tabby needs it

Tabby works across other apps. It does not own the text field you are typing into.

So it has to ask macOS:

- what app is frontmost?
- what element is focused?
- is it editable?
- what text is in it?
- where is the caret?

That all happens through Accessibility APIs.

### Concrete pipeline in this repo

The focus pipeline is:

1. [`tabby/Services/Focus/FocusTracker.swift`](tabby/Services/Focus/FocusTracker.swift) polls on a timer
2. `FocusSnapshotResolver` reduces the raw AX element into a higher-level snapshot
3. `AXTextGeometryResolver` figures out caret geometry
4. [`tabby/Support/AXHelper.swift`](tabby/Support/AXHelper.swift) is the low-level bridge to macOS AX APIs

That split is important:

- `FocusTracker` owns timing and publication
- resolver objects own interpretation
- `AXHelper` owns the ugly C/Core Foundation calls

### `AXHelper` in plain language

[`tabby/Support/AXHelper.swift`](tabby/Support/AXHelper.swift) exists so the rest of the app does not need to directly touch:

- `AXUIElement`
- `CFTypeRef`
- `AXValue`
- low-level C functions like `AXUIElementCopyAttributeValue`

That file is the adapter between:

- messy OS APIs
- clean app-level Swift code

This is equivalent to writing one ugly but well-contained wrapper around a hostile browser or native API instead of spreading that mess across your whole codebase.

### Why AX is tricky

Unlike the DOM, the AX tree is not consistent across apps.

Different apps expose different:

- roles
- attributes
- selection behavior
- caret geometry support

That is why the code has so much capability checking and fallback behavior.

In web terms:

- imagine every website implemented input fields slightly differently
- and the browser API shape also changed depending on the app

That is what cross-app macOS Accessibility work feels like.

### Chromium/WebKit special case: text markers

In some apps, `NSRange`-style caret queries do not work properly.

That is why [`AXHelper.textMarkerCaretRect`](tabby/Support/AXHelper.swift) exists.

Those apps use a private Accessibility object called `AXTextMarkerRange`.

The code:

1. asks for the current text marker range
2. passes that marker back into another AX query
3. receives the caret bounds

You do not need to memorize the API names, but you should understand the design lesson:

- browser-based macOS apps often need special-case handling
- keep that handling at the OS boundary, not in the coordinator

## The suggestion pipeline in product terms

The main loop is:

1. detect focus
2. watch typing
3. decide if suggestion generation is allowed
4. build a request
5. ask the local model for text
6. render ghost text
7. reconcile later typing with the active suggestion
8. accept text on `Tab`

The orchestration center is [`tabby/App/Coordinators/SuggestionCoordinator.swift`](tabby/App/Coordinators/SuggestionCoordinator.swift).

But that file is intentionally split into multiple extension files so each workflow concern stays readable.

Key idea:

- the coordinator should decide when things happen
- support files should decide pure rules
- services should handle side effects

If you keep that distinction, this codebase stays maintainable.

## Memory management: why `[weak self]` exists

Swift uses ARC, automatic reference counting.

That means objects are released when nothing retains them anymore.

A common bug is a retain cycle:

- object A strongly retains object B
- object B strongly retains object A
- neither gets released

This shows up with closures a lot.

Example:

```swift
inputMonitor.onEvent = { [weak self] event in
    self?.handleInputEvent(event) ?? false
}
```

Why `weak`:

- `SuggestionCoordinator` owns `inputMonitor`
- the closure would otherwise strongly capture `self`
- then `inputMonitor` would indirectly retain `SuggestionCoordinator`
- creating a cycle

JavaScript developers are often not used to this because GC hides most of it. In Swift desktop code, you need to think about ownership more explicitly.

## Common Swift things that look scary but are normal

### `final class`

Means the class is not intended to be subclassed.

This is usually good default practice:

- clearer intent
- slightly better optimization
- fewer inheritance surprises

### `private(set)`

Readable from outside, writable only inside the type.

Good for observable state.

### `some View`

SwiftUI's way of saying "this returns a view, but I am hiding the exact concrete type."

You can treat it like an opaque UI return type.

### `NSHostingController`

Bridges SwiftUI content into an AppKit window/controller world.

This is how SwiftUI and AppKit coexist.

## Practical translation table

| Swift / macOS | JavaScript mental model |
| --- | --- |
| `struct View` | React component |
| `@ObservedObject` | subscribe to external store |
| `@Published` | observable store field |
| `@MainActor` | must run on UI thread |
| `Task` | in-flight async job / promise owner |
| `protocol` | TypeScript interface |
| `enum` with payloads | discriminated union |
| `extension` | split methods across files on same type |
| `AppDelegate` | process lifecycle controller |
| `NSWindow` | native desktop window |
| `NSWindowDelegate` | window lifecycle event handler |
| `AXUIElement` | cross-process DOM-like node |
| `AXHelper` | low-level browser/native wrapper layer |

## How to make safe changes in Tabby

If you are new to Swift, make changes in this order:

1. `Support/` pure logic
2. `Services/` side effects
3. `App/` orchestration
4. `UI/` presentation

Why:

- pure logic is easiest to reason about
- UI bugs are often caused by upstream ownership mistakes
- if you change views first, you may hide the actual architecture problem

## What to read when something breaks

### "Tabby does not recognize a text field"

Read:

- [`tabby/Services/Focus/FocusTracker.swift`](tabby/Services/Focus/FocusTracker.swift)
- `FocusSnapshotResolver`
- [`tabby/Support/AXHelper.swift`](tabby/Support/AXHelper.swift)

### "Ghost text appears in the wrong place"

Read:

- `AXTextGeometryResolver`
- [`tabby/Support/AXHelper.swift`](tabby/Support/AXHelper.swift)
- overlay-related services

### "Suggestions generate at the wrong times"

Read:

- [`tabby/App/Coordinators/SuggestionCoordinator.swift`](tabby/App/Coordinators/SuggestionCoordinator.swift)
- [`tabby/App/Coordinators/SuggestionCoordinator+Input.swift`](tabby/App/Coordinators/SuggestionCoordinator+Input.swift)
- suggestion support helpers in `Support/`

### "Model/runtime behavior is wrong"

Read:

- `LlamaRuntimeManager`
- `LlamaSuggestionEngine`
- `RuntimeBootstrapModel`

### "A window or menu flow behaves strangely"

Read:

- [`tabby/App/Core/AppDelegate.swift`](tabby/App/Core/AppDelegate.swift)
- [`tabby/App/Coordinators/SettingsCoordinator.swift`](tabby/App/Coordinators/SettingsCoordinator.swift)
- `WelcomeCoordinator`
- SwiftUI views in `UI/`

## A few engineering rules for this repo

When you work on Tabby, these rules will keep you out of trouble:

- do not put OS-specific logic in SwiftUI views
- do not put low-level AX calls directly in coordinators
- do not let one giant type own pure logic, side effects, and UI decisions all at once
- prefer adding a small focused type over making one file become magical
- document ownership and lifecycle, not just behavior

## If you only remember five things

1. `App/` owns lifecycle and orchestration.
2. `UI/` should mostly render observed state.
3. `@MainActor` means "this code belongs on the UI thread."
4. The AX tree is basically Tabby's cross-app DOM.
5. Coordinators exist to keep workflow ownership out of views.

## Suggested next reading

After this document, read these in order:

1. [`ARCHITECTURE.md`](ARCHITECTURE.md)
2. [`tabby/App/Core/TabbyAppEnvironment.swift`](tabby/App/Core/TabbyAppEnvironment.swift)
3. [`tabby/App/Core/AppDelegate.swift`](tabby/App/Core/AppDelegate.swift)
4. [`tabby/App/Coordinators/SuggestionCoordinator.swift`](tabby/App/Coordinators/SuggestionCoordinator.swift)
5. [`tabby/App/Coordinators/SuggestionCoordinator+Input.swift`](tabby/App/Coordinators/SuggestionCoordinator+Input.swift)
6. [`tabby/Services/Focus/FocusTracker.swift`](tabby/Services/Focus/FocusTracker.swift)
7. [`tabby/Support/AXHelper.swift`](tabby/Support/AXHelper.swift)
