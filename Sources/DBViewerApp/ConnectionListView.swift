import SwiftUI
import DBViewerCore

struct ConnectionListView: View {
    @ObservedObject var viewModel: ConnectionListViewModel

    var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedConnection) {
                ForEach(viewModel.connections) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name)
                            .font(.headline)
                        Text(profile.engine.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .tag(profile)
                }
            }
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        viewModel.startCreatingConnection()
                    } label: {
                        Label("接続を追加", systemImage: "plus")
                    }

                    Button {
                        viewModel.startEditingSelectedConnection()
                    } label: {
                        Label("接続を編集", systemImage: "pencil")
                    }
                    .disabled(viewModel.selectedConnection == nil)

                    Button(role: .destructive) {
                        viewModel.requestDeleteSelectedConnection()
                    } label: {
                        Label("接続を削除", systemImage: "trash")
                    }
                    .disabled(viewModel.selectedConnection == nil)
                }
            }
        } detail: {
            if let connection = viewModel.selectedConnection {
                ConnectionDetailView(viewModel: viewModel, connection: connection)
            } else {
                Text("Select a connection")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: viewModel.selectedConnection?.id) { _ in
            Task { await viewModel.loadSchemas() }
        }
        .onChange(of: viewModel.selectedTable?.id) { _ in
            viewModel.refreshSelectedTable()
        }
        .sheet(item: $viewModel.editorViewModel) { editor in
            ConnectionEditorView(
                viewModel: editor,
                onSave: viewModel.saveEditor,
                onCancel: viewModel.cancelEditor,
                isSaving: viewModel.isSaving
            )
            .padding()
        }
        .sheet(item: $viewModel.rowEditorViewModel) { rowEditor in
            RowEditorView(
                viewModel: rowEditor,
                onSave: viewModel.applyRowChanges,
                onCancel: viewModel.cancelRowEditing,
                isSaving: viewModel.isApplyingRowChange
            )
            .padding()
        }
        .confirmationDialog(
            "接続を削除",
            isPresented: Binding(
                get: { viewModel.deleteTarget != nil },
                set: { if !$0 { viewModel.deleteTarget = nil } }
            )
        ) {
            if let target = viewModel.deleteTarget {
                Button("\(target.name) を削除", role: .destructive) {
                    viewModel.confirmDeleteSelectedConnection()
                }
            }
        } message: {
            if let target = viewModel.deleteTarget {
                Text("\(target.name) を削除すると元に戻せません。続行しますか？")
            }
        }
    }
}

