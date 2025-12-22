import Foundation
import SQLite3
import PostgresNIO
import MySQLNIO
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

// MySQL Driver - Real implementation using MySQLNIO
public final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    public let engine: DatabaseEngine = .mysql
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

        var logger = Logger(label: "db-viewer.mysql")
        logger.logLevel = .error

        do {
            let connection = try await MySQLConnection.connect(
                to: .makeAddressResolvingHost(profile.host, port: profile.port),
                username: profile.username,
                database: profile.database,
                password: password ?? "",
                tlsConfiguration: nil,
                logger: logger,
                on: eventLoopGroup.next()
            ).get()
            _ = try await connection.close().get()
        } catch {
            throw DatabaseDriverError.connectionFailed(reason: "MySQL接続に失敗しました: \(error.localizedDescription)")
        }
    }

    public func openSession(using profile: ConnectionProfile) async throws -> DatabaseSession {
        let password = getPassword(from: profile.credential)

        var logger = Logger(label: "db-viewer.mysql")
        logger.logLevel = .error

        let connection = try await MySQLConnection.connect(
            to: .makeAddressResolvingHost(profile.host, port: profile.port),
            username: profile.username,
            database: profile.database,
            password: password ?? "",
            tlsConfiguration: nil,
            logger: logger,
            on: eventLoopGroup.next()
        ).get()

        return MySQLSession(profile: profile, connection: connection, logger: logger)
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
        let escapedSchema = escapeStringLiteral(schema)
        let sql = """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = '\(escapedSchema)'
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
        let escapedSchema = escapeStringLiteral(table.schema)
        let escapedTable = escapeStringLiteral(table.name)
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
                WHERE tc.table_schema = '\(escapedSchema)'
                    AND tc.table_name = '\(escapedTable)'
                    AND tc.constraint_type = 'PRIMARY KEY'
            ) pk ON c.column_name = pk.column_name
            WHERE c.table_schema = '\(escapedSchema)'
                AND c.table_name = '\(escapedTable)'
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
        var sql = "SELECT * FROM \(escapeIdentifier(query.table.schema)).\(escapeIdentifier(query.table.name))"

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
                return "\(escapeIdentifier(filter.column)) \(op) \(formatValue(filter.value))"
            }
            sql += " WHERE " + filterClauses.joined(separator: " AND ")
        }

        // Add ORDER BY clause
        if !query.sorts.isEmpty {
            let sortClauses = query.sorts.map { sort in
                "\(escapeIdentifier(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
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
        let escapedSchema = escapeIdentifier(modification.table.schema)
        let escapedTable = escapeIdentifier(modification.table.name)

        switch modification.operation {
        case .insert(let values):
            let columnNames = values.keys.map { escapeIdentifier($0) }.joined(separator: ", ")
            let valueStrings = values.values.map { formatValue($0) }.joined(separator: ", ")
            sql = "INSERT INTO \(escapedSchema).\(escapedTable) (\(columnNames)) VALUES (\(valueStrings))"

        case .update(let values, let lock):
            let setClauses = values.map { "\(escapeIdentifier($0.key)) = \(formatValue($0.value))" }.joined(separator: ", ")
            sql = "UPDATE \(escapedSchema).\(escapedTable) SET \(setClauses)"
            sql += " WHERE " + buildWhereClause(from: lock)

        case .delete(let lock):
            sql = "DELETE FROM \(escapedSchema).\(escapedTable)"
            sql += " WHERE " + buildWhereClause(from: lock)
        }

        // クエリを実行し、全行を消費してメタデータを取得
        let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        var rowCount = 0
        for try await _ in rows {
            rowCount += 1
        }

        // INSERT/UPDATE/DELETEの場合、影響行数を取得（RETURNINGがない場合は0行が返る）
        // 影響行数が不明な場合は1を返す（楽観ロック前提で1行のみ変更）
        let affectedRows = rowCount > 0 ? rowCount : 1
        return ModificationResult(affectedRows: affectedRows)
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

    /// PostgreSQLの識別子（テーブル名、カラム名、スキーマ名）をエスケープする
    /// ダブルクォートで囲み、内部のダブルクォートは2つにエスケープする
    private func escapeIdentifier(_ identifier: String) -> String {
        let escaped = identifier.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// PostgreSQLの文字列リテラルをエスケープする
    private func escapeStringLiteral(_ value: String) -> String {
        return value.replacingOccurrences(of: "'", with: "''")
    }

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
        case .array(let values):
            // IN句用: (value1, value2, ...)
            let formattedValues = values.map { formatValue($0) }.joined(separator: ", ")
            return "(\(formattedValues))"
        }
    }

    private func buildWhereClause(from lock: ModificationRequest.OptimisticLock) -> String {
        switch lock.strategy {
        case .primaryKey(let keys):
            return keys.map { "\(escapeIdentifier($0.key)) = \(formatValue($0.value))" }.joined(separator: " AND ")
        case .allColumns(let snapshot):
            return snapshot.map { "\(escapeIdentifier($0.key)) = \(formatValue($0.value))" }.joined(separator: " AND ")
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

// MySQL Session - Real implementation using MySQLNIO
actor MySQLSession: DatabaseSession {
    let profile: ConnectionProfile
    private let connection: MySQLConnection
    private var logger: Logger

    init(profile: ConnectionProfile, connection: MySQLConnection, logger: Logger) {
        self.profile = profile
        self.connection = connection
        self.logger = logger
    }

    func listSchemas() async throws -> [DatabaseSchema] {
        let sql = "SHOW DATABASES"
        var schemas: [DatabaseSchema] = []

        let rows = try await connection.query(sql, []).get()
        for row in rows {
            if let name = row.column("Database")?.string {
                // システムデータベースを除外
                if !["information_schema", "mysql", "performance_schema", "sys"].contains(name) {
                    schemas.append(DatabaseSchema(name: name))
                }
            }
        }
        return schemas
    }

    func listTables(in schema: String) async throws -> [DatabaseTable] {
        let sql = """
            SELECT TABLE_NAME, TABLE_TYPE
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = ?
            ORDER BY TABLE_NAME
            """

        var tables: [DatabaseTable] = []
        let rows = try await connection.query(sql, [MySQLData(string: schema)]).get()

        for row in rows {
            if let name = row.column("TABLE_NAME")?.string,
               let tableType = row.column("TABLE_TYPE")?.string {
                let kind: DatabaseTable.TableKind = tableType == "VIEW" ? .view : .table
                tables.append(DatabaseTable(schema: schema, name: name, kind: kind))
            }
        }
        return tables
    }

    func describe(table: DatabaseTable) async throws -> [DatabaseColumn] {
        let sql = """
            SELECT
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.IS_NULLABLE,
                c.COLUMN_DEFAULT,
                c.COLUMN_KEY
            FROM INFORMATION_SCHEMA.COLUMNS c
            WHERE c.TABLE_SCHEMA = ?
                AND c.TABLE_NAME = ?
            ORDER BY c.ORDINAL_POSITION
            """

        var columns: [DatabaseColumn] = []
        let rows = try await connection.query(sql, [
            MySQLData(string: table.schema),
            MySQLData(string: table.name)
        ]).get()

        for row in rows {
            guard let name = row.column("COLUMN_NAME")?.string,
                  let dataType = row.column("DATA_TYPE")?.string,
                  let isNullable = row.column("IS_NULLABLE")?.string else {
                continue
            }

            let defaultValue = row.column("COLUMN_DEFAULT")?.string
            let columnKey = row.column("COLUMN_KEY")?.string ?? ""

            var constraints: Set<DatabaseColumn.ColumnConstraint> = []
            if columnKey == "PRI" {
                constraints.insert(.primaryKey)
            }

            columns.append(DatabaseColumn(
                table: table.name,
                name: name,
                dataType: dataType,
                isNullable: isNullable == "YES",
                defaultValue: defaultValue,
                constraints: constraints
            ))
        }
        return columns
    }

    func execute(query: DataQueryRequest) async throws -> DataPage {
        var sql = "SELECT * FROM \(escapeIdentifier(query.table.schema)).\(escapeIdentifier(query.table.name))"
        var bindings: [MySQLData] = []

        // Add WHERE clause for filters
        if !query.filters.isEmpty {
            var filterClauses: [String] = []
            for filter in query.filters {
                let escapedColumn = escapeIdentifier(filter.column)

                switch filter.operation {
                case .equals:
                    filterClauses.append("\(escapedColumn) = ?")
                    bindings.append(convertToMySQLData(filter.value))
                case .notEquals:
                    filterClauses.append("\(escapedColumn) != ?")
                    bindings.append(convertToMySQLData(filter.value))
                case .greaterThan:
                    filterClauses.append("\(escapedColumn) > ?")
                    bindings.append(convertToMySQLData(filter.value))
                case .lessThan:
                    filterClauses.append("\(escapedColumn) < ?")
                    bindings.append(convertToMySQLData(filter.value))
                case .greaterThanOrEqual:
                    filterClauses.append("\(escapedColumn) >= ?")
                    bindings.append(convertToMySQLData(filter.value))
                case .lessThanOrEqual:
                    filterClauses.append("\(escapedColumn) <= ?")
                    bindings.append(convertToMySQLData(filter.value))
                case .like:
                    filterClauses.append("\(escapedColumn) LIKE ?")
                    bindings.append(convertToMySQLData(filter.value))
                case .ilike:
                    // MySQLにはILIKEがないため、LOWER()を使用して大文字小文字を区別しない検索を実現
                    filterClauses.append("LOWER(\(escapedColumn)) LIKE LOWER(?)")
                    bindings.append(convertToMySQLData(filter.value))
                case .inSet:
                    // IN句: 配列の各値に対してプレースホルダを生成
                    if case .array(let values) = filter.value {
                        let placeholders = values.map { _ in "?" }.joined(separator: ", ")
                        filterClauses.append("\(escapedColumn) IN (\(placeholders))")
                        for value in values {
                            bindings.append(convertToMySQLData(value))
                        }
                    } else {
                        // 単一値の場合は従来通り
                        filterClauses.append("\(escapedColumn) IN (?)")
                        bindings.append(convertToMySQLData(filter.value))
                    }
                }
            }
            sql += " WHERE " + filterClauses.joined(separator: " AND ")
        }

        // Add ORDER BY clause
        if !query.sorts.isEmpty {
            let sortClauses = query.sorts.map { sort in
                "\(escapeIdentifier(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
            }
            sql += " ORDER BY " + sortClauses.joined(separator: ", ")
        }

        // Add LIMIT and OFFSET
        sql += " LIMIT \(query.limit) OFFSET \(query.offset)"


        var dataRows: [DataRow] = []
        let rows = try await connection.query(sql, bindings).get()

        for row in rows {
            // クエリ結果から直接カラム名を取得
            let columnNames = row.columnDefinitions.map { $0.name }
            var cells: [String: DatabaseValue] = [:]
            for columnName in columnNames {
                if let column = row.column(columnName) {
                    cells[columnName] = extractValue(from: column)
                }
            }
            dataRows.append(DataRow(cells: cells))
        }

        return DataPage(rows: dataRows, hasMore: dataRows.count == query.limit)
    }

    func execute(modification: ModificationRequest) async throws -> ModificationResult {
        var sql: String
        var bindings: [MySQLData] = []
        let escapedSchema = escapeIdentifier(modification.table.schema)
        let escapedTable = escapeIdentifier(modification.table.name)

        switch modification.operation {
        case .insert(let values):
            let columnNames = values.keys.map { escapeIdentifier($0) }.joined(separator: ", ")
            let placeholders = values.keys.map { _ in "?" }.joined(separator: ", ")
            sql = "INSERT INTO \(escapedSchema).\(escapedTable) (\(columnNames)) VALUES (\(placeholders))"
            bindings = values.values.map { convertToMySQLData($0) }

        case .update(let values, let lock):
            let setClauses = values.keys.map { "\(escapeIdentifier($0)) = ?" }.joined(separator: ", ")
            sql = "UPDATE \(escapedSchema).\(escapedTable) SET \(setClauses)"
            bindings = values.values.map { convertToMySQLData($0) }

            let whereResult = buildWhereClause(from: lock)
            sql += " WHERE " + whereResult.clause
            bindings.append(contentsOf: whereResult.bindings)

        case .delete(let lock):
            sql = "DELETE FROM \(escapedSchema).\(escapedTable)"
            let whereResult = buildWhereClause(from: lock)
            sql += " WHERE " + whereResult.clause
            bindings = whereResult.bindings
        }

        _ = try await connection.query(sql, bindings).get()

        // ROW_COUNT()で実際の影響行数を取得
        let countRows = try await connection.query("SELECT ROW_COUNT() as cnt", []).get()
        var affectedRows = 1
        if let firstRow = countRows.first,
           let count = firstRow.column("cnt")?.int {
            affectedRows = count
        }

        return ModificationResult(affectedRows: affectedRows)
    }

    func execute(sql: String, limit: Int?) async throws -> SQLQueryResult {
        var finalSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalSQL.hasSuffix(";") {
            finalSQL = String(finalSQL.dropLast())
        }

        if let limit = limit {
            finalSQL += " LIMIT \(limit)"
        }

        var columns: [String] = []
        var dataRows: [DataRow] = []
        var isFirstRow = true

        let rows = try await connection.query(finalSQL, []).get()

        for row in rows {
            // Get column names from first row using columnDefinitions
            if isFirstRow {
                columns = row.columnDefinitions.map { $0.name }
                isFirstRow = false
            }

            var cells: [String: DatabaseValue] = [:]
            for columnName in columns {
                if let column = row.column(columnName) {
                    cells[columnName] = extractValue(from: column)
                }
            }
            dataRows.append(DataRow(cells: cells))
        }

        return SQLQueryResult(columns: columns, rows: dataRows)
    }

    func close() async {
        _ = try? await connection.close().get()
    }

    // Helper methods

    /// MySQLの識別子（テーブル名、カラム名、スキーマ名）をエスケープする
    /// バッククォートで囲み、内部のバッククォートは2つにエスケープする
    private func escapeIdentifier(_ identifier: String) -> String {
        let escaped = identifier.replacingOccurrences(of: "`", with: "``")
        return "`\(escaped)`"
    }

    private func convertToMySQLData(_ value: DatabaseValue) -> MySQLData {
        switch value {
        case .null:
            return MySQLData(type: .null, format: .text, buffer: nil, isUnsigned: false)
        case .bool(let b):
            return MySQLData(bool: b)
        case .int(let i):
            return MySQLData(int: i)
        case .double(let d):
            return MySQLData(double: d)
        case .decimal(let s):
            return MySQLData(string: s)
        case .string(let s):
            return MySQLData(string: s)
        case .date(let date):
            return MySQLData(date: date)
        case .timestamp(let date):
            return MySQLData(date: date)
        case .blob(let data):
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            return MySQLData(type: .blob, format: .binary, buffer: buffer, isUnsigned: false)
        case .json(let json):
            return MySQLData(string: json)
        case .array:
            // 配列型はIN句で個別に処理されるため、ここには到達しないはず
            // 念のためNULLを返す
            return MySQLData(type: .null, format: .text, buffer: nil, isUnsigned: false)
        }
    }

    private func buildWhereClause(from lock: ModificationRequest.OptimisticLock) -> (clause: String, bindings: [MySQLData]) {
        switch lock.strategy {
        case .primaryKey(let keys):
            let clauses = keys.keys.map { "\(escapeIdentifier($0)) = ?" }.joined(separator: " AND ")
            let bindings = keys.values.map { convertToMySQLData($0) }
            return (clauses, bindings)
        case .allColumns(let snapshot):
            let clauses = snapshot.keys.map { "\(escapeIdentifier($0)) = ?" }.joined(separator: " AND ")
            let bindings = snapshot.values.map { convertToMySQLData($0) }
            return (clauses, bindings)
        }
    }

    private func extractValue(from data: MySQLData) -> DatabaseValue {
        if data.buffer == nil {
            return .null
        }

        // Try different type conversions
        // Note: Check int before bool, as MySQL TINYINT(1) can be interpreted as both
        if let value = data.int {
            return .int(value)
        }
        if let value = data.double {
            return .double(value)
        }
        if let value = data.date {
            return .timestamp(value)
        }
        if let value = data.string {
            return .string(value)
        }

        return .null
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

        let sql = "PRAGMA table_info(\(escapeIdentifier(table.name)))"
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
        var sql = "SELECT * FROM \(escapeIdentifier(query.table.name))"
        var bindingValues: [DatabaseValue] = []

        // Add WHERE clause for filters
        if !query.filters.isEmpty {
            var filterClauses: [String] = []
            for filter in query.filters {
                let escapedColumn = escapeIdentifier(filter.column)

                switch filter.operation {
                case .equals:
                    filterClauses.append("\(escapedColumn) = ?")
                    bindingValues.append(filter.value)
                case .notEquals:
                    filterClauses.append("\(escapedColumn) != ?")
                    bindingValues.append(filter.value)
                case .greaterThan:
                    filterClauses.append("\(escapedColumn) > ?")
                    bindingValues.append(filter.value)
                case .lessThan:
                    filterClauses.append("\(escapedColumn) < ?")
                    bindingValues.append(filter.value)
                case .greaterThanOrEqual:
                    filterClauses.append("\(escapedColumn) >= ?")
                    bindingValues.append(filter.value)
                case .lessThanOrEqual:
                    filterClauses.append("\(escapedColumn) <= ?")
                    bindingValues.append(filter.value)
                case .like:
                    filterClauses.append("\(escapedColumn) LIKE ?")
                    bindingValues.append(filter.value)
                case .ilike:
                    // SQLiteにはILIKEがないため、LOWER()を使用して大文字小文字を区別しない検索を実現
                    filterClauses.append("LOWER(\(escapedColumn)) LIKE LOWER(?)")
                    bindingValues.append(filter.value)
                case .inSet:
                    // IN句: 配列の各値に対してプレースホルダを生成
                    if case .array(let values) = filter.value {
                        let placeholders = values.map { _ in "?" }.joined(separator: ", ")
                        filterClauses.append("\(escapedColumn) IN (\(placeholders))")
                        bindingValues.append(contentsOf: values)
                    } else {
                        // 単一値の場合は従来通り
                        filterClauses.append("\(escapedColumn) IN (?)")
                        bindingValues.append(filter.value)
                    }
                }
            }
            sql += " WHERE " + filterClauses.joined(separator: " AND ")
        }

        // Add ORDER BY clause
        if !query.sorts.isEmpty {
            let sortClauses = query.sorts.map { sort in
                "\(escapeIdentifier(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
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
        for (index, value) in bindingValues.enumerated() {
            try bindValue(statement: statement, index: Int32(index + 1), value: value)
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
        let escapedTable = escapeIdentifier(modification.table.name)

        switch modification.operation {
        case .insert(let insertValues):
            let columns = insertValues.keys.map { escapeIdentifier($0) }.joined(separator: ", ")
            let placeholders = insertValues.keys.map { _ in "?" }.joined(separator: ", ")
            sql = "INSERT INTO \(escapedTable) (\(columns)) VALUES (\(placeholders))"
            values = Array(insertValues.values)

        case .update(let updateValues, let lock):
            let setClauses = updateValues.keys.map { "\(escapeIdentifier($0)) = ?" }.joined(separator: ", ")
            sql = "UPDATE \(escapedTable) SET \(setClauses)"
            values = Array(updateValues.values)

            // Add WHERE clause for optimistic lock
            let whereClause = try buildOptimisticLockWhereClause(lock: lock)
            sql += " WHERE \(whereClause.clause)"
            values.append(contentsOf: whereClause.values)

        case .delete(let lock):
            sql = "DELETE FROM \(escapedTable)"
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

    /// SQLiteの識別子（テーブル名、カラム名）をエスケープする
    /// ダブルクォートで囲み、内部のダブルクォートは2つにエスケープする
    private func escapeIdentifier(_ identifier: String) -> String {
        let escaped = identifier.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

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
        case .array:
            // 配列型はIN句で個別に処理されるため、ここには到達しないはず
            // 念のためNULLをバインド
            sqlite3_bind_null(statement, index)
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
            let clauses = keys.keys.map { "\(escapeIdentifier($0)) = ?" }.joined(separator: " AND ")
            return (clauses, Array(keys.values))
        case .allColumns(let snapshot):
            let clauses = snapshot.keys.map { "\(escapeIdentifier($0)) = ?" }.joined(separator: " AND ")
            return (clauses, Array(snapshot.values))
        }
    }
}