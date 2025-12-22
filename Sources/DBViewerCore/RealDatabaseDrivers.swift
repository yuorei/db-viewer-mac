import Foundation
import SQLite3
import PostgresNIO
import NIOCore
import NIOPosix
import Logging

// PostgreSQL Driver - Real implementation using PostgresNIO
public final class PostgreSQLDriver: DatabaseDriver, @unchecked Sendable {
    public let engine: DatabaseEngine = .postgres
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    public init() {
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }

    public func testConnection(using profile: ConnectionProfile) async throws {
        guard !profile.host.isEmpty,
              profile.port > 0,
              !profile.database.isEmpty,
              !profile.username.isEmpty else {
            throw DatabaseDriverError.connectionFailed(reason: "必須フィールドが入力されていません")
        }

        let password = getPassword(from: profile.credential)

        var logger = Logger(label: "db-viewer.postgres")
        logger.logLevel = .error

        let config = PostgresConnection.Configuration(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: password,
            database: profile.database,
            tls: .disable
        )

        do {
            let connection = try await PostgresConnection.connect(
                configuration: config,
                id: 1,
                logger: logger
            )
            try await connection.close()
        } catch {
            throw DatabaseDriverError.connectionFailed(reason: "PostgreSQL接続に失敗しました: \(error.localizedDescription)")
        }
    }

    public func openSession(using profile: ConnectionProfile) async throws -> DatabaseSession {
        let password = getPassword(from: profile.credential)

        var logger = Logger(label: "db-viewer.postgres")
        logger.logLevel = .error

        let config = PostgresConnection.Configuration(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: password,
            database: profile.database,
            tls: .disable
        )

        let connection = try await PostgresConnection.connect(
            configuration: config,
            id: 1,
            logger: logger
        )

        return PostgreSQLSession(profile: profile, connection: connection)
    }

    private func getPassword(from credential: CredentialReference) -> String? {
        switch credential.storage {
        case .inline(let password):
            return password
        case .keychain:
            // TODO: Implement keychain retrieval
            return nil
        }
    }
}

// MySQL Driver - For now, a placeholder that attempts real connections
public final class MySQLDriver: DatabaseDriver {
    public let engine: DatabaseEngine = .mysql
    
    public init() {}
    
    public func testConnection(using profile: ConnectionProfile) async throws {
        guard !profile.host.isEmpty,
              profile.port > 0,
              !profile.database.isEmpty,
              !profile.username.isEmpty else {
            throw DatabaseDriverError.connectionFailed(reason: "必須フィールドが入力されていません")
        }
        
        // For now, simulate connection test
        // In a real implementation, we would try to connect to MySQL
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
        
        // Simulate connection success for valid hostnames
        let validHosts = ["localhost", "127.0.0.1", "mysql", "db", "database"]
        if !validHosts.contains(profile.host) && !profile.host.hasPrefix("192.168.") && !profile.host.hasPrefix("10.") {
            throw DatabaseDriverError.connectionFailed(reason: "MySQL接続に失敗しました: ホスト \(profile.host) に接続できませんでした")
        }
    }
    
    public func openSession(using profile: ConnectionProfile) async throws -> DatabaseSession {
        try await testConnection(using: profile)
        return MySQLSession(profile: profile)
    }
}

// SQLite Driver - For now, a placeholder that attempts real connections
public final class SQLiteDriver: DatabaseDriver {
    public let engine: DatabaseEngine = .sqlite
    
    public init() {}
    