private struct ConnectionDetailView: View {
    @ObservedObject var viewModel: ConnectionListViewModel
    let connection: ConnectionProfile

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $viewModel.selectedTable) {
                ForEach(viewModel.schemas) { schema in
                    Section(schema.name) {
                        ForEach(schema.tables) { table in
                            HStack {
                                Label(table.name, systemImage: iconName(for: table))
                                    .labelStyle(.titleAndIcon)
                                Spacer()
                                if let count = table.estimatedRowCount {
                                    Text("\(count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .tag(table)
                        }
                    }
                }
            }
            .frame(minWidth: 220, maxWidth: 260)
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.name)
                        .font(.title2)
                    Text("\(connection.host):\(connection.port)/\(connection.database)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                Picker("表示モード", selection: $viewModel.detailMode) {
                    ForEach(ConnectionListViewModel.DetailMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                switch viewModel.detailMode {
                case .table:
                    if let table = viewModel.selectedTable {
                        TableDataSection(
                            table: table,
                            columns: viewModel.tableColumns,
                            rows: viewModel.tableRows,
                            isLoading: viewModel.isLoadingTable,
                            hasMore: viewModel.tableHasMore,
                            isExportingBackup: viewModel.isExportingBackup,
                            selectedRowIDs: $viewModel.selectedRowIDs,
                            onRefresh: viewModel.refreshSelectedTable,
                            onLoadMore: viewModel.loadMoreRows,
                            onBackup: viewModel.exportSelectedTableBackup,
                            onBackupAll: viewModel.exportAllTablesBackup,
                            onAddRow: viewModel.startCreatingRow,
                            onEditRow: viewModel.startEditingSelectedRow,
                            onDeleteRows: viewModel.deleteSelectedRows
                        )
                    } else {
                        Spacer()
                        Text("テーブルを選択してください")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                case .sql:
                    SQLConsoleView(viewModel: viewModel.sqlConsoleViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .backup:
                    if let backupViewModel = viewModel.backupViewModel {
                        DatabaseBackupView(viewModel: backupViewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        VStack {
                            Spacer()
                            Text("バックアップ機能が利用できません")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func iconName(for table: DatabaseTable) -> String {
        switch table.kind {
        case .table: return "tablecells"
        case .view: return "eye"
        case .materializedView: return "shippingbox"
        }
    }
}

private struct TableDataSection: View {
    let table: DatabaseTable
    let columns: [DatabaseColumn]
    let rows: [ConnectionListViewModel.TableRowViewModel]
    let isLoading: Bool
    let hasMore: Bool
    let isExportingBackup: Bool
    @Binding var selectedRowIDs: Set<UUID>
    let onRefresh: () -> Void
    let onLoadMore: () -> Void
    let onBackup: () -> Void
    let onBackupAll: () -> Void
    let onAddRow: () -> Void
    let onEditRow: () -> Void
    let onDeleteRows: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(table.name)
                        .font(.title3)
                    Text("カラム \(columns.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onRefresh) {
                    Label("再読込", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                Button(action: onBackup) {
                    Label("バックアップ", systemImage: "square.and.arrow.down")
                }
                .disabled(isLoading || isExportingBackup)
                Button(action: onBackupAll) {
                    Label("全テーブルをバックアップ", systemImage: "tray.and.arrow.down")
                }
                .disabled(isLoading || isExportingBackup)
                if isExportingBackup {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    Button(action: onAddRow) {
                        Label("行を追加", systemImage: "plus")
                    }
                    Button(action: onEditRow) {
                        Label("選択行を編集", systemImage: "pencil")
                    }
                    .disabled(selectedRowIDs.count != 1)
                    Button(role: .destructive, action: onDeleteRows) {
                        Label("選択行を削除", systemImage: "trash")
                    }
                    .disabled(selectedRowIDs.isEmpty)
                } label: {
                    Label("操作", systemImage: "square.and.pencil")
                }
            }

            if columns.isEmpty && !isLoading {
                if #available(macOS 14, *) {
                    ContentUnavailableView("カラム情報が取得できません", systemImage: "questionmark.circle")
                } else {
                    Label("カラム情報が取得できません", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                DataGridView(
                    columns: columns,
                    rows: rows,
                    selectedRowIDs: $selectedRowIDs,
                    isLoading: isLoading,
                    onActivateRow: onEditRow
                )
            }

            if hasMore {
                Button {
                    onLoadMore()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("さらに読み込む", systemImage: "arrow.down")
                    }
                }
            }
        }
    }
}

private struct DataGridView: View {
    let columns: [DatabaseColumn]
    let rows: [ConnectionListViewModel.TableRowViewModel]
    @Binding var selectedRowIDs: Set<UUID>
    let isLoading: Bool
    let onActivateRow: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isLoading && rows.isEmpty {
                ProgressView()
            }

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 1) {
                        ForEach(columns, id: \.name) { column in
                            Text(column.name)
                                .font(.footnote.weight(.semibold))
                                .padding(6)
                                .frame(minWidth: 140, alignment: .leading)
                                .background(Color.secondary.opacity(0.15))
                        }
                    }

                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 1) {
                            ForEach(columns, id: \.name) { column in
                                Text(row.displayValue(for: column))
                                    .font(.system(size: 13, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(6)
                                    .frame(minWidth: 140, alignment: .leading)
                                    .background(rowBackground(for: index, selected: selectedRowIDs.contains(row.id)))
                            }
                        }
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            TapGesture(count: 2)
                                .onEnded { activateRow(row) }
                        )
                        .onTapGesture {
                            toggleSelection(for: row.id)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func rowBackground(for index: Int, selected: Bool) -> Color {
        if selected {
            return Color.accentColor.opacity(0.25)
        }
        return index.isMultiple(of: 2) ? Color.primary.opacity(0.02) : Color.clear
    }

    private func toggleSelection(for id: UUID) {
        if selectedRowIDs.contains(id) {
            selectedRowIDs.remove(id)
        } else {
            selectedRowIDs.insert(id)
        }
    }

    private func activateRow(_ row: ConnectionListViewModel.TableRowViewModel) {
        selectedRowIDs = [row.id]
        onActivateRow()
    }
}

