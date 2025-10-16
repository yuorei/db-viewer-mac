import Foundation
import DBViewerCore

@MainActor
final class SQLConsoleViewModel: ObservableObject, Identifiable {
    struct ResultRow: Identifiable {
        let id = UUID()
        let values: [String: String]
    }

    @Published var query: String
    @Published var isExecuting: Bool = false
    @Published var resultColumns: [String] = []
    @Published var resultRows: [ResultRow] = []
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let runner: @Sendable (String) async throws -> SQLQueryResult
    private let formatValue: (DatabaseValue?) -> String

    init(
        initialQuery: String = "",
        runner: @escaping @Sendable (String) async throws -> SQLQueryResult,
        formatValue: @escaping (DatabaseValue?) -> String
    ) {
        self.query = initialQuery
        self.runner = runner
        self.formatValue = formatValue
    }

    func execute() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "SQLを入力してください。"
            resultColumns = []
            resultRows = []
            statusMessage = nil
            return
        }

        isExecuting = true
        errorMessage = nil

        Task {
            do {
                let result = try await runner(trimmed)
                await MainActor.run {
                    apply(result: result)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = self.message(for: error)
                    self.isExecuting = false
                }
            }
        }
    }

    func clearResults() {
        resultColumns = []
        resultRows = []
        statusMessage = nil
        errorMessage = nil
    }

    var hasDisplayableResult: Bool {
        !resultColumns.isEmpty || !resultRows.isEmpty || statusMessage != nil
    }

    var canClearResults: Bool {
        hasDisplayableResult || errorMessage != nil
    }

    func suggestQuery(for table: DatabaseTable) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return }
        query = "SELECT * FROM \(table.schema).\(table.name) LIMIT 100;"
    }

    private func apply(result: SQLQueryResult) {
        let formattedRows = result.rows.map { row -> ResultRow in
            var map: [String: String] = [:]
            for column in result.columns {
                map[column] = formatValue(row.cells[column])
            }
            return ResultRow(values: map)
        }

        resultColumns = result.columns
        resultRows = formattedRows
        statusMessage = makeSummary(rows: formattedRows.count, affected: result.affectedRowCount)
        errorMessage = nil
        isExecuting = false
    }

    private func makeSummary(rows: Int, affected: Int?) -> String? {
        var components: [String] = []
        if let affected {
            components.append("影響行数 \(affected)")
        }
        components.append("取得行数 \(rows)")
        return components.joined(separator: " / ")
}

    private func message(for error: Error) -> String {
        if let driverError = error as? DatabaseDriverError {
            switch driverError {
            case .unsupported:
                return "この接続ではSQLコンソールは利用できません。"
            case .connectionFailed(let reason),
                 .queryFailed(let reason):
                return reason
            case .authenticationFailed:
                return "認証に失敗しました。"
            case .notFound:
                return "対象が存在しません。"
            case .optimisticLockFailed:
                return "同時更新が検出されました。"
            case .transactionConflict:
                return "トランザクションが競合しました。"
            }
        }
        return error.localizedDescription
    }
}
