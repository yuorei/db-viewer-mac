import Foundation

public struct InMemoryDataset: Sendable {
    public var schemas: [DatabaseSchema]
    public var columns: [DatabaseTable.ID: [DatabaseColumn]]
    public var rows: [DatabaseTable.ID: [DataRow]]

    public init(
        schemas: [DatabaseSchema] = [],
        columns: [DatabaseTable.ID: [DatabaseColumn]] = [:],
        rows: [DatabaseTable.ID: [DataRow]] = [:]
    ) {
        self.schemas = schemas
        self.columns = columns
        self.rows = rows
    }
}

public final class InMemoryDriver: DatabaseDriver {
    public let engine: DatabaseEngine
    private let store: InMemoryStore
    private let dataset: InMemoryDataset

    public init(engine: DatabaseEngine, dataset: InMemoryDataset = .init()) {
        self.engine = engine
        self.dataset = dataset
        self.store = InMemoryStore(dataset: dataset)
    }

    public func openSession(using profile: ConnectionProfile) async throws -> DatabaseSession {
        InMemorySession(profile: profile, store: store)
    }

    public func testConnection(using profile: ConnectionProfile) async throws {}
    
    internal func makeSession(with profile: ConnectionProfile) -> DatabaseSession {
        InMemorySession(profile: profile, store: InMemoryStore(dataset: dataset))
    }
}

actor InMemoryStore {
    private var dataset: InMemoryDataset

    init(dataset: InMemoryDataset) {
        self.dataset = dataset
    }

    func schemas() -> [DatabaseSchema] {
        dataset.schemas
    }

    func tables(in schema: String) -> [DatabaseTable] {
        dataset.schemas.first { $0.name == schema }?.tables ?? []
    }

    func table(named name: String, in schema: String?) -> DatabaseTable? {
        if let schema {
            return dataset.schemas
                .first { $0.name == schema }?
                .tables
                .first { $0.name == name }
        }

        for candidate in dataset.schemas {
            if let table = candidate.tables.first(where: { $0.name == name }) {
                return table
            }
        }
        return nil
    }

    func columns(for table: DatabaseTable) -> [DatabaseColumn] {
        dataset.columns[table.id] ?? []
    }

    func page(for table: DatabaseTable, offset: Int, limit: Int) -> DataPage {
        let rows = dataset.rows[table.id] ?? []
        let slice = Array(rows.dropFirst(offset).prefix(limit))
        let hasMore = offset + slice.count < rows.count
        return DataPage(rows: slice, totalCount: rows.count, hasMore: hasMore)
    }

    func apply(_ modification: ModificationRequest) throws -> ModificationResult {
        switch modification.operation {
        case .insert(let values):
            let row = DataRow(cells: values)
            var tableRows = dataset.rows[modification.table.id] ?? []
            tableRows.append(row)
            dataset.rows[modification.table.id] = tableRows
            return ModificationResult(affectedRows: 1, returnedRow: row)
        case .update(let values, let lock):
            guard let index = try findRowIndex(for: modification.table, using: lock) else {
                throw DatabaseDriverError.notFound
            }
            var tableRows = dataset.rows[modification.table.id] ?? []
            var row = tableRows[index]
            for (key, value) in values {
                row.cells[key] = value
            }
            tableRows[index] = row
            dataset.rows[modification.table.id] = tableRows
            return ModificationResult(affectedRows: 1, returnedRow: row)
        case .delete(let lock):
            guard let index = try findRowIndex(for: modification.table, using: lock) else {
                throw DatabaseDriverError.notFound
            }
            var tableRows = dataset.rows[modification.table.id] ?? []
            tableRows.remove(at: index)
            dataset.rows[modification.table.id] = tableRows
            return ModificationResult(affectedRows: 1, returnedRow: nil)
        }
    }

    private func findRowIndex(for table: DatabaseTable, using lock: ModificationRequest.OptimisticLock) throws -> Int? {
        let tableRows = dataset.rows[table.id] ?? []
        switch lock.strategy {
        case .primaryKey(let keys):
            let keyColumns = keys.keys
            guard !keyColumns.isEmpty else { return nil }
            return tableRows.firstIndex { row in
                keyColumns.allSatisfy { key in
                    row.cells[key] == keys[key]
                }
            }
        case .allColumns(let snapshot):
            return tableRows.firstIndex { row in
                row.cells == snapshot
            }
        }
    }
}