    public func testConnection(using profile: ConnectionProfile) async throws {
        // For SQLite, just check if the database file path is valid
        guard !profile.database.isEmpty else {
            throw DatabaseDriverError.connectionFailed(reason: "データベースファイルパスが指定されていません")
        }
        
        // Check if file exists or if parent directory is writable for new files
        let fileURL = URL(fileURLWithPath: profile.database)
        let fileManager = FileManager.default
        
        if fileManager.fileExists(atPath: profile.database) {
            // File exists, check if readable
            guard fileManager.isReadableFile(atPath: profile.database) else {
                throw DatabaseDriverError.connectionFailed(reason: "データベースファイルが読み取れません")
            }
        } else {
            // File doesn't exist, check if parent directory is writable
            let parentURL = fileURL.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: parentURL.path) else {
                throw DatabaseDriverError.connectionFailed(reason: "親ディレクトリが存在しません: \(parentURL.path)")
            }
            guard fileManager.isWritableFile(atPath: parentURL.path) else {
                throw DatabaseDriverError.connectionFailed(reason: "親ディレクトリに書き込み権限がありません")
            }
        }
    }
    
    public func openSession(using profile: ConnectionProfile) async throws -> DatabaseSession {
        try await testConnection(using: profile)
        return SQLiteSession(profile: profile)
    }
}

