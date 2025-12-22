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

    enum TestConnectionState {
        case idle
        case testing
        case success
        case failure(String)
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
    @Published var testConnectionState: TestConnectionState = .idle

    private let profileID: UUID?
    private let driverRegistry: DatabaseDriverRegistry?

    init(mode: Mode, driverRegistry: DatabaseDriverRegistry? = nil) {
        self.mode = mode
        self.driverRegistry = driverRegistry
        switch mode {
        case .create:
            self.profileID = nil
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

    var canTestConnection: Bool {
        isValid && driverRegistry != nil
    }

    var testConnectionStateText: String {
        switch testConnectionState {
        case .idle:
            return ""
        case .testing:
            return "接続中..."
        case .success:
            return "接続成功"
        case .failure(let error):
            return "接続失敗: \(error)"
        }
    }

    func testConnection() async {
        guard let driverRegistry = driverRegistry,
              let driver = driverRegistry.driver(for: engine) else {
            testConnectionState = .failure("対応していないデータベース種別です")
            return
        }

        testConnectionState = .testing

        do {
            let profile = makeProfile()
            try await driver.testConnection(using: profile)
            testConnectionState = .success

            // Reset to idle after 3 seconds
            Task {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                if case .success = testConnectionState {
                    testConnectionState = .idle
                }
            }
        } catch {
            testConnectionState = .failure(error.localizedDescription)

            // Reset to idle after 5 seconds
            Task {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if case .failure = testConnectionState {
                    testConnectionState = .idle
                }
            }
        }
    }

    func makeProfile() -> ConnectionProfile {
        let portValue = Int(port) ?? Self.defaultPort(for: engine)
        let credential = CredentialReference(storage: .inline(password))

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
