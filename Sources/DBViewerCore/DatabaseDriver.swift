import Foundation

public enum DatabaseDriverError: Error, Sendable, Equatable {
    case unsupported
    case connectionFailed(reason: String)
    case authenticationFailed
    case queryFailed(reason: String)
    case notFound
    case optimisticLockFailed
    case transactionConflict
}

public struct DataQueryRequest: Sendable, Equatable {
    public var table: DatabaseTable
    public var filters: [Filter]
    public var sorts: [Sort]
    public var limit: Int
    public var offset: Int

    public struct Filter: Sendable, Equatable {
        public var column: String
        public var operation: Operation
        public var value: DatabaseValue

        public enum Operation: String, Sendable, Equatable {
            case equals
            case notEquals
            case greaterThan
            case lessThan
            case greaterThanOrEqual
            case lessThanOrEqual
            case like
            case ilike
            case inSet
        }

        public init(column: String, operation: Operation, value: DatabaseValue) {
            self.column = column
            self.operation = operation
            self.value = value
        }
    }

    public struct Sort: Sendable, Equatable {
        public var column: String
        public var ascending: Bool

        public init(column: String, ascending: Bool = true) {
            self.column = column
            self.ascending = ascending
        }
    }

    public init(table: DatabaseTable, filters: [Filter] = [], sorts: [Sort] = [], limit: Int = 100, offset: Int = 0) {
        self.table = table
        self.filters = filters
        self.sorts = sorts
        self.limit = limit
        self.offset = offset
    }
}

public struct ModificationRequest: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        case insert(values: [String: DatabaseValue])
        case update(values: [String: DatabaseValue], optimisticLock: OptimisticLock)
        case delete(optimisticLock: OptimisticLock)
    }

    public struct OptimisticLock: Sendable, Equatable {
        public enum Strategy: Sendable, Equatable {
            case primaryKey(keys: [String: DatabaseValue])
            case allColumns(snapshot: [String: DatabaseValue])
        }

        public var strategy: Strategy

        public init(strategy: Strategy) {
            self.strategy = strategy
        }
    }

    public var table: DatabaseTable
    public var operation: Operation

    public init(table: DatabaseTable, operation: Operation) {
        self.table = table
        self.operation = operation
    }
}

public struct ModificationResult: Sendable, Equatable {
    public var affectedRows: Int
    public var returnedRow: DataRow?

    public init(affectedRows: Int, returnedRow: DataRow? = nil) {
        self.affectedRows = affectedRows
        self.returnedRow = returnedRow
    }
}

public protocol DatabaseSession: Sendable {
    var profile: ConnectionProfile { get }

    func listSchemas() async throws -> [DatabaseSchema]
    func listTables(in schema: String) async throws -> [DatabaseTable]
    func describe(table: DatabaseTable) async throws -> [DatabaseColumn]
    func execute(query: DataQueryRequest) async throws -> DataPage
    func execute(modification: ModificationRequest) async throws -> ModificationResult
    func execute(sql: String, limit: Int?) async throws -> SQLQueryResult
    func close() async
}

public extension DatabaseSession {
    func execute(sql: String) async throws -> SQLQueryResult {
        try await execute(sql: sql, limit: nil)
    }
}

public protocol DatabaseDriver: Sendable {
    var engine: DatabaseEngine { get }
    func openSession(using profile: ConnectionProfile) async throws -> DatabaseSession
    func testConnection(using profile: ConnectionProfile) async throws
}

public final class DatabaseDriverRegistry: Sendable {
    private let drivers: [DatabaseEngine: DatabaseDriver]

    public init(drivers: [DatabaseDriver]) {
        var map: [DatabaseEngine: DatabaseDriver] = [:]
        drivers.forEach { map[$0.engine] = $0 }
        self.drivers = map
    }

    public func driver(for engine: DatabaseEngine) -> DatabaseDriver? {
        drivers[engine]
    }
}