actor InMemorySession: DatabaseSession {
    let profile: ConnectionProfile
    private let store: InMemoryStore

    init(profile: ConnectionProfile, store: InMemoryStore) {
        self.profile = profile
        self.store = store
    }

    func listSchemas() async throws -> [DatabaseSchema] {
        await store.schemas()
    }

    func listTables(in schema: String) async throws -> [DatabaseTable] {
        await store.tables(in: schema)
    }

    func describe(table: DatabaseTable) async throws -> [DatabaseColumn] {
        await store.columns(for: table)
    }

    func execute(query: DataQueryRequest) async throws -> DataPage {
        await store.page(for: query.table, offset: query.offset, limit: query.limit)
    }

    func execute(modification: ModificationRequest) async throws -> ModificationResult {
        try await store.apply(modification)
    }

    func execute(sql: String, limit: Int?) async throws -> SQLQueryResult {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SQLQueryResult(columns: [], rows: [], affectedRowCount: 0)
        }

        let pattern = "(?i)^select\\s+\\*\\s+from\\s+([A-Za-z0-9_\\.`\"]+)(?:\\s+limit\\s+(\\d+))?\\s*;?$"
        let regex = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: fullRange),
              let identifierRange = Range(match.range(at: 1), in: trimmed) else {
            throw DatabaseDriverError.unsupported
        }

        let rawIdentifier = String(trimmed[identifierRange])
        let parts = rawIdentifier
            .split(separator: ".", maxSplits: 1)
            .map { part in
                String(part).trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
            }

        let schema: String?
        let tableName: String
        if parts.count == 2 {
            schema = parts[0]
            tableName = parts[1]
        } else {
            schema = nil
            tableName = parts[0]
        }

        guard let table = await store.table(named: tableName, in: schema) else {
            throw DatabaseDriverError.notFound
        }

        let limitFromQuery: Int?
        if match.numberOfRanges > 2,
           let limitRange = Range(match.range(at: 2), in: trimmed) {
            limitFromQuery = Int(trimmed[limitRange])
        } else {
            limitFromQuery = nil
        }

        let defaultLimit = 500
        let combinedLimit = [limitFromQuery, limit]
            .compactMap { $0 }
            .min() ?? defaultLimit
        let effectiveLimit = max(combinedLimit, 0)

        let columns = await store.columns(for: table).map(\.name)
        let page = await store.page(for: table, offset: 0, limit: effectiveLimit)
        return SQLQueryResult(columns: columns, rows: page.rows, affectedRowCount: nil)
    }

    func close() async {}
}

