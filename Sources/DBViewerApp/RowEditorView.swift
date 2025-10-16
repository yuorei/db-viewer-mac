import SwiftUI
import DBViewerCore

struct RowEditorView: View {
    @ObservedObject var viewModel: RowEditorViewModel
    var onSave: () -> Void
    var onCancel: () -> Void
    var isSaving: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text(viewModel.title)) {
                    ForEach($viewModel.fields) { $field in
                        VStack(alignment: .leading) {
                            TextField(field.column.name, text: $field.text)
                                .textFieldStyle(.roundedBorder)
                            Text(field.column.dataType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let message = viewModel.validationMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(width: 420)

            Divider()

            HStack {
                Button("キャンセル", action: onCancel)
                Spacer()
                Button(viewModel.actionTitle, action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                if isSaving {
                    ProgressView().controlSize(.small).padding(.leading, 8)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 520)
        .padding(.top)
    }
}
#if canImport(PreviewsMacros)
#Preview {
    let table = DatabaseTable(schema: "public", name: "users")
    let columns = [
        DatabaseColumn(table: table.fullyQualifiedName, name: "id", dataType: "INT", isNullable: false, constraints: [.primaryKey]),
        DatabaseColumn(table: table.fullyQualifiedName, name: "name", dataType: "VARCHAR", isNullable: false),
        DatabaseColumn(table: table.fullyQualifiedName, name: "email", dataType: "VARCHAR", isNullable: false)
    ]
    let vm = RowEditorViewModel(mode: .insert(table: table, columns: columns))
    return RowEditorView(viewModel: vm, onSave: {}, onCancel: {}, isSaving: false)
}
#endif
