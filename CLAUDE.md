必ず回答は日本語でお願いします

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DB Viewer is a macOS database viewer application supporting PostgreSQL, MySQL, and SQLite. The project is written in Swift and uses SwiftUI for the UI layer.

## Building and Running

### Build the project
```bash
swift build
```

### Run the main application
```bash
swift run db-viewer
```

### Run the backup demo
```bash
swift run backup-demo
```

### Run tests
```bash
swift test
```

## Architecture

The codebase is organized into three main modules:

### DBViewerCore (library)
Core business logic and database drivers. Key components:

- **DatabaseDriver protocol**: Abstract interface for database engines. Each driver provides `testConnection()` and `openSession()` methods.
- **DatabaseSession protocol**: Represents an active database connection. Provides methods for:
  - Schema/table introspection (`listSchemas()`, `listTables()`, `describe()`)
  - Data queries (`execute(query:)`)
  - Data modifications (`execute(modification:)`)
  - Raw SQL execution (`execute(sql:)`)
  - Backup generation (`generateBackupSQL()`)

- **Driver implementations**:
  - `PostgreSQLDriver`, `MySQLDriver`, `SQLiteDriver` in `RealDatabaseDrivers.swift`
  - `InMemoryDriver` in `StubDrivers.swift` (for testing/preview)
  - SQLite is the only fully functional driver using SQLite3 C API
  - PostgreSQL and MySQL drivers currently return sample data

- **ConnectionStore**: Manages saved database connections
  - `FileConnectionStore`: Production implementation using AES-GCM encryption
  - `InMemoryConnectionStore`: Test/preview implementation
  - Credentials stored in macOS Keychain via `KeychainService`

- **Data models** (`DatabaseModels.swift`):
  - `ConnectionProfile`: Database connection configuration with TLS and SSH tunnel support
  - `DatabaseSchema`, `DatabaseTable`, `DatabaseColumn`: Schema objects
  - `DatabaseValue`: Type-safe enum for database values (null, bool, int, double, string, date, blob, json)
  - `DataRow`, `DataPage`: Query results
  - `DataQueryRequest`, `ModificationRequest`: Request types with filtering, sorting, and optimistic locking

### DBViewerApp (executable)
SwiftUI application layer following MVVM pattern:

- **Views**: SwiftUI views for each screen
- **ViewModels**: Business logic and state management (marked with `@MainActor`)
- **AppDependencies**: Dependency injection container
  - `live()`: Production dependencies with real drivers
  - `preview()`: Preview dependencies with sample data

Key view models:
- `ConnectionListViewModel`: Manages connection list and active sessions
- `ConnectionEditorViewModel`: Handles connection creation/editing
- `DatabaseBackupViewModel`: Generates SQL backups for tables
- `SQLConsoleViewModel`: Executes raw SQL queries
- `RowEditorViewModel`: Inline row editing

### BackupDemo (executable)
Demonstration of backup functionality (executable target defined but no source files currently exist).

## Key Design Patterns

### Dependency Injection
`AppDependencies` provides centralized dependency management. Use `live()` for production and `preview()` for SwiftUI previews.

### Protocol-Based Drivers
Database drivers implement the `DatabaseDriver` and `DatabaseSession` protocols, enabling easy testing and driver swapping via `DatabaseDriverRegistry`.

### Optimistic Locking
Data modifications use optimistic locking with two strategies:
- `primaryKey`: Lock using primary key values
- `allColumns`: Lock using full row snapshot (detects concurrent modifications)

### Credential Security
- Passwords never stored in connection profiles directly
- `CredentialReference` with two storage modes:
  - `keychain(id)`: Secure keychain storage (production)
  - `inline(password)`: Direct storage (testing only)
- Connection file encrypted with AES-GCM using key stored in keychain

## Database Backup Feature

The backup functionality is implemented as an extension on `DatabaseSession` in `DatabaseDriver.swift` (lines 119-262):

- `generateBackupSQL(for:)`: Main entry point, generates full SQL backup
- Includes CREATE TABLE statements and INSERT statements
- Supports selective table backup or full database backup
- Handles multiple schemas and data types
- Output format includes metadata header with connection info and timestamp

## Current Limitations

- PostgreSQL and MySQL drivers (`RealDatabaseDrivers.swift`) are placeholder implementations returning sample data
- Only SQLite driver has full functionality using the SQLite3 C API
- BackupDemo target exists but has no implementation
- No actual tests in Tests directory (DatabaseModelsTests.swift was deleted)

## Database Engine Support

Each database engine has specific connection requirements:
- **PostgreSQL**: Default port 5432, supports schemas
- **MySQL**: Default port 3306, database name used as schema
- **SQLite**: File-based, no network connection, uses "main" schema

## Swift Concurrency

The codebase uses modern Swift concurrency:
- All database operations are `async throws`
- Actors used for session management (`PostgreSQLSession`, `MySQLSession`, `SQLiteSession`)
- `@MainActor` used for ViewModels
- `Sendable` protocol enforced throughout for thread safety
