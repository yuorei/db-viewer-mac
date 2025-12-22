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
            database: "testdb",
            username: "root",
            credential: CredentialReference(storage: .inline("password"))
        )

        do {
            // 接続テスト
            print("1. 接続テスト...")
            try await driver.testConnection(using: profile)
            print("   ✓ 接続成功\n")

            // セッション開始
            print("2. セッション開始...")
            let session = try await driver.openSession(using: profile)
            print("   ✓ セッション開始成功\n")

            // スキーマ一覧
            print("3. スキーマ一覧:")
            let schemas = try await session.listSchemas()
            for schema in schemas {
                print("   - \(schema.name)")
            }
            print()

            // テーブル一覧
            print("4. テーブル一覧 (testdb):")
            let tables = try await session.listTables(in: "testdb")
            for table in tables {
                print("   - \(table.name) (\(table.kind))")
            }
            print()

            // テーブル構造
            if let usersTable = tables.first(where: { $0.name == "users" }) {
                print("5. usersテーブルの構造:")
                let columns = try await session.describe(table: usersTable)
                for col in columns {
                    let pk = col.constraints.contains(DatabaseColumn.ColumnConstraint.primaryKey) ? " [PK]" : ""
                    let nullable = col.isNullable ? "NULL" : "NOT NULL"
                    print("   - \(col.name): \(col.dataType) \(nullable)\(pk)")
                }
                print()

                // データ取得
                print("6. usersテーブルのデータ:")
                let query = DataQueryRequest(table: usersTable, limit: 10, offset: 0)
                let page = try await session.execute(query: query)
                for row in page.rows {
                    let id = row.cells["id"] ?? .null
                    let username = row.cells["username"] ?? .null
                    let email = row.cells["email"] ?? .null
                    print("   - id=\(id), username=\(username), email=\(email)")
                }
                print()
            }

            // productsテーブル
            if let productsTable = tables.first(where: { $0.name == "products" }) {
                print("7. productsテーブルのデータ:")
                let query = DataQueryRequest(table: productsTable, limit: 10, offset: 0)
                let page = try await session.execute(query: query)
                for row in page.rows {
                    let id = row.cells["id"] ?? .null
                    let name = row.cells["name"] ?? .null
                    let price = row.cells["price"] ?? .null
                    let stock = row.cells["stock"] ?? .null
                    print("   - id=\(id), name=\(name), price=\(price), stock=\(stock)")
                }
                print()
            }

            // SQLクエリ実行
            print("8. SQLクエリ実行 (SELECT * FROM users WHERE username = 'alice'):")
            let sqlResult = try await session.execute(sql: "SELECT * FROM users WHERE username = 'alice'", limit: 10)
            print("   カラム: \(sqlResult.columns.joined(separator: ", "))")
            for row in sqlResult.rows {
                print("   データ: \(row.cells)")
            }
            print()

            // セッションクローズ
            print("9. セッションクローズ...")
            await session.close()
            print("   ✓ クローズ成功\n")

            print("=== すべてのテスト完了 ===")

        } catch {
            print("エラー: \(error)")
        }
    }
}
