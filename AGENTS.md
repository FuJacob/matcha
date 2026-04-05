# Matcha App Collaboration Rules

## Learning-first expectation

- Explain both the "what" and the "why" for architecture and code changes.
- Add concise teaching comments for non-obvious Swift syntax and lifecycle behavior.
- Call out tradeoffs when there are multiple valid implementation choices.
- Prefer clean boundaries (App, UI, Services, Models, Support) over quick coupling.

## Current architecture intent

- `App/`: app entrypoint and lifecycle ownership.
- `UI/`: menu bar views and presentation concerns.
- `Services/`: side-effectful boundaries (permissions, process management, IO).
- `Models/`: shared data/state contracts.
- `Support/`: pure helper/resolution logic.
