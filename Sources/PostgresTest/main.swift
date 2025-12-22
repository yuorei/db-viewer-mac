import Foundation
import DBViewerCore

print("Testing PostgreSQL connection...")

let profile = ConnectionProfile(
    name: "Test PostgreSQL",
    engine: .postgres,
    host: "localhost",
    port: 5432,
    database: "testdb",
    username: "postgres",
    credential: CredentialReference(storage: .inline("postgres"))
)

let driver = PostgreSQLDriver()

do {
    print("Testing connection...")
    try await driver.testConnection(using: profile)
    print("✓ Connection test passed!")

    print("\nOpening session...")
    let session = try await driver.openSession(using: profile)
    print("✓ Session opened!")

    print("\nListing schemas...")
    let schemas = try await session.listSchemas()
    for schema in schemas {
        print("  - \(schema.name)")
    }

    print("\nListing tables in 'public' schema...")
    let tables = try await session.listTables(in: "public")
    for table in tables {
        print("  - \(table.name) (\(table.kind))")
    }

    if let usersTable = tables.first(where: { $0.name == "users" }) {
        print("\nDescribing 'users' table...")
        let columns = try await session.describe(table: usersTable)
        for column in columns {
            print("  - \(column.name): \(column.dataType) \(column.isNullable ? "NULL" : "NOT NULL")")
        }

        print("\nQuerying 'users' table...")
        let query = DataQueryRequest(table: usersTable, limit: 10)
        let page = try await session.execute(query: query)
        print("Found \(page.rows.count) rows:")
        for row in page.rows {
            print("  \(row.cells)")
        }
    }

    await session.close()
    print("\n✓ All tests passed!")

} catch {
    print("✗ Error: \(error)")
}
