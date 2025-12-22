import Foundation
import DBViewerCore

@MainActor
final class DatabaseBackupViewModel: ObservableObject {
    @Published var isGeneratingBackup: Bool = false
    @Published var backupSQL: String = ""
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var selectedTables: Set<DatabaseTable> = []
    @Published var availableTables: [DatabaseTable] = []
    @Published var isLoadingTables: Bool = false
    
    private let connection: ConnectionProfile
    private let driver: DatabaseDriver
    
    init(connection: ConnectionProfile, driver: DatabaseDriver) {
        self.connection = connection
        self.driver = driver
    }
    
    func loadAvailableTables() {
        isLoadingTables = true
        errorMessage = nil
        
        Task {
            do {
                let session = try await driver.openSession(using: connection)
                defer { 
                    Task { await session.close() }
                }
                
                let schemas = try await session.listSchemas()
                var allTables: [DatabaseTable] = []
                
                for schema in schemas {
                    let tables = try await session.listTables(in: schema.name)
                    allTables.append(contentsOf: tables)
                }
                
                await MainActor.run {
                    self.availableTables = allTables.sorted { $0.fullyQualifiedName < $1.fullyQualifiedName }
                    self.isLoadingTables = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "テーブル一覧の取得に失敗しました: \(error.localizedDescription)"
                    self.isLoadingTables = false
                }
            }
        }
    }
    
    func generateBackup() {
        isGeneratingBackup = true
        errorMessage = nil
        statusMessage = nil
        
        let tablesToBackup = selectedTables.isEmpty ? nil : Array(selectedTables)
        
        Task {
            do {
                let session = try await driver.openSession(using: connection)
                defer { 
                    Task { await session.close() }
                }
                
                let sql = try await session.generateBackupSQL(for: tablesToBackup)
                await MainActor.run {
                    self.backupSQL = sql
                    self.statusMessage = self.makeStatusMessage(tableCount: tablesToBackup?.count ?? self.availableTables.count)
                    self.isGeneratingBackup = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "バックアップSQLの生成に失敗しました: \(error.localizedDescription)"
                    self.isGeneratingBackup = false
                }
            }
        }
    }
    
    func selectAllTables() {
        selectedTables = Set(availableTables)
    }
    
    func deselectAllTables() {
        selectedTables.removeAll()
    }
    
    func toggleTableSelection(_ table: DatabaseTable) {
        if selectedTables.contains(table) {
            selectedTables.remove(table)
        } else {
            selectedTables.insert(table)
        }
    }
    
    func clearBackup() {
        backupSQL = ""
        statusMessage = nil
        errorMessage = nil
    }
    
    func saveBackupToFile() {
        guard !backupSQL.isEmpty else { return }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "sql")!]
        savePanel.nameFieldStringValue = "database_backup_\(dateFormatter.string(from: Date())).sql"
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try self.backupSQL.write(to: url, atomically: true, encoding: .utf8)
                    self.statusMessage = "バックアップファイルを保存しました: \(url.lastPathComponent)"
                } catch {
                    self.errorMessage = "ファイルの保存に失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func makeStatusMessage(tableCount: Int) -> String {
        return "バックアップSQL生成完了 (\(tableCount)テーブル)"
    }
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}

#if canImport(AppKit)
import AppKit
#endif