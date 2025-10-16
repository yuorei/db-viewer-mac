import SwiftUI
import DBViewerCore

struct ConnectionEditorView: View {
    @ObservedObject var viewModel: ConnectionEditorViewModel
    var onSave: () -> Void
    var onCancel: () -> Void
    var isSaving: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("接続情報") {
                    TextField("表示名", text: $viewModel.name)
                    Picker("DB種別", selection: $viewModel.engine) {
                        ForEach(viewModel.availableEngines, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                }

                Section("ホスト") {
                    TextField("ホスト", text: $viewModel.host)
                    TextField("ポート", text: $viewModel.port)
                        .monospacedDigit()
                        .textFieldStyle(.roundedBorder)
                    TextField("データベース", text: $viewModel.database)
                }

                Section("認証") {
                    TextField("ユーザー名", text: $viewModel.username)
                    SecureField("パスワード", text: $viewModel.password)
                    if !viewModel.requiresPassword {
                        Text("このDB種別ではパスワードは任意です").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("その他") {
                    Toggle("TLS/SSLを利用", isOn: $viewModel.useTLS)
                }
            }
            .formStyle(.grouped)
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
        .padding(.top)
    }
}
#if canImport(PreviewsMacros)
#Preview {
    ConnectionEditorView(
        viewModel: ConnectionEditorViewModel(mode: .create),
        onSave: {},
        onCancel: {}
    )
}
#endif
