import SwiftUI
import DBViewerCore

struct DatabaseBackupView: View {
    @ObservedObject var viewModel: DatabaseBackupViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("データベースバックアップ")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("選択したテーブルまたは全テーブルのデータをSQLファイルとしてバックアップできます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            // Table Selection Section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("バックアップ対象テーブル")
                        .font(.headline)
                    
                    Spacer()
                    
                    if !viewModel.availableTables.isEmpty {
                        Button("すべて選択") {
                            viewModel.selectAllTables()
                        }
                        .disabled(viewModel.isGeneratingBackup)
                        
                        Button("すべて解除") {
                            viewModel.deselectAllTables()
                        }
                        .disabled(viewModel.isGeneratingBackup)
                    }
                }
                
                if viewModel.isLoadingTables {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("テーブル一覧を読み込み中...")
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.availableTables.isEmpty {
                    Text("利用可能なテーブルがありません")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.availableTables, id: \.id) { table in
                                TableSelectionRow(
                                    table: table,
                                    isSelected: viewModel.selectedTables.contains(table),
                                    onToggle: { viewModel.toggleTableSelection(table) }
                                )
                                .disabled(viewModel.isGeneratingBackup)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 200)
                    .background(Color.primary.opacity(0.02))
                    .cornerRadius(8)
                }
                
                if !viewModel.selectedTables.isEmpty {
                    Text("\(viewModel.selectedTables.count)個のテーブルが選択されています")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !viewModel.availableTables.isEmpty {
                    Text("テーブルが選択されていません。全テーブルがバックアップされます。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            
            // Action Buttons
            HStack(spacing: 12) {
                Button {
                    viewModel.generateBackup()
                } label: {
                    Label("バックアップSQL生成", systemImage: "doc.text")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isGeneratingBackup || viewModel.isLoadingTables)
                
                Button {
                    viewModel.saveBackupToFile()
                } label: {
                    Label("ファイルに保存", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.backupSQL.isEmpty || viewModel.isGeneratingBackup)
                
                Button {
                    viewModel.clearBackup()
                } label: {
                    Label("結果をクリア", systemImage: "xmark.circle")
                }
                .disabled(viewModel.backupSQL.isEmpty || viewModel.isGeneratingBackup)
                
                Spacer()
                
                if viewModel.isGeneratingBackup {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("バックアップSQL生成中...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Status and Error Messages
            if let status = viewModel.statusMessage {
                Label(status, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            
            // Backup SQL Result
            if !viewModel.backupSQL.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("生成されたバックアップSQL")
                        .font(.headline)
                    
                    ScrollView {
                        Text(viewModel.backupSQL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding()
                    }
                    .frame(maxHeight: 300)
                    .background(Color.primary.opacity(0.02))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                }
            }
        }
        .padding()
        .onAppear {
            if viewModel.availableTables.isEmpty && !viewModel.isLoadingTables {
                viewModel.loadAvailableTables()
            }
        }
    }
}

private struct TableSelectionRow: View {
    let table: DatabaseTable
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            Button(action: onToggle) {
                HStack {
                    Image(systemName: isSelected ? "checkmark.square" : "square")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.fullyQualifiedName)
                            .font(.system(.body, design: .monospaced))
                        
                        HStack {
                            Text(table.kind.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            if let rowCount = table.estimatedRowCount {
                                Text("• \(rowCount) rows")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

