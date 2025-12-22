回答は必ず日本語でお願いします。

# Repository Guidelines

## Project Structure & Module Organization
`Sources/DBViewerCore` holds the database drivers, models, and backup generation logic. `Sources/DBViewerApp` contains the SwiftUI UI and view models. `Sources/PostgresTest` is a small executable for Postgres connectivity experiments. `Package.swift` defines the targets and dependencies, while `.build/` and `build/` are local artifacts that should not be edited manually.

## Build, Test, and Development Commands
Use SwiftPM directly for most workflows:
- `swift build` builds the package.
- `swift run db-viewer` launches the macOS app.
- `swift run PostgresTest` runs the CLI test target.
- `swift test` runs XCTest (currently no tests).

The Makefile wraps common tasks and sets a module cache:
- `make build` / `make release` for debug or release builds.
- `make run` to launch the app.
- `make preview` to build for SwiftUI previews.
- `make app` to create `build/DBViewer.app`.

## Coding Style & Naming Conventions
Use 4-space indentation and follow Swift API Design Guidelines. Types use `PascalCase`, members and variables use `camelCase`, and enum cases are lower camel case. Prefer `async/await` for database operations, mark shared models as `Sendable`, and keep UI-facing view models on `@MainActor`. No formatter or linter is configured, so match the existing style.

## Testing Guidelines
There is no `Tests/` directory yet. If you add tests, use SwiftPM’s layout `Tests/<TargetName>Tests`, name files `*Tests.swift`, and implement `XCTestCase` subclasses. Run tests with `swift test` or `make test`.

## Commit & Pull Request Guidelines
Current commit history uses short, descriptive Japanese sentences without prefixes. Keep messages concise and focused (e.g., “Improve backup SQL generation”). PRs should include a summary, rationale, verification steps, and screenshots for UI changes. Mention which database engine(s) were exercised and avoid committing real credentials or connection secrets.

## Security & Configuration Notes
Credentials are intended for macOS Keychain storage; do not log or persist secrets. When adding new drivers or dependencies, document any system requirements in `README.md` and `Package.swift`.
