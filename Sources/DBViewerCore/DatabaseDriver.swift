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
    
    func generateBackupSQL(for tables: [DatabaseTable]? = nil) async throws -> String {
        // If no tables specified, backup all tables
        let tablesToBackup: [DatabaseTable]
        if let tables = tables {
            tablesToBackup = tables
        } else {
            // Get all tables from all schemas
            let schemas = try await listSchemas()
            tablesToBackup = try await withThrowingTaskGroup(of: [DatabaseTable].self) { group in
                for schema in schemas {
                    group.addTask {
                        try await self.listTables(in: schema.name)
                    }
                }
                
                var allTables: [DatabaseTable] = []
                for try await tables in group {
                    allTables.append(contentsOf: tables)
                }
                return allTables
            }
        }
        
        var backupSQL = ""
        
        // Add header comment
        backupSQL += "-- Database Backup Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        backupSQL += "-- Connection: \(profile.name)\n"
        backupSQL += "-- Engine: \(profile.engine.displayName)\n\n"
        
        // Generate backup for each table
        for table in tablesToBackup {
            do {
                backupSQL += try await generateTableBackupSQL(for: table)
                backupSQL += "\n"
            } catch {
                // Add comment about failed table
                backupSQL += "-- Failed to backup table \(table.fullyQualifiedName): \(error.localizedDescription)\n\n"
            }
        }
        
        return backupSQL
    }
    
    private func generateTableBackupSQL(for table: DatabaseTable) async throws -> String {
        var sql = ""
        
        // Add table comment
        sql += "-- Table: \(table.fullyQualifiedName)\n"
        
        // Get table structure
        let columns = try await describe(table: table)
        
        // Generate CREATE TABLE statement (simplified version)
        sql += generateCreateTableSQL(for: table, columns: columns)
        sql += "\n\n"
        
        // Get all data from the table
        let dataQuery = DataQueryRequest(table: table, limit: Int.max)
        let dataPage = try await execute(query: dataQuery)
        
        if !dataPage.rows.isEmpty {
            // Generate INSERT statements
            let columnNames = columns.map { $0.name }
            let quotedColumnNames = columnNames.map { escapeIdentifier($0) }.joined(separator: ", ")
            
            sql += "-- Data for table \(table.fullyQualifiedName)\n"
            
            for row in dataPage.rows {
                let values = columnNames.map { columnName in
                    formatValueForSQL(row.cells[columnName])
                }.joined(separator: ", ")
                
                sql += "INSERT INTO \(escapeIdentifier(table.schema)).\(escapeIdentifier(table.name)) (\(quotedColumnNames)) VALUES (\(values));\n"
            }
        } else {
            sql += "-- No data in table \(table.fullyQualifiedName)\n"
        }
        
        return sql
    }
    
    private func generateCreateTableSQL(for table: DatabaseTable, columns: [DatabaseColumn]) -> String {
        let tableName = "\(escapeIdentifier(table.schema)).\(escapeIdentifier(table.name))"
        
        var sql = "CREATE TABLE \(tableName) (\n"
        
        let columnDefinitions = columns.map { column in
            var def = "    \(escapeIdentifier(column.name)) \(column.dataType)"
            
            if !column.isNullable {
                def += " NOT NULL"
            }
            
            if let defaultValue = column.defaultValue {
                def += " DEFAULT \(defaultValue)"
            }
            
            return def
        }
        
        sql += columnDefinitions.joined(separator: ",\n")
        sql += "\n);"
        
        return sql
    }
    
    private func escapeIdentifier(_ identifier: String) -> String {
        // Simple identifier escaping - should be customized per database engine
        return "\"\(identifier)\""
    }
    
    private func formatValueForSQL(_ value: DatabaseValue?) -> String {
        guard let value = value else {
            return "NULL"
        }
        
        switch value {
        case .null:
            return "NULL"
        case .bool(let b):
            return b ? "TRUE" : "FALSE"
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .decimal(let s):
            return s
        case .string(let s):
            return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
        case .date(let date):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
            return "'\(formatter.string(from: date))'"
        case .timestamp(let date):
            let formatter = ISO8601DateFormatter()
            return "'\(formatter.string(from: date))'"
        case .blob(let data):
            return "'\(data.base64EncodedString())'"
        case .json(let json):
            return "'\(json.replacingOccurrences(of: "'", with: "''"))'"
        case .array(let values):
            // IN句用: (value1, value2, ...)
            let formattedValues = values.map { formatValueForSQL($0) }.joined(separator: ", ")
            return "(\(formattedValues))"
        }
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
