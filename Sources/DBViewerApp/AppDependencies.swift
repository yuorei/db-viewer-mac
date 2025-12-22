import Foundation
import DBViewerCore

struct AppDependencies {
    var connectionStore: any ConnectionStore
    var driverRegistry: DatabaseDriverRegistry

    static func live() -> AppDependencies {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = appSupport.appending(path: "DBViewer")
        let fileURL = directory.appending(path: "connections.json")
        let configuration = ConnectionStoreConfiguration(storageURL: fileURL)
        let store = FileConnectionStore(configuration: configuration)

        // Use real database drivers instead of in-memory drivers with sample data
        let driverRegistry = DatabaseDriverRegistry(drivers: [
            PostgreSQLDriver(),
            MySQLDriver(),
            SQLiteDriver()
        ])

        return AppDependencies(connectionStore: store, driverRegistry: driverRegistry)
    }

    static func preview() -> AppDependencies {
        let sampleProfile = ConnectionProfile(
            name: "Local PostgreSQL",
            engine: .postgres,
            host: "localhost",
            port: 5432,
            database: "postgres",
            username: "postgres",
            credential: .init(storage: .inline("postgres"))
        )
        let store = InMemoryConnectionStore(items: [sampleProfile])

        // Use sample dataset for preview only
        let dataset = sampleDataset()
        let driverRegistry = DatabaseDriverRegistry(drivers: [
            InMemoryDriver(engine: .postgres, dataset: dataset)
        ])

        return AppDependencies(connectionStore: store, driverRegistry: driverRegistry)
    }

    @MainActor
    func makeConnectionListViewModel() -> ConnectionListViewModel {
        ConnectionListViewModel(dependencies: .init(connectionStore: connectionStore), driverRegistry: driverRegistry)
    }

    @MainActor
    func makeConnectionEditorViewModel(mode: ConnectionEditorViewModel.Mode) -> ConnectionEditorViewModel {
        ConnectionEditorViewModel(mode: mode, driverRegistry: driverRegistry)
    }
}

private extension AppDependencies {
    static func sampleDataset() -> InMemoryDataset {
        let usersTable = DatabaseTable(schema: "public", name: "users", estimatedRowCount: 3)
        let ordersTable = DatabaseTable(schema: "public", name: "orders", estimatedRowCount: 2)
        let schema = DatabaseSchema(name: "public", tables: [usersTable, ordersTable])

        let userColumns: [DatabaseColumn] = [
            DatabaseColumn(
                table: usersTable.fullyQualifiedName,
                name: "id",
                dataType: "INT",
                isNullable: false,
                constraints: [.primaryKey]
            ),
            DatabaseColumn(
                table: usersTable.fullyQualifiedName,
                name: "name",
                dataType: "VARCHAR",
                isNullable: false
            ),
            DatabaseColumn(
                table: usersTable.fullyQualifiedName,
                name: "email",
                dataType: "VARCHAR",
                isNullable: false,
                constraints: [.unique]
            ),
            DatabaseColumn(
                table: usersTable.fullyQualifiedName,
                name: "created_at",
                dataType: "TIMESTAMP",
                isNullable: false
            )
        ]

        let orderColumns: [DatabaseColumn] = [
            DatabaseColumn(
                table: ordersTable.fullyQualifiedName,
                name: "id",
                dataType: "INT",
                isNullable: false,
                constraints: [.primaryKey]
            ),
            DatabaseColumn(
                table: ordersTable.fullyQualifiedName,
                name: "user_id",
                dataType: "INT",
                isNullable: false,
                constraints: [.foreignKey(reference: usersTable.fullyQualifiedName)]
            ),
            DatabaseColumn(
                table: ordersTable.fullyQualifiedName,
                name: "total",
                dataType: "DECIMAL",
                isNullable: false
            ),
            DatabaseColumn(
                table: ordersTable.fullyQualifiedName,
                name: "status",
                dataType: "VARCHAR",
                isNullable: false
            )
        ]

        let now = Date()
        let userRows: [DataRow] = [
            DataRow(cells: [
                "id": .int(1),
                "name": .string("Alice"),
                "email": .string("alice@example.com"),
                "created_at": .timestamp(now)
            ]),
            DataRow(cells: [
                "id": .int(2),
                "name": .string("Bob"),
                "email": .string("bob@example.com"),
                "created_at": .timestamp(now)
            ]),
            DataRow(cells: [
                "id": .int(3),
                "name": .string("Carol"),
                "email": .string("carol@example.com"),
                "created_at": .timestamp(now)
            ])
        ]

        let orderRows: [DataRow] = [
            DataRow(cells: [
                "id": .int(101),
                "user_id": .int(1),
                "total": .decimal("49.99"),
                "status": .string("PAID")
            ]),
            DataRow(cells: [
                "id": .int(102),
                "user_id": .int(2),
                "total": .decimal("19.50"),
                "status": .string("PENDING")
            ])
        ]

        return InMemoryDataset(
            schemas: [schema],
            columns: [
                usersTable.id: userColumns,
                ordersTable.id: orderColumns
            ],
            rows: [
                usersTable.id: userRows,
                ordersTable.id: orderRows
            ]
        )
    }
}
