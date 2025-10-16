import Foundation
import DBViewerCore

@MainActor
final class ConnectionEditorViewModel: ObservableObject, Identifiable {
    enum Mode {
        case create
        case edit(ConnectionProfile, password: String)

        var title: String {
            switch self {
            case .create:
                return "新規接続"
            case .edit:
                return "接続を編集"
            }
        }
    }

    let id = UUID()
    let mode: Mode

    @Published var name: String
    @Published var engine: DatabaseEngine
    @Published var host: String
    @Published var port: String
    @Published var database: String
    @Published var username: String
    @Published var password: String
    @Published var useTLS: Bool

    private let profileID: UUID?
    let existingKeychainID: String?

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            self.profileID = nil
            self.existingKeychainID = nil
            self.name = ""
            self.engine = .postgres
            self.host = "localhost"
            self.port = String(Self.defaultPort(for: .postgres))
            self.database = "postgres"
            self.username = "postgres"
            self.password = ""
            self.useTLS = true
        case .edit(let profile, let password):
            self.profileID = profile.id
            if case let .keychain(id) = profile.credential.storage {
                self.existingKeychainID = id
            } else {
                self.existingKeychainID = nil
            }
            self.name = profile.name
            self.engine = profile.engine
            self.host = profile.host
            self.port = String(profile.port)
            self.database = profile.database
            self.username = profile.username
            self.password = password
            self.useTLS = profile.tls.mode != .disabled
        }
    }

    var title: String {
        mode.title
    }

    var availableEngines: [DatabaseEngine] {
        DatabaseEngine.allCases
    }

    var isValid: Bool {
        !name.isEmpty && !host.isEmpty && !database.isEmpty && !username.isEmpty && Int(port) != nil
    }

    var requiresPassword: Bool {
        switch engine {
        case .sqlite:
            return false
        default:
            return true
        }
    }

    var shouldPersistPassword: Bool {
        requiresPassword && !password.isEmpty
    }

    func makeProfile(keychainID: String?) -> ConnectionProfile {
        let portValue = Int(port) ?? Self.defaultPort(for: engine)
        let credential: CredentialReference
        if let keychainID, shouldPersistPassword {
            credential = CredentialReference(storage: .keychain(id: keychainID))
        } else {
            credential = CredentialReference(storage: .inline(""))
        }

        return ConnectionProfile(
            id: profileID ?? UUID(),
            name: name,
            engine: engine,
            host: host,
            port: portValue,
            database: database,
            username: username,
            credential: credential,
            tls: .init(mode: useTLS ? .system : .disabled)
        )
    }

    private static func defaultPort(for engine: DatabaseEngine) -> Int {
        switch engine {
        case .postgres: return 5432
        case .mysql: return 3306
        case .sqlite: return 0
        }
    }
}
