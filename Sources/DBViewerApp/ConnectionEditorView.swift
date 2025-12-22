import SwiftUI
import DBViewerCore

struct ConnectionEditorView: View {
    @ObservedObject var viewModel: ConnectionEditorViewModel
    var onSave: () -> Void
    var onCancel: () -> Void
    var isSaving: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 接続情報セクション
                    VStack(alignment: .leading, spacing: 12) {
                        Text("接続情報")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        LabeledContent("表示名") {
                            TextField("", text: $viewModel.name)
                                .textFieldStyle(.squareBorder)
                        }

                        LabeledContent("DB種別") {
                            Picker("", selection: $viewModel.engine) {
                                ForEach(viewModel.availableEngines, id: \.self) { engine in
                                    Text(engine.displayName).tag(engine)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    Divider()

                    // ホストセクション
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ホスト")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        LabeledContent("ホスト") {
                            TextField("", text: $viewModel.host)
                                .textFieldStyle(.squareBorder)
                        }

                        LabeledContent("ポート") {
                            TextField("", text: $viewModel.port)
                                .textFieldStyle(.squareBorder)
                                .monospacedDigit()
                        }

                        LabeledContent("データベース") {
                            TextField("", text: $viewModel.database)
                                .textFieldStyle(.squareBorder)
                        }
                    }

                    Divider()

                    // 認証セクション
                    VStack(alignment: .leading, spacing: 12) {
                        Text("認証")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        LabeledContent("ユーザー名") {
                            TextField("", text: $viewModel.username)
                                .textFieldStyle(.squareBorder)
                        }

                        LabeledContent("パスワード") {
                            SecureField("", text: $viewModel.password)
                                .textFieldStyle(.squareBorder)
                        }

                        if !viewModel.requiresPassword {
                            Text("このDB種別ではパスワードは任意です")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button("接続テスト") {
                                Task {
                                    await viewModel.testConnection()
                                }
                            }
                            .disabled(!viewModel.canTestConnection || {
                                if case .testing = viewModel.testConnectionState {
                                    return true
                                }
                                return false
                            }())

                            Spacer()

                            if !viewModel.testConnectionStateText.isEmpty {
                                HStack {
                                    if case .testing = viewModel.testConnectionState {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else if case .success = viewModel.testConnectionState {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    } else if case .failure = viewModel.testConnectionState {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                    Text(viewModel.testConnectionStateText)
                                        .font(.caption)
                                        .foregroundStyle({
                                            switch viewModel.testConnectionState {
                                            case .success:
                                                return Color.green
                                            case .testing:
                                                return Color.secondary
                                            case .idle, .failure:
                                                return Color.red
                                            }
                                        }())
                                }
                            }
                        }
                    }

                    Divider()

                    // その他セクション
                    VStack(alignment: .leading, spacing: 12) {
                        Text("その他")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Toggle("TLS/SSLを利用", isOn: $viewModel.useTLS)
                    }
                }
                .padding()
            }
            .frame(width: 420)

            Divider()

            HStack {
                Button("キャンセル", action: onCancel)
                Spacer()
                Button("保存", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.isValid || isSaving)
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 8)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}
#if canImport(PreviewsMacros)
#Preview {
    ConnectionEditorView(
        viewModel: ConnectionEditorViewModel(mode: .create, driverRegistry: nil),
        onSave: {},
        onCancel: {}
    )
}
#endif
