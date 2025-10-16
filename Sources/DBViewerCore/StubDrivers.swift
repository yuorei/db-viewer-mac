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

    public init(engine: DatabaseEngine, dataset: InMemoryDataset = .init()) {
        self.engine = engine
        self.store = InMemoryStore(dataset: dataset)
    }

    public func openSession(using profile: ConnectionProfile) async throws -> DatabaseSession {
        InMemorySession(profile: profile, store: store)
    }

    public func testConnection(using profile: ConnectionProfile) async throws {}
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