public enum StubDrivers {
    public static let postgres = InMemoryDriver(
        engine: .postgres,
        dataset: InMemoryDataset(
            schemas: [
                DatabaseSchema(
                    name: "public",
                    tables: [
                        DatabaseTable(schema: "public", name: "users", kind: .table, estimatedRowCount: 100),
                        DatabaseTable(schema: "public", name: "posts", kind: .table, estimatedRowCount: 250),
                        DatabaseTable(schema: "public", name: "comments", kind: .table, estimatedRowCount: 500)
                    ]
                ),
                DatabaseSchema(
                    name: "analytics",
                    tables: [
                        DatabaseTable(schema: "analytics", name: "events", kind: .table, estimatedRowCount: 10000),
                        DatabaseTable(schema: "analytics", name: "user_sessions", kind: .view, estimatedRowCount: 5000)
                    ]
                )
            ],
            columns: [
                "public.users": [
                    DatabaseColumn(table: "public.users", name: "id", dataType: "INTEGER", isNullable: false, constraints: [.primaryKey]),
                    DatabaseColumn(table: "public.users", name: "name", dataType: "VARCHAR(255)", isNullable: false),
                    DatabaseColumn(table: "public.users", name: "email", dataType: "VARCHAR(255)", isNullable: false, constraints: [.unique]),
                    DatabaseColumn(table: "public.users", name: "created_at", dataType: "TIMESTAMP", isNullable: false)
                ],
                "public.posts": [
                    DatabaseColumn(table: "public.posts", name: "id", dataType: "INTEGER", isNullable: false, constraints: [.primaryKey]),
                    DatabaseColumn(table: "public.posts", name: "user_id", dataType: "INTEGER", isNullable: false, constraints: [.foreignKey(reference: "public.users(id)")]),
                    DatabaseColumn(table: "public.posts", name: "title", dataType: "VARCHAR(255)", isNullable: false),
                    DatabaseColumn(table: "public.posts", name: "content", dataType: "TEXT", isNullable: true),
                    DatabaseColumn(table: "public.posts", name: "created_at", dataType: "TIMESTAMP", isNullable: false)
                ],
                "public.comments": [
                    DatabaseColumn(table: "public.comments", name: "id", dataType: "INTEGER", isNullable: false, constraints: [.primaryKey]),
                    DatabaseColumn(table: "public.comments", name: "post_id", dataType: "INTEGER", isNullable: false, constraints: [.foreignKey(reference: "public.posts(id)")]),
                    DatabaseColumn(table: "public.comments", name: "author", dataType: "VARCHAR(255)", isNullable: false),
                    DatabaseColumn(table: "public.comments", name: "content", dataType: "TEXT", isNullable: false),
                    DatabaseColumn(table: "public.comments", name: "created_at", dataType: "TIMESTAMP", isNullable: false)
                ],
                "analytics.events": [
                    DatabaseColumn(table: "analytics.events", name: "id", dataType: "BIGINT", isNullable: false, constraints: [.primaryKey]),
                    DatabaseColumn(table: "analytics.events", name: "event_type", dataType: "VARCHAR(100)", isNullable: false),
                    DatabaseColumn(table: "analytics.events", name: "user_id", dataType: "INTEGER", isNullable: true, constraints: [.foreignKey(reference: "public.users(id)")]),
                    DatabaseColumn(table: "analytics.events", name: "data", dataType: "JSONB", isNullable: true),
                    DatabaseColumn(table: "analytics.events", name: "created_at", dataType: "TIMESTAMP", isNullable: false)
                ],
                "analytics.user_sessions": [
                    DatabaseColumn(table: "analytics.user_sessions", name: "user_id", dataType: "INTEGER", isNullable: false),
                    DatabaseColumn(table: "analytics.user_sessions", name: "session_count", dataType: "BIGINT", isNullable: false),
                    DatabaseColumn(table: "analytics.user_sessions", name: "last_session", dataType: "TIMESTAMP", isNullable: true)
                ]
            ],
            rows: [
                "public.users": [
                    DataRow(cells: [
                        "id": .int(1),
                        "name": .string("John Doe"),
                        "email": .string("john@example.com"),
                        "created_at": .timestamp(Date())
                    ]),
                    DataRow(cells: [
                        "id": .int(2),
                        "name": .string("Jane Smith"),
                        "email": .string("jane@example.com"),
                        "created_at": .timestamp(Date())
                    ])
                ],
                "public.posts": [
                    DataRow(cells: [
                        "id": .int(1),
                        "user_id": .int(1),
                        "title": .string("First Post"),
                        "content": .string("This is my first post!"),
                        "created_at": .timestamp(Date())
                    ])
                ],
                "public.comments": [
                    DataRow(cells: [
                        "id": .int(1),
                        "post_id": .int(1),
                        "author": .string("Anonymous"),
                        "content": .string("Great post!"),
                        "created_at": .timestamp(Date())
                    ])
                ]
            ]
        )
    )
    
    public var session: DatabaseSession {
        let profile = ConnectionProfile(
            name: "Test Connection",
            engine: .postgres,
            host: "localhost",
            port: 5432,
            database: "test_db",
            username: "testuser",
            credential: CredentialReference(storage: .inline("password"))
        )
        
        return StubDrivers.postgres.makeSession(with: profile)
    }
}
