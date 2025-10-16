import Foundation
import CryptoKit

public protocol ConnectionStore: Sendable {
    func loadConnections() async throws -> [ConnectionProfile]
    func saveConnections(_ connections: [ConnectionProfile]) async throws
    func upsert(_ profile: ConnectionProfile) async throws -> [ConnectionProfile]
    func delete(_ profile: ConnectionProfile) async throws -> [ConnectionProfile]
}

public struct ConnectionStoreConfiguration: Sendable {
    public var storageURL: URL
    public var keychainServiceName: String

    public init(storageURL: URL, keychainServiceName: String) {
        self.storageURL = storageURL
        self.keychainServiceName = keychainServiceName
    }
}

public final class FileConnectionStore: ConnectionStore, @unchecked Sendable {
    private let configuration: ConnectionStoreConfiguration
    private let keychain: KeychainService
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: ConnectionStoreConfiguration,
        keychain: KeychainService,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    public func loadConnections() async throws -> [ConnectionProfile] {
        guard fileManager.fileExists(atPath: configuration.storageURL.path) else {
            return []
        }

        let encrypted = try Data(contentsOf: configuration.storageURL)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encrypted) else {
            throw ConnectionStoreError.invalidPayload
        }

        let key = try obtainEncryptionKey()
        let decrypted = try AES.GCM.open(sealedBox, using: key)
        let document = try decoder.decode(ConnectionDocument.self, from: decrypted)
        return document.connections
    }

    public func saveConnections(_ connections: [ConnectionProfile]) async throws {
        let document = ConnectionDocument(connections: connections)
        let data = try encoder.encode(document)
        let key = try obtainEncryptionKey()
        let sealedBox = try AES.GCM.seal(data, using: key)
        try ensureDirectoryExists()
        try sealedBox.combined?.write(to: configuration.storageURL, options: .atomic)
    }

    public func upsert(_ profile: ConnectionProfile) async throws -> [ConnectionProfile] {
        var connections = try await loadConnections()
        if let index = connections.firstIndex(where: { $0.id == profile.id }) {
            connections[index] = profile
        } else {
            connections.append(profile)
        }
        try await saveConnections(connections)
        return connections
    }

    public func delete(_ profile: ConnectionProfile) async throws -> [ConnectionProfile] {
        var connections = try await loadConnections()
        connections.removeAll { $0.id == profile.id }
        try await saveConnections(connections)
        try cleanupKeychain(for: profile)
        return connections
    }

    private func cleanupKeychain(for profile: ConnectionProfile) throws {
        guard case let .keychain(id) = profile.credential.storage else { return }
        try keychain.deletePassword(account: id, service: configuration.keychainServiceName)
    }

    private func ensureDirectoryExists() throws {
        let directory = configuration.storageURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func obtainEncryptionKey() throws -> SymmetricKey {
        let keyId = "encryption-key"
        if let existing = try keychain.password(account: keyId, service: configuration.keychainServiceName) {
            guard let data = Data(base64Encoded: existing) else {
                throw ConnectionStoreError.invalidKeyMaterial
            }
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let base64 = Data(key.withUnsafeBytes { Data($0) }).base64EncodedString()
        try keychain.storePassword(base64, account: keyId, service: configuration.keychainServiceName)
        return key
    }
}

public enum ConnectionStoreError: Error, Sendable {
    case invalidPayload
    case invalidKeyMaterial
}

public actor InMemoryConnectionStore: ConnectionStore {
    private var items: [ConnectionProfile]

    public init(items: [ConnectionProfile] = []) {
        self.items = items
    }

    public func loadConnections() async throws -> [ConnectionProfile] {
        items
    }

    public func saveConnections(_ connections: [ConnectionProfile]) async throws {
        items = connections
    }

    public func upsert(_ profile: ConnectionProfile) async throws -> [ConnectionProfile] {
        if let index = items.firstIndex(where: { $0.id == profile.id }) {
            items[index] = profile
        } else {
            items.append(profile)
        }
        return items
    }

    public func delete(_ profile: ConnectionProfile) async throws -> [ConnectionProfile] {
        items.removeAll { $0.id == profile.id }
        return items
    }
}

private struct ConnectionDocument: Codable, Sendable {
    var connections: [ConnectionProfile]
}