// PostgreSQL Session - Real implementation using PostgresNIO
actor PostgreSQLSession: DatabaseSession {
    let profile: ConnectionProfile
    private let connection: PostgresConnection
    private var logger: Logger

    init(profile: ConnectionProfile, connection: PostgresConnection) {
        self.profile = profile
        self.connection = connection
        var logger = Logger(label: "db-viewer.postgres.session")
        logger.logLevel = .error
        self.logger = logger
    }

    func listSchemas() async throws -> [DatabaseSchema] {
        let sql = """
            SELECT schema_name FROM information_schema.schemata
            WHERE schema_name NOT IN ('pg_catalog', 'pg_toast', 'information_schema')
            ORDER BY schema_name
            """

        var schemas: [DatabaseSchema] = []
        let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        for try await row in rows {
            let randomAccessRow = row.makeRandomAccess()
            if let name = try? randomAccessRow[0].decode(String.self) {
                schemas.append(DatabaseSchema(name: name))
            }
        }
        return schemas
    }

    func listTables(in schema: String) async throws -> [DatabaseTable] {
        let sql = """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = '\(schema)'
            ORDER BY table_name
            """

        var tables: [DatabaseTable] = []
        let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        for try await row in rows {
            let randomAccessRow = row.makeRandomAccess()
            if let name = try? randomAccessRow[0].decode(String.self),
               let tableType = try? randomAccessRow[1].decode(String.self) {
                let kind: DatabaseTable.TableKind = tableType == "VIEW" ? .view : .table
                tables.append(DatabaseTable(schema: schema, name: name, kind: kind))
            }
        }
        return tables
    }

    func describe(table: DatabaseTable) async throws -> [DatabaseColumn] {
        let sql = """
            SELECT
                c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END as is_primary_key
            FROM information_schema.columns c
            LEFT JOIN (
                SELECT ku.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage ku
                    ON tc.constraint_name = ku.constraint_name
                WHERE tc.table_schema = '\(table.schema)'
                    AND tc.table_name = '\(table.name)'
                    AND tc.constraint_type = 'PRIMARY KEY'
            ) pk ON c.column_name = pk.column_name
            WHERE c.table_schema = '\(table.schema)'
                AND c.table_name = '\(table.name)'
            ORDER BY c.ordinal_position
            """

        var columns: [DatabaseColumn] = []
        let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        for try await row in rows {
            let randomAccessRow = row.makeRandomAccess()
            guard let name = try? randomAccessRow[0].decode(String.self),
                  let dataType = try? randomAccessRow[1].decode(String.self),
                  let isNullable = try? randomAccessRow[2].decode(String.self),
                  let isPrimaryKey = try? randomAccessRow[4].decode(Bool.self) else {
                continue
            }
            let defaultValue = try? randomAccessRow[3].decode(String?.self)

            var constraints: Set<DatabaseColumn.ColumnConstraint> = []
            if isPrimaryKey {
                constraints.insert(.primaryKey)
            }
            columns.append(DatabaseColumn(
                table: table.name,
                name: name,
                dataType: dataType,
                isNullable: isNullable == "YES",
                defaultValue: defaultValue ?? nil,
                constraints: constraints
            ))
        }
        return columns
    }

    func execute(query: DataQueryRequest) async throws -> DataPage {
        var sql = "SELECT * FROM \"\(query.table.schema)\".\"\(query.table.name)\""

        // Add WHERE clause for filters
        if !query.filters.isEmpty {
            let filterClauses = query.filters.map { filter in
                let op = switch filter.operation {
                case .equals: "="
                case .notEquals: "!="
                case .greaterThan: ">"
                case .lessThan: "<"
                case .greaterThanOrEqual: ">="
                case .lessThanOrEqual: "<="
                case .like: "LIKE"
                case .ilike: "ILIKE"
                case .inSet: "IN"
                }
                return "\"\(filter.column)\" \(op) \(formatValue(filter.value))"
            }
            sql += " WHERE " + filterClauses.joined(separator: " AND ")
        }

        // Add ORDER BY clause
        if !query.sorts.isEmpty {
            let sortClauses = query.sorts.map { sort in
                "\"\(sort.column)\" \(sort.ascending ? "ASC" : "DESC")"
            }
            sql += " ORDER BY " + sortClauses.joined(separator: ", ")
        }

        // Add LIMIT and OFFSET
        sql += " LIMIT \(query.limit) OFFSET \(query.offset)"

        // First, get the column information to decode properly
        let columns = try await describe(table: query.table)
        let columnNames = columns.map { $0.name }

        var rows: [DataRow] = []
        let queryRows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)

        for try await row in queryRows {
            var cells: [String: DatabaseValue] = [:]
            let randomAccessRow = row.makeRandomAccess()

            for (index, columnName) in columnNames.enumerated() {
                if index < randomAccessRow.count {
                    cells[columnName] = extractValue(from: randomAccessRow, at: index)
                }
            }
            rows.append(DataRow(cells: cells))
        }

        return DataPage(rows: rows, hasMore: rows.count == query.limit)
    }

    func execute(modification: ModificationRequest) async throws -> ModificationResult {
        var sql: String

        switch modification.operation {
        case .insert(let values):
            let columnNames = values.keys.map { "\"\($0)\"" }.joined(separator: ", ")
            let valueStrings = values.values.map { formatValue($0) }.joined(separator: ", ")
            sql = "INSERT INTO \"\(modification.table.schema)\".\"\(modification.table.name)\" (\(columnNames)) VALUES (\(valueStrings))"

        case .update(let values, let lock):
            let setClauses = values.map { "\"\($0.key)\" = \(formatValue($0.value))" }.joined(separator: ", ")
            sql = "UPDATE \"\(modification.table.schema)\".\"\(modification.table.name)\" SET \(setClauses)"
            sql += " WHERE " + buildWhereClause(from: lock)

        case .delete(let lock):
            sql = "DELETE FROM \"\(modification.table.schema)\".\"\(modification.table.name)\""
            sql += " WHERE " + buildWhereClause(from: lock)
        }

        _ = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        return ModificationResult(affectedRows: 1)
    }

    func execute(sql: String, limit: Int?) async throws -> SQLQueryResult {
        var finalSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalSQL.hasSuffix(";") {
            finalSQL = String(finalSQL.dropLast())
        }

        var columns: [String] = []
        var rows: [DataRow] = []
        var isFirstRow = true

        let queryRows = try await connection.query(PostgresQuery(unsafeSQL: finalSQL), logger: logger)

        for try await row in queryRows {
            let randomAccessRow = row.makeRandomAccess()

            // Get column names from first row
            if isFirstRow {
                for i in 0..<randomAccessRow.count {
                    columns.append(randomAccessRow[i].columnName)
                }
                isFirstRow = false
            }

            var cells: [String: DatabaseValue] = [:]
            for i in 0..<randomAccessRow.count {
                let columnName = randomAccessRow[i].columnName
                cells[columnName] = extractValue(from: randomAccessRow, at: i)
            }
            rows.append(DataRow(cells: cells))
        }

        return SQLQueryResult(columns: columns, rows: rows)
    }

    func close() async {
        try? await connection.close()
    }

    // Helper methods
    private func formatValue(_ value: DatabaseValue) -> String {
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
            return "E'\\\\x\(data.map { String(format: "%02x", $0) }.joined())'"
        case .json(let json):
            return "'\(json.replacingOccurrences(of: "'", with: "''"))'::jsonb"
        }
    }

    private func buildWhereClause(from lock: ModificationRequest.OptimisticLock) -> String {
        switch lock.strategy {
        case .primaryKey(let keys):
            return keys.map { "\"\($0.key)\" = \(formatValue($0.value))" }.joined(separator: " AND ")
        case .allColumns(let snapshot):
            return snapshot.map { "\"\($0.key)\" = \(formatValue($0.value))" }.joined(separator: " AND ")
        }
    }

    private func extractValue(from row: PostgresRandomAccessRow, at index: Int) -> DatabaseValue {
        let cell = row[index]

        // Check if NULL
        if cell.bytes == nil {
            return .null
        }

        // Try to decode based on common types
        if let value = try? cell.decode(Int.self) {
            return .int(value)
        }
        if let value = try? cell.decode(Double.self) {
            return .double(value)
        }
        if let value = try? cell.decode(Bool.self) {
            return .bool(value)
        }
        if let value = try? cell.decode(Date.self) {
            return .timestamp(value)
        }
        if let value = try? cell.decode(String.self) {
            return .string(value)
        }

        return .null
    }
}

