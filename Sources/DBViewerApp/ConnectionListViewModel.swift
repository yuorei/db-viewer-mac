import Foundation
import DBViewerCore
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class ConnectionListViewModel: ObservableObject {
    enum DetailMode: String, CaseIterable, Identifiable {
        case table
        case sql
        case backup

        var id: String { rawValue }

        var title: String {
            switch self {
            case .table:
                return "テーブル"
            case .sql:
                return "SQLコンソール"
            case .backup:
                return "バックアップ"
            }
        }
    }

    struct Dependencies {
        var connectionStore: any ConnectionStore

        static var preview: Dependencies {
            let sampleProfile = ConnectionProfile(
                name: "Local PostgreSQL",
                engine: .postgres,
                host: "localhost",
                port: 5432,
                database: "postgres",
                username: "postgres",
                credential: .init(storage: .inline("postgres"))
            )
            let store = InMemoryConnectionStore(items: [sampleProfile])
            return Dependencies(connectionStore: store)
        }
    }

    @Published var connections: [ConnectionProfile] = []
    @Published var selectedConnection: ConnectionProfile?
    @Published var schemas: [DatabaseSchema] = []
    @Published var errorMessage: String?
    @Published var editorViewModel: ConnectionEditorViewModel?
    @Published var isSaving: Bool = false
    @Published var deleteTarget: ConnectionProfile?
    @Published var selectedTable: DatabaseTable?
    @Published var tableColumns: [DatabaseColumn] = []
    @Published var tableRows: [TableRowViewModel] = []
    @Published var tableHasMore: Bool = false
    @Published var isLoadingTable: Bool = false
    @Published var selectedRowIDs: Set<UUID> = []
    @Published var rowEditorViewModel: RowEditorViewModel?
    @Published var isApplyingRowChange: Bool = false
    @Published var detailMode: DetailMode = .table
    @Published var isExportingBackup: Bool = false

    private let dependencies: Dependencies
    private let driverRegistry: DatabaseDriverRegistry
    private let pageSize: Int = 100
    private let sqlPreviewLimit: Int = 200
    private var tablePageIndex: Int = 0
    private var skipNextSelectionRefresh = false
    private var pendingTableRefresh = false
    lazy var sqlConsoleViewModel: SQLConsoleViewModel = {
        SQLConsoleViewModel(
            runner: { [weak self] sql in
                guard let self else {
                    throw DatabaseDriverError.unsupported
                }
                return try await self.executeSQL(sql: sql)
            },
            formatValue: TableRowViewModel.format
        )
    }()
    
    private(set) lazy var backupViewModel: DatabaseBackupViewModel? = nil

    init(dependencies: Dependencies, driverRegistry: DatabaseDriverRegistry) {
        self.dependencies = dependencies
        self.driverRegistry = driverRegistry

        Task {
            await loadConnections()
        }
    }

    func loadConnections() async {
        do {
            connections = try await dependencies.connectionStore.loadConnections()
            selectedConnection = connections.first
            await loadSchemas()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startCreatingConnection() {
        editorViewModel = ConnectionEditorViewModel(mode: .create, driverRegistry: driverRegistry)
    }

    func startEditingSelectedConnection() {
        guard let selectedConnection else { return }
        let password = existingPassword(for: selectedConnection)
        editorViewModel = ConnectionEditorViewModel(mode: .edit(selectedConnection, password: password), driverRegistry: driverRegistry)
    }

    func saveEditor() {
        guard let editorViewModel else { return }
        isSaving = true

        Task {
            do {
                let profile = editorViewModel.makeProfile()
                let updatedConnections = try await dependencies.connectionStore.upsert(profile)
                await MainActor.run {
                    self.connections = updatedConnections
                    self.selectedConnection = profile
                    self.editorViewModel = nil
                }
                await loadSchemas()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                self.isSaving = false
            }
        }
    }

    func requestDeleteSelectedConnection() {
        guard let selectedConnection else { return }
        deleteTarget = selectedConnection
    }

    func confirmDeleteSelectedConnection() {
        guard let target = deleteTarget else { return }
        Task {
            do {
                let updatedConnections = try await dependencies.connectionStore.delete(target)
                await MainActor.run {
                    self.connections = updatedConnections
                    if self.selectedConnection?.id == target.id {
                        self.selectedConnection = self.connections.first
                    }
                    self.deleteTarget = nil
                }
                await loadSchemas()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelEditor() {
        editorViewModel = nil
    }

    func refreshSelectedTable() {
        if skipNextSelectionRefresh {
            skipNextSelectionRefresh = false
            return
        }
        if isLoadingTable {
            pendingTableRefresh = true
            return
        }
        pendingTableRefresh = false
        Task { await loadSelectedTable(reset: true) }
    }

    func loadMoreRows() {
        guard tableHasMore, !isLoadingTable else { return }
        Task { await loadSelectedTable(reset: false) }
    }

    private func executeSQL(sql: String) async throws -> SQLQueryResult {
        try await withSession { session in
            try await session.execute(sql: sql, limit: sqlPreviewLimit)
        }
    }

    private func existingPassword(for profile: ConnectionProfile) -> String {
        switch profile.credential.storage {
        case .inline(let value):
            return value
        case .keychain:
            return ""
        }
    }

    func loadSchemas() async {
        guard let connection = selectedConnection,
              let driver = driverRegistry.driver(for: connection.engine) else {
            return
        }

        do {
            let session = try await driver.openSession(using: connection)
            let schemaList = try await session.listSchemas()

            // 各スキーマのテーブル一覧を取得
            var schemasWithTables: [DatabaseSchema] = []
            for schema in schemaList {
                let tables = try await session.listTables(in: schema.name)
                schemasWithTables.append(DatabaseSchema(name: schema.name, tables: tables))
            }

            await session.close()

            // Initialize backup view model with driver and connection info
            backupViewModel = DatabaseBackupViewModel(connection: connection, driver: driver)

            schemas = schemasWithTables
            errorMessage = nil
            skipNextSelectionRefresh = true
            reconcileSelection(with: schemasWithTables)
            await loadSelectedTable(reset: true)
            skipNextSelectionRefresh = false
        } catch {
            errorMessage = error.localizedDescription
            backupViewModel = nil
        }
    }

    private func reconcileSelection(with schemas: [DatabaseSchema]) {
        guard !schemas.isEmpty else {
            selectedTable = nil
            tableColumns = []
            tableRows = []
            tableHasMore = false
            return
        }

        if let current = selectedTable,
           let updated = findTable(with: current.id, in: schemas) {
            selectedTable = updated
        } else {
            selectedTable = schemas.first?.tables.first
        }
    }

    private func findTable(with id: DatabaseTable.ID, in schemas: [DatabaseSchema]) -> DatabaseTable? {
        for schema in schemas {
            if let table = schema.tables.first(where: { $0.id == id }) {
                return table
            }
        }
        return nil
    }

    private func loadSelectedTable(reset: Bool) async {
        guard let table = selectedTable else {
            tableColumns = []
            tableRows = []
            tableHasMore = false
            return
        }

        if reset {
            tablePageIndex = 0
            tableRows = []
            tableHasMore = false
            selectedRowIDs = []
            sqlConsoleViewModel.suggestQuery(for: table)
        }

        isLoadingTable = true
        defer {
            isLoadingTable = false
            if pendingTableRefresh {
                pendingTableRefresh = false
                Task { [weak self] in
                    await self?.loadSelectedTable(reset: true)
                }
            }
        }

        do {
            if reset {
                let columns = try await fetchColumns(for: table)
                tableColumns = columns
            }

            let offset = tablePageIndex * pageSize
            let page = try await fetchPage(for: table, offset: offset)
            let rows = makeRowViewModels(from: page.rows, columns: tableColumns)
            if reset {
                tableRows = rows
            } else {
                tableRows.append(contentsOf: rows)
            }
            selectedRowIDs = selectedRowIDs.intersection(Set(tableRows.map(\.id)))
            tableHasMore = page.hasMore
            tablePageIndex += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchColumns(for table: DatabaseTable) async throws -> [DatabaseColumn] {
        try await withSession { session in
            try await session.describe(table: table)
        }
    }

    private func fetchPage(for table: DatabaseTable, offset: Int) async throws -> DataPage {
        try await fetchPage(for: table, offset: offset, limit: pageSize)
    }

    private func fetchPage(for table: DatabaseTable, offset: Int, limit: Int) async throws -> DataPage {
        try await withSession { session in
            let request = DataQueryRequest(table: table, limit: limit, offset: offset)
            return try await session.execute(query: request)
        }
    }

    private func withSession<T: Sendable>(_ action: @Sendable (DatabaseSession) async throws -> T) async throws -> T {
        guard let connection = selectedConnection,
              let driver = driverRegistry.driver(for: connection.engine) else {
            throw DatabaseDriverError.unsupported
        }

        let session = try await driver.openSession(using: connection)
        do {
            let value = try await action(session)
            await session.close()
            return value
        } catch {
            await session.close()
            throw error
        }
    }

    private func makeRowViewModels(from rows: [DataRow], columns: [DatabaseColumn]) -> [TableRowViewModel] {
        rows.map { TableRowViewModel(row: $0, columns: columns) }
    }

    func startCreatingRow() {
        guard let table = selectedTable else { return }
        rowEditorViewModel = RowEditorViewModel(mode: .insert(table: table, columns: tableColumns))
    }

    func startEditingSelectedRow() {
        guard let table = selectedTable,
              let rowID = selectedRowIDs.first,
              let row = tableRows.first(where: { $0.id == rowID }) else { return }
        rowEditorViewModel = RowEditorViewModel(mode: .update(table: table, columns: tableColumns, original: row.raw))
    }

    func cancelRowEditing() {
        rowEditorViewModel = nil
    }

    func applyRowChanges() {
        guard let editor = rowEditorViewModel else { return }
        isApplyingRowChange = true

        Task {
            do {
                let request = try editor.buildRequest()
                _ = try await withSession { session in
                    try await session.execute(modification: request)
                }
                await loadSelectedTable(reset: true)
                await MainActor.run {
                    self.rowEditorViewModel?.validationMessage = nil
                    self.rowEditorViewModel = nil
                    self.errorMessage = nil
                }
            } catch let error as RowEditorViewModel.RowEditorError {
                await MainActor.run {
                    rowEditorViewModel?.validationMessage = error.localizedDescription
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                self.isApplyingRowChange = false
            }
        }
    }

    func deleteSelectedRows() {
        guard let table = selectedTable else { return }
        let targetRows = tableRows.filter { selectedRowIDs.contains($0.id) }
        guard !targetRows.isEmpty else { return }

        Task {
            do {
                for row in targetRows {
                    guard let lock = makeLock(for: row) else { continue }
                    let request = ModificationRequest(table: table, operation: .delete(optimisticLock: lock))
                    _ = try await withSession { session in
                        try await session.execute(modification: request)
                    }
                }
                await MainActor.run {
                    self.selectedRowIDs.removeAll()
                    self.errorMessage = nil
                }
                await loadSelectedTable(reset: true)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func exportSelectedTableBackup() {
        guard let table = selectedTable else { return }

        Task { [weak self] in
            guard let self else { return }
            guard let destination = await self.requestBackupDestination(for: table) else { return }
            await self.performBackup(for: table, to: destination)
        }
    }

    func exportAllTablesBackup() {
        let tables = schemas
            .flatMap { $0.tables }
            .filter { $0.kind == .table }
        guard !tables.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            guard let directory = await self.requestBackupDirectory() else { return }
            await self.performBackup(for: tables, to: directory)
        }
    }

    private func makeLock(for row: TableRowViewModel) -> ModificationRequest.OptimisticLock? {
        let primaryKeys = tableColumns.filter { $0.constraints.contains(.primaryKey) }
        if !primaryKeys.isEmpty {
            var keys: [String: DatabaseValue] = [:]
            for column in primaryKeys {
                if let value = row.raw.cells[column.name] {
                    keys[column.name] = value
                }
            }
            return ModificationRequest.OptimisticLock(strategy: .primaryKey(keys: keys))
        }
        return ModificationRequest.OptimisticLock(strategy: .allColumns(snapshot: row.raw.cells))
    }

    private func performBackup(for table: DatabaseTable, to destination: URL) async {
        await runBackupTask {
            try await self.writeBackup(for: table, to: destination)
        }
    }

    private func performBackup(for tables: [DatabaseTable], to directory: URL) async {
        await runBackupTask {
            let timestamp = backupDateFormatter.string(from: Date())
            for table in tables {
                let fileName = self.backupFileName(for: table, timestamp: timestamp)
                let destination = directory.appendingPathComponent(fileName)
                try await self.writeBackup(for: table, to: destination)
            }
        }
    }

    private func runBackupTask(_ work: () async throws -> Void) async {
        isExportingBackup = true
        defer { isExportingBackup = false }

        do {
            try await work()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func writeBackup(for table: DatabaseTable, to destination: URL) async throws {
        let snapshot = try await fetchTableSnapshot(for: table)
        let sql = makeBackupSQL(for: table, snapshot: snapshot)
        try sql.write(to: destination, atomically: true, encoding: .utf8)
    }

    private func fetchTableSnapshot(for table: DatabaseTable) async throws -> (columns: [DatabaseColumn], rows: [DataRow]) {
        try await withSession { session in
            let columns = try await session.describe(table: table)
            var rows: [DataRow] = []
            var offset = 0
            let limit = pageSize

            while true {
                let request = DataQueryRequest(table: table, limit: limit, offset: offset)
                let page = try await session.execute(query: request)
                rows.append(contentsOf: page.rows)
                guard page.hasMore else { break }
                offset += page.rows.count
                if page.rows.isEmpty {
                    break
                }
            }

            return (columns, rows)
        }
    }

    private func makeBackupSQL(for table: DatabaseTable, snapshot: (columns: [DatabaseColumn], rows: [DataRow])) -> String {
        var lines: [String] = []
        let timestamp = backupDateFormatter.string(from: Date())
        lines.append("-- Backup for \(table.fullyQualifiedName) at \(timestamp)")
        lines.append("BEGIN TRANSACTION;")

        let columnNames = snapshot.columns.map { escapeIdentifier($0.name) }
        let columnList = columnNames.joined(separator: ", ")
        let qualifiedName = "\(escapeIdentifier(table.schema)).\(escapeIdentifier(table.name))"

        if snapshot.rows.isEmpty {
            lines.append("-- No rows to export")
        } else {
            for row in snapshot.rows {
                let values = snapshot.columns.map { column in
                    sqlLiteral(for: row.cells[column.name])
                }
                let valueList = values.joined(separator: ", ")
                lines.append("INSERT INTO \(qualifiedName) (\(columnList)) VALUES (\(valueList));")
            }
        }

        lines.append("COMMIT;")
        return lines.joined(separator: "\n") + "\n"
    }

    private func sqlLiteral(for value: DatabaseValue?) -> String {
        guard let value else { return "NULL" }

        switch value {
        case .null:
            return "NULL"
        case .bool(let bool):
            return bool ? "TRUE" : "FALSE"
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .decimal(let string):
            return string
        case .string(let string):
            return "'\(escapeStringLiteral(string))'"
        case .date(let date), .timestamp(let date):
            return "'\(iso8601Formatter.string(from: date))'"
        case .blob(let data):
            let hex = data.map { String(format: "%02X", $0) }.joined()
            return "X'\(hex)'"
        case .json(let json):
            return "'\(escapeStringLiteral(json))'"
        case .array(let values):
            let formattedValues = values.map { sqlLiteral(for: $0) }.joined(separator: ", ")
            return "(\(formattedValues))"
        }
    }

    private func escapeIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func escapeStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }

    private func requestBackupDestination(for table: DatabaseTable) async -> URL? {
#if canImport(AppKit)
        let panel = NSSavePanel()
        if let sqlType = UTType(filenameExtension: "sql") {
            panel.allowedContentTypes = [sqlType]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = backupFileName(for: table)
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
#else
        return nil
#endif
    }

    private func requestBackupDirectory() async -> URL? {
#if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
#else
        return nil
#endif
    }

    private func backupFileName(for table: DatabaseTable, timestamp: String? = nil) -> String {
        let resolvedTimestamp = timestamp ?? backupDateFormatter.string(from: Date())
        let schemaComponent = sanitizedFileComponent(table.schema)
        let tableComponent = sanitizedFileComponent(table.name)
        let identifier = schemaComponent.isEmpty ? tableComponent : "\(schemaComponent).\(tableComponent)"
        return "\(resolvedTimestamp)-\(identifier).sql"
    }

    private func sanitizedFileComponent(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitizedScalars = value.unicodeScalars.map { scalar -> String in
            invalidCharacters.contains(scalar) ? "_" : String(scalar)
        }
        let sanitized = sanitizedScalars.joined().replacingOccurrences(of: " ", with: "_")
        return sanitized.isEmpty ? "unnamed" : sanitized
    }

    struct TableRowViewModel: Identifiable {
        let id = UUID()
        let raw: DataRow
        private let values: [String: String]

        init(row: DataRow, columns: [DatabaseColumn]) {
            self.raw = row
            var map: [String: String] = [:]
            for column in columns {
                map[column.name] = Self.format(row.cells[column.name])
            }
            self.values = map
        }

        func displayValue(for column: DatabaseColumn) -> String {
            values[column.name] ?? ""
        }

        static func format(_ value: DatabaseValue?) -> String {
            guard let value else { return "NULL" }
            switch value {
            case .null:
                return "NULL"
            case .bool(let bool):
                return bool ? "TRUE" : "FALSE"
            case .int(let int):
                return String(int)
            case .double(let double):
                return String(double)
            case .decimal(let string):
                return string
            case .string(let string):
                return string
            case .date(let date), .timestamp(let date):
                return ISO8601DateFormatter.string(
                    from: date,
                    timeZone: .current,
                    formatOptions: [.withInternetDateTime]
                )
            case .blob(let data):
                return "BLOB(\(data.count))"
            case .json(let json):
                return json
            case .array(let values):
                return values.map { format($0) }.joined(separator: ", ")
            }
        }
    }
}

@MainActor
private let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

@MainActor
private let backupDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()
