import DBViewerCore
import Foundation

@main
struct MySQLTest {
    static func main() async {
        print("=== MySQL接続テスト ===\n")

        let driver = MySQLDriver()
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Test MySQL",
            engine: .mysql,
            host: "127.0.0.1",
            port: 3306,
            database: "mydb",
            username: "root",
            credential: CredentialReference(storage: .inline("rootpassword"))
        )

        var session: DatabaseSession?

        do {
            // 接続テスト
            print("1. 接続テスト...")
            try await driver.testConnection(using: profile)
            print("   ✓ 接続成功\n")

            // セッション開始
            print("2. セッション開始...")
            session = try await driver.openSession(using: profile)
            print("   ✓ セッション開始成功\n")

            // スキーマ一覧
            print("3. スキーマ一覧:")
            let schemas = try await session!.listSchemas()
            for schema in schemas {
                print("   - \(schema.name)")
            }
            print()

            // テーブル一覧
            print("4. テーブル一覧 (mydb):")
            let tables = try await session!.listTables(in: "mydb")
            for table in tables {
                print("   - \(table.name) (\(table.kind))")
            }
            print()

            print("=== テスト完了 ===")

        } catch {
            print("エラー: \(error)")
        }

        // セッションをクローズ
        if let session = session {
            print("\nセッションをクローズ中...")
            await session.close()
            print("クローズ完了")
        }

        // ドライバをシャットダウン
        print("ドライバをシャットダウン中...")
        try? await driver.shutdown()
        print("シャットダウン完了")
    }
}