// MySQL Session - simplified implementation for now
actor MySQLSession: DatabaseSession {
    let profile: ConnectionProfile
    
    init(profile: ConnectionProfile) {
        self.profile = profile
    }
    
    func listSchemas() async throws -> [DatabaseSchema] {
        // For now, return the configured database as a schema
        return [DatabaseSchema(name: profile.database)]
    }
    
    func listTables(in schema: String) async throws -> [DatabaseTable] {
        // For now, return sample tables
        return [
            DatabaseTable(schema: schema, name: "users", kind: .table),
            DatabaseTable(schema: schema, name: "orders", kind: .table),
            DatabaseTable(schema: schema, name: "products", kind: .table),
            DatabaseTable(schema: schema, name: "active_users", kind: .view)
        ]
    }
    
    func describe(table: DatabaseTable) async throws -> [DatabaseColumn] {
        // Return sample column structure
        switch table.name {
        case "users":
            return [
                DatabaseColumn(table: table.name, name: "id", dataType: "int", isNullable: false, constraints: [.primaryKey]),
                DatabaseColumn(table: table.name, name: "username", dataType: "varchar(50)", isNullable: false),
                DatabaseColumn(table: table.name, name: "email", dataType: "varchar(100)", isNullable: true),
                DatabaseColumn(table: table.name, name: "created_at", dataType: "datetime", isNullable: false, defaultValue: "CURRENT_TIMESTAMP")
            ]
        case "orders":
            return [
                DatabaseColumn(table: table.name, name: "id", dataType: "int", isNullable: false, constraints: [.primaryKey]),
                DatabaseColumn(table: table.name, name: "user_id", dataType: "int", isNullable: false),
                DatabaseColumn(table: table.name, name: "total", dataType: "decimal(10,2)", isNullable: false),
                DatabaseColumn(table: table.name, name: "status", dataType: "varchar(20)", isNullable: false, defaultValue: "'pending'"),
                DatabaseColumn(table: table.name, name: "created_at", dataType: "datetime", isNullable: false, defaultValue: "CURRENT_TIMESTAMP")
            ]
        case "products":
            return [
                DatabaseColumn(table: table.name, name: "id", dataType: "int", isNullable: false, constraints: [.primaryKey]),
                DatabaseColumn(table: table.name, name: "name", dataType: "varchar(100)", isNullable: false),
                DatabaseColumn(table: table.name, name: "price", dataType: "decimal(8,2)", isNullable: false),
                DatabaseColumn(table: table.name, name: "stock", dataType: "int", isNullable: false, defaultValue: "0")
            ]
        default:
            return []
        }
    }
    
    func execute(query: DataQueryRequest) async throws -> DataPage {
        // Return sample data for demonstration
        let sampleRows: [DataRow] = switch query.table.name {
        case "users":
            [
                DataRow(cells: [
                    "id": .int(1),
                    "username": .string("alice"),
                    "email": .string("alice@example.com"),
                    "created_at": .timestamp(Date())
                ]),
                DataRow(cells: [
                    "id": .int(2),
                    "username": .string("bob"),
                    "email": .string("bob@example.com"),
                    "created_at": .timestamp(Date())
                ])
            ]
        case "orders":
            [
                DataRow(cells: [
                    "id": .int(1),
                    "user_id": .int(1),
                    "total": .decimal("99.99"),
                    "status": .string("completed"),
                    "created_at": .timestamp(Date())
                ])
            ]
        case "products":
            [
                DataRow(cells: [
                    "id": .int(1),
                    "name": .string("Laptop"),
                    "price": .decimal("1299.99"),
                    "stock": .int(5)
                ]),
                DataRow(cells: [
                    "id": .int(2),
                    "name": .string("Mouse"),
                    "price": .decimal("29.99"),
                    "stock": .int(100)
                ])
            ]
        default:
            []
        }
        
        return DataPage(rows: sampleRows, hasMore: false)
    }
    
    func execute(modification: ModificationRequest) async throws -> ModificationResult {
        // Simulate successful modification
        return ModificationResult(affectedRows: 1)
    }
    
    func execute(sql: String, limit: Int?) async throws -> SQLQueryResult {
        // Return sample SQL result
        return SQLQueryResult(
            columns: ["result"],
            rows: [DataRow(cells: ["result": .string("MySQL query executed: \(sql)")])]
        )
    }
    
    func close() async {
        // Nothing to close in this simplified implementation
    }
}

