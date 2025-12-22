import Foundation
import DBViewerCore

@MainActor
final class RowEditorViewModel: ObservableObject, Identifiable {
    enum Mode {
        case insert(table: DatabaseTable, columns: [DatabaseColumn])
        case update(table: DatabaseTable, columns: [DatabaseColumn], original: DataRow)

        var table: DatabaseTable {
            switch self {
            case .insert(let table, _):
                return table
            case .update(let table, _, _):
                return table
            }
        }

        var columns: [DatabaseColumn] {
            switch self {
            case .insert(_, let columns):
                return columns
            case .update(_, let columns, _):
                return columns
            }
        }
    }

    struct Field: Identifiable, Hashable {
        let id = UUID()
        let column: DatabaseColumn
        var text: String
        let originalValue: DatabaseValue?
        var isNullable: Bool { column.isNullable }
    }

    enum RowEditorError: LocalizedError {
        case missingRequiredValue(DatabaseColumn)
        case invalidFormat(DatabaseColumn, String)
        case nothingToUpdate

        var errorDescription: String? {
            switch self {
            case .missingRequiredValue(let column):
                return "\(column.name) は必須です"
            case .invalidFormat(let column, let message):
                return "\(column.name): \(message)"
            case .nothingToUpdate:
                return "更新する内容がありません"
            }
        }
    }

    let id = UUID()
    let mode: Mode
    @Published var fields: [Field]
    @Published var validationMessage: String?

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .insert(_, let columns):
            self.fields = columns.map { column in
                Field(column: column, text: "", originalValue: nil)
            }
        case .update(_, let columns, let original):
            self.fields = columns.map { column in
                let value = original.cells[column.name]
                return Field(column: column, text: Self.displayText(for: value), originalValue: value)
            }
        }
    }

    var title: String {
        switch mode {
        case .insert:
            return "行を追加"
        case .update:
            return "行を編集"
        }
    }

    var actionTitle: String {
        switch mode {
        case .insert: return "追加"
        case .update: return "保存"
        }
    }

    var table: DatabaseTable { mode.table }
    var columns: [DatabaseColumn] { mode.columns }

    func buildRequest() throws -> ModificationRequest {
        validationMessage = nil
        let valueMap = try buildValueMap()
        switch mode {
        case .insert(let table, _):
            return ModificationRequest(table: table, operation: .insert(values: valueMap))
        case .update(let table, _, let original):
            let updates = try diff(original: original, values: valueMap)
            guard !updates.isEmpty else {
                throw RowEditorError.nothingToUpdate
            }
            let lock = makeLock(from: original)
            return ModificationRequest(table: table, operation: .update(values: updates, optimisticLock: lock))
        }
    }

    private func buildValueMap() throws -> [String: DatabaseValue] {
        var result: [String: DatabaseValue] = [:]
        for field in fields {
            let trimmed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if field.isNullable {
                    result[field.column.name] = .null
                } else if case .update = mode, field.originalValue != nil {
                    // keep original value
                    continue
                } else {
                    throw RowEditorError.missingRequiredValue(field.column)
                }
            } else {
                result[field.column.name] = try convert(trimmed, for: field.column)
            }
        }
        return result
    }

    private func diff(original: DataRow, values: [String: DatabaseValue]) throws -> [String: DatabaseValue] {
        var updated: [String: DatabaseValue] = [:]
        for (key, value) in values {
            let originalValue = original.cells[key]
            if originalValue != value {
                updated[key] = value
            }
        }
        return updated
    }

    private func makeLock(from original: DataRow) -> ModificationRequest.OptimisticLock {
        let primaryKeys = columns.filter { $0.constraints.contains(.primaryKey) }
        if !primaryKeys.isEmpty {
            var keys: [String: DatabaseValue] = [:]
            for column in primaryKeys {
                if let value = original.cells[column.name] {
                    keys[column.name] = value
                }
            }
            return ModificationRequest.OptimisticLock(strategy: .primaryKey(keys: keys))
        }
        return ModificationRequest.OptimisticLock(strategy: .allColumns(snapshot: original.cells))
    }

    private func convert(_ text: String, for column: DatabaseColumn) throws -> DatabaseValue {
        let lower = column.dataType.lowercased()
        if lower.contains("int") {
            guard let int = Int(text) else {
                throw RowEditorError.invalidFormat(column, "整数を入力してください")
            }
            return .int(int)
        }
        if lower.contains("bool") {
            let normalized = text.lowercased()
            if ["true", "t", "1"].contains(normalized) {
                return .bool(true)
            }
            if ["false", "f", "0"].contains(normalized) {
                return .bool(false)
            }
            throw RowEditorError.invalidFormat(column, "TRUE/FALSE で入力してください")
        }
        if lower.contains("double") || lower.contains("float") {
            guard let double = Double(text) else {
                throw RowEditorError.invalidFormat(column, "数値を入力してください")
            }
            return .double(double)
        }
        if lower.contains("decimal") || lower.contains("numeric") {
            return .decimal(text)
        }
        if lower.contains("timestamp") || lower.contains("date") {
            if let date = ISO8601DateFormatter().date(from: text) {
                return lower.contains("date") && !lower.contains("time") ? .date(date) : .timestamp(date)
            }
            throw RowEditorError.invalidFormat(column, "ISO8601形式で入力してください")
        }
        if lower.contains("json") {
            return .json(text)
        }
        return .string(text)
    }

    private static func displayText(for value: DatabaseValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null:
            return ""
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
            return ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime])
        case .blob:
            return ""
        case .json(let json):
            return json
        case .array(let values):
            return values.map { displayText(for: $0) }.joined(separator: ", ")
        }
    }
}
