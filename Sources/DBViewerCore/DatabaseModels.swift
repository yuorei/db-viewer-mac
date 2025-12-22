import Foundation

public enum DatabaseEngine: String, Codable, CaseIterable, Sendable {
    case postgres
    case mysql
    case sqlite

    public var displayName: String {
        switch self {
        case .postgres: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .sqlite: return "SQLite"
        }
    }
}

public struct SSHConfiguration: Codable, Sendable, Equatable, Hashable {
    public enum Authentication: Codable, Sendable, Equatable, Hashable {
        case password(String)
        case keyFile(path: String, passphrase: String?)
    }

    public var host: String
    public var port: Int
    public var username: String
    public var authentication: Authentication

    public init(host: String, port: Int = 22, username: String, authentication: Authentication) {
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
    }
}

public struct CredentialReference: Codable, Sendable, Equatable, Hashable {
    public enum Storage: Codable, Sendable, Hashable {
        case keychain(id: String)
        case inline(String)
    }

    public var storage: Storage

    public init(storage: Storage) {
        self.storage = storage
    }
}

public struct ConnectionProfile: Identifiable, Codable, Sendable, Equatable, Hashable {
    public struct TLSConfiguration: Codable, Sendable, Equatable, Hashable {
        public enum Mode: String, Codable, Sendable, Hashable {
            case disabled
            case system
            case pinnedCertificate
        }

        public var mode: Mode
        public var pinnedCertificatePath: String?

        public init(mode: Mode = .system, pinnedCertificatePath: String? = nil) {
            self.mode = mode
            self.pinnedCertificatePath = pinnedCertificatePath
        }
    }

    public var id: UUID
    public var name: String
    public var engine: DatabaseEngine
    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var credential: CredentialReference
    public var tls: TLSConfiguration
    public var sshConfiguration: SSHConfiguration?

    public init(
        id: UUID = UUID(),
        name: String,
        engine: DatabaseEngine,
        host: String,
        port: Int,
        database: String,
        username: String,
        credential: CredentialReference,
        tls: TLSConfiguration = .init(),
        sshConfiguration: SSHConfiguration? = nil
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.credential = credential
        self.tls = tls
        self.sshConfiguration = sshConfiguration
    }
}

public struct DatabaseSchema: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { name }
    public var name: String
    public var tables: [DatabaseTable]

    public init(name: String, tables: [DatabaseTable] = []) {
        self.name = name
        self.tables = tables
    }
}

public struct DatabaseTable: Identifiable, Codable, Sendable, Equatable, Hashable {
    public enum TableKind: String, Codable, Sendable {
        case table
        case view
        case materializedView
    }

    public var id: String { fullyQualifiedName }
    public var schema: String
    public var name: String
    public var kind: TableKind
    public var estimatedRowCount: Int?

    public var fullyQualifiedName: String {
        "\(schema).\(name)"
    }

    public init(schema: String, name: String, kind: TableKind = .table, estimatedRowCount: Int? = nil) {
        self.schema = schema
        self.name = name
        self.kind = kind
        self.estimatedRowCount = estimatedRowCount
    }
}

public struct DatabaseColumn: Identifiable, Codable, Sendable, Equatable, Hashable {
    public enum ColumnConstraint: Codable, Sendable, Hashable {
        case primaryKey
        case foreignKey(reference: String)
        case unique
        case notNull
        case check(expression: String)
    }

    public var id: String { "\(table).\(name)" }
    public var table: String
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    public var defaultValue: String?
    public var constraints: Set<ColumnConstraint>

    public init(
        table: String,
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        constraints: Set<ColumnConstraint> = []
    ) {
        self.table = table
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.constraints = constraints
    }
}

public struct DataRow: Sendable, Equatable {
    public var cells: [String: DatabaseValue]

    public init(cells: [String: DatabaseValue]) {
        self.cells = cells
    }
}

public struct DataPage: Sendable, Equatable {
    public var rows: [DataRow]
    public var totalCount: Int?
    public var hasMore: Bool

    public init(rows: [DataRow], totalCount: Int? = nil, hasMore: Bool) {
        self.rows = rows
        self.totalCount = totalCount
        self.hasMore = hasMore
    }
}

public struct SQLQueryResult: Sendable, Equatable {
    public var columns: [String]
    public var rows: [DataRow]
    public var affectedRowCount: Int?

    public init(columns: [String] = [], rows: [DataRow] = [], affectedRowCount: Int? = nil) {
        self.columns = columns
        self.rows = rows
        self.affectedRowCount = affectedRowCount
    }
}

public enum DatabaseValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case decimal(String)
    case string(String)
    case date(Date)
    case timestamp(Date)
    case blob(Data)
    case json(String)
    /// IN句で使用する複数値の配列
    case array([DatabaseValue])
}