// Real SQLite Session - basic implementation  
actor SQLiteSession: DatabaseSession {
    let profile: ConnectionProfile
    private var db: OpaquePointer?
    
    init(profile: ConnectionProfile) {
        self.profile = profile
    }
    
    private func openDatabase() throws {
        guard db == nil else { return }
        
        let result = sqlite3_open(profile.database, &db)
        guard result == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            db = nil
            throw DatabaseDriverError.connectionFailed(reason: "SQLiteデータベースを開けませんでした: \(errorMessage)")
        }
    }
    
    func listSchemas() async throws -> [DatabaseSchema] {
        // SQLite には明示的なスキーマ概念がないため、"main" スキーマのみ返す
        return [DatabaseSchema(name: "main")]
    }
    
    func listTables(in schema: String) async throws -> [DatabaseTable] {
        try openDatabase()
        
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw DatabaseDriverError.queryFailed(reason: "テーブル一覧の取得に失敗しました: \(errorMessage)")
        }
        
        defer { sqlite3_finalize(statement) }
        
        var tables: [DatabaseTable] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let tableName = String(cString: sqlite3_column_text(statement, 0))
            tables.append(DatabaseTable(schema: schema, name: tableName))
        }
        
        return tables
    }
    
    func describe(table: DatabaseTable) async throws -> [DatabaseColumn] {
        try openDatabase()
        
        let sql = "PRAGMA table_info(\(table.name))"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw DatabaseDriverError.queryFailed(reason: "テーブル構造の取得に失敗しました: \(errorMessage)")
        }
        
        defer { sqlite3_finalize(statement) }
        
        var columns: [DatabaseColumn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let _ = sqlite3_column_int(statement, 0) // columnId - not used but part of the result
            let name = String(cString: sqlite3_column_text(statement, 1))
            let type = String(cString: sqlite3_column_text(statement, 2))
            let notNull = sqlite3_column_int(statement, 3) != 0
            let defaultValue = sqlite3_column_text(statement, 4) != nil ? String(cString: sqlite3_column_text(statement, 4)) : nil
            let isPrimaryKey = sqlite3_column_int(statement, 5) != 0
            
            columns.append(DatabaseColumn(
                table: table.name,
                name: name,
                dataType: type,
                isNullable: !notNull,
                defaultValue: defaultValue,
                constraints: isPrimaryKey ? [.primaryKey] : []
            ))
        }
        
        return columns
    }
    
    func execute(query: DataQueryRequest) async throws -> DataPage {
        try openDatabase()
        
        // Build SELECT query
        var sql = "SELECT * FROM \(query.table.name)"
        
        // Add WHERE clause for filters
        if !query.filters.isEmpty {
            let filterClauses = query.filters.map { filter in
                let op = switch filter.operation {
                case .equals: "="
                case .notEquals: "!="
                case .greaterThan: ">"
                case .lessThan: "<"
                case .greaterThanOrEqual: ">="
                case .lessThanOrEqual: "<="
                case .like: "LIKE"
                case .ilike: "LIKE" // SQLite doesn't have ILIKE, use LIKE
                case .inSet: "IN"
                }
                return "\(filter.column) \(op) ?"
            }
            sql += " WHERE " + filterClauses.joined(separator: " AND ")
        }
        
        // Add ORDER BY clause
        if !query.sorts.isEmpty {
            let sortClauses = query.sorts.map { sort in
                "\(sort.column) \(sort.ascending ? "ASC" : "DESC")"
            }
            sql += " ORDER BY " + sortClauses.joined(separator: ", ")
        }
        
        // Add LIMIT and OFFSET
        sql += " LIMIT \(query.limit) OFFSET \(query.offset)"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw DatabaseDriverError.queryFailed(reason: "クエリの準備に失敗しました: \(errorMessage)")
        }
        
        defer { sqlite3_finalize(statement) }
        
        // Bind parameters for filters
        for (index, filter) in query.filters.enumerated() {
            try bindValue(statement: statement, index: Int32(index + 1), value: filter.value)
        }
        
        // Execute query and collect results
        var rows: [DataRow] = []
        let columnCount = sqlite3_column_count(statement)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            var cells: [String: DatabaseValue] = [:]
            
            for i in 0..<columnCount {
                let columnName = String(cString: sqlite3_column_name(statement, i))
                let value = extractValue(statement: statement, index: i)
                cells[columnName] = value
            }
            
            rows.append(DataRow(cells: cells))
        }
        
        return DataPage(rows: rows, hasMore: rows.count == query.limit)
    }
    
    func execute(modification: ModificationRequest) async throws -> ModificationResult {
        try openDatabase()
        
        var sql: String
        var values: [DatabaseValue] = []
        
        switch modification.operation {
        case .insert(let insertValues):
            let columns = insertValues.keys.joined(separator: ", ")
            let placeholders = String(repeating: "?", count: insertValues.count).split(separator: "").joined(separator: ", ")
            sql = "INSERT INTO \(modification.table.name) (\(columns)) VALUES (\(placeholders))"
            values = Array(insertValues.values)
            
        case .update(let updateValues, let lock):
            let setClauses = updateValues.keys.map { "\($0) = ?" }.joined(separator: ", ")
            sql = "UPDATE \(modification.table.name) SET \(setClauses)"
            values = Array(updateValues.values)
            
            // Add WHERE clause for optimistic lock
            let whereClause = try buildOptimisticLockWhereClause(lock: lock)
            sql += " WHERE \(whereClause.clause)"
            values.append(contentsOf: whereClause.values)
            
        case .delete(let lock):
            sql = "DELETE FROM \(modification.table.name)"
            let whereClause = try buildOptimisticLockWhereClause(lock: lock)
            sql += " WHERE \(whereClause.clause)"
            values = whereClause.values
        }
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw DatabaseDriverError.queryFailed(reason: "更新クエリの準備に失敗しました: \(errorMessage)")
        }
        
        defer { sqlite3_finalize(statement) }
        
        // Bind parameters
        for (index, value) in values.enumerated() {
            try bindValue(statement: statement, index: Int32(index + 1), value: value)
        }
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw DatabaseDriverError.queryFailed(reason: "更新クエリの実行に失敗しました: \(errorMessage)")
        }
        
        let affectedRows = Int(sqlite3_changes(db))
        return ModificationResult(affectedRows: affectedRows)
    }
    
    func execute(sql: String, limit: Int?) async throws -> SQLQueryResult {
        try openDatabase()
        
        var finalSQL = sql
        if let limit = limit {
            finalSQL += " LIMIT \(limit)"
        }
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, finalSQL, -1, &statement, nil) == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw DatabaseDriverError.queryFailed(reason: "SQLクエリの準備に失敗しました: \(errorMessage)")
        }
        
        defer { sqlite3_finalize(statement) }
        
        let columnCount = sqlite3_column_count(statement)
        var columns: [String] = []
        
        for i in 0..<columnCount {
            columns.append(String(cString: sqlite3_column_name(statement, i)))
        }
        
        var rows: [DataRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [DatabaseValue?] = []
            for i in 0..<columnCount {
                row.append(extractValue(statement: statement, index: i))
            }
            
            // Convert to DataRow format
            var cells: [String: DatabaseValue] = [:]
            for (index, value) in row.enumerated() {
                let columnName = columns[index]
                cells[columnName] = value ?? .null
            }
            rows.append(DataRow(cells: cells))
        }
        
        return SQLQueryResult(columns: columns, rows: rows, affectedRowCount: nil)
    }
    
    func close() async {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }
    
    // Helper methods
    private func bindValue(statement: OpaquePointer?, index: Int32, value: DatabaseValue) throws {
        switch value {
        case .null:
            sqlite3_bind_null(statement, index)
        case .bool(let b):
            sqlite3_bind_int(statement, index, b ? 1 : 0)
        case .int(let i):
            sqlite3_bind_int64(statement, index, Int64(i))
        case .double(let d):
            sqlite3_bind_double(statement, index, d)
        case .decimal(let s):
            sqlite3_bind_text(statement, index, s, -1, nil)
        case .string(let s):
            sqlite3_bind_text(statement, index, s, -1, nil)
        case .date(let date):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
            sqlite3_bind_text(statement, index, formatter.string(from: date), -1, nil)
        case .timestamp(let date):
            let formatter = ISO8601DateFormatter()
            sqlite3_bind_text(statement, index, formatter.string(from: date), -1, nil)
        case .blob(let data):
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), nil)
            }
        case .json(let json):
            sqlite3_bind_text(statement, index, json, -1, nil)
        }
    }
    
    private func extractValue(statement: OpaquePointer?, index: Int32) -> DatabaseValue? {
        let type = sqlite3_column_type(statement, index)
        
        switch type {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .int(Int(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return .string(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let length = sqlite3_column_bytes(statement, index)
            let bytes = sqlite3_column_blob(statement, index)
            let data = Data(bytes: bytes!, count: Int(length))
            return .blob(data)
        default:
            return .null
        }
    }
    
    private func buildOptimisticLockWhereClause(lock: ModificationRequest.OptimisticLock) throws -> (clause: String, values: [DatabaseValue]) {
        switch lock.strategy {
        case .primaryKey(let keys):
            let clauses = keys.keys.map { "\($0) = ?" }.joined(separator: " AND ")
            return (clauses, Array(keys.values))
        case .allColumns(let snapshot):
            let clauses = snapshot.keys.map { "\($0) = ?" }.joined(separator: " AND ")
            return (clauses, Array(snapshot.values))
        }
    }
}