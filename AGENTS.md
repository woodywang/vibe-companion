# Repository Guidelines

## Project Structure & Module Organization

This repository contains a single application:

- `Package.swift` + `VibeCompanion/`: macOS menu-bar app built with SwiftPM and SwiftUI. Production code is under `VibeCompanion/Sources/`, grouped by feature (`App`, `Collectors`, `Core`, `Overlay`, `Settings`). XCTest files live in `VibeCompanion/Tests/`.
- `scripts/`: packaging utilities, notably `build-app.sh`.
- `docs/`: architecture, collector, build, and design documentation.

The app is local-first: no server, no third-party dependencies, and no user data ever leaves the machine. The single outbound request is an optional fetch of the public LiteLLM pricing table for cost estimation, which falls back to the bundled snapshot and never blocks rate display. Do not reintroduce an upload path or any telemetry without an explicit request.

## Build, Test, and Development Commands

- `swift build`: compile the app.
- `swift test`: run the XCTest suite.
- `./scripts/build-app.sh [debug|release]`: produce `.build/app/VibeCompanion.app`.

Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when `xcode-select` points at the Command Line Tools — otherwise `swift test` fails with `no such module 'XCTest'`.

## Coding Style & Naming Conventions

Follow existing formatting: four-space indentation in Swift. Use `PascalCase` for types, `camelCase` for functions and values, and descriptive feature-oriented filenames. Keep pure mapping/format logic out of views (see `Core/SpeedometerLogic.swift`) so it stays unit-testable.

## Testing Guidelines

Use XCTest for client behavior; name test methods `testExpectedBehavior`. Add regression tests alongside every behavioral fix. Run `swift test` before submitting; for UI/overlay changes also build and launch the `.app` to confirm the change visually.

## Commit & Pull Request Guidelines

History generally follows Conventional Commits: `feat(scope): ...`, `fix(scope): ...`, `test(scope): ...`, `docs: ...`, or `chore: ...`. Keep commits focused and imperative. Pull requests should explain the problem and solution, list verification commands, link relevant issues or design docs, and include screenshots or recordings for UI/overlay changes.

## Security & Configuration

Never commit secrets or build output. User settings live in `UserDefaults` suite `dev.vibe.companion`; the app reads only `~/.claude` and `~/.codex` session files (overridable via `$CLAUDE_CONFIG_DIR` / `$CODEX_HOME`) and never transmits their contents.
