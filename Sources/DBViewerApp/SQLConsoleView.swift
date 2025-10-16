import SwiftUI

struct SQLConsoleView: View {
    @ObservedObject var viewModel: SQLConsoleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SQLクエリ")
                    .font(.headline)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.query)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                    if viewModel.query.isEmpty {
                        Text("SQLを入力してください")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.execute()
                } label: {
                    Label("実行", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isExecuting)

                Button {
                    viewModel.clearResults()
                } label: {
                    Label("結果をクリア", systemImage: "xmark.circle")
                }
                .disabled(viewModel.isExecuting || !viewModel.canClearResults)

                Spacer()

                if viewModel.isExecuting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let status = viewModel.statusMessage {
                Label(status, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            SQLResultGridView(columns: viewModel.resultColumns, rows: viewModel.resultRows)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct SQLResultGridView: View {
    let columns: [String]
    let rows: [SQLConsoleViewModel.ResultRow]

    var body: some View {
        Group {
            if columns.isEmpty && rows.isEmpty {
                if #available(macOS 14, *) {
                    ContentUnavailableView("SQLを実行すると結果が表示されます", systemImage: "tablecells")
                } else {
                    Label("SQLを実行すると結果が表示されます", systemImage: "tablecells")
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 1) {
                            ForEach(columns, id: \.self) { column in
                                Text(column)
                                    .font(.footnote.weight(.semibold))
                                    .padding(6)
                                    .frame(minWidth: 140, alignment: .leading)
                                    .background(Color.secondary.opacity(0.15))
                            }
                        }

                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 1) {
                                ForEach(columns, id: \.self) { column in
                                    Text(row.values[column] ?? "")
                                        .font(.system(size: 13, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .padding(6)
                                        .frame(minWidth: 140, alignment: .leading)
                                        .background(rowBackground(for: index))
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func rowBackground(for index: Int) -> Color {
        index.isMultiple(of: 2) ? Color.primary.opacity(0.02) : Color.clear
    }
}
