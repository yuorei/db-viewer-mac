import Foundation

public protocol ConnectionStore: Sendable {
    func loadConnections() async throws -> [ConnectionProfile]
    func saveConnections(_ connections: [ConnectionProfile]) async throws
    func upsert(_ profile: ConnectionProfile) async throws -> [ConnectionProfile]
    func delete(_ profile: ConnectionProfile) async throws -> [ConnectionProfile]
}

public struct ConnectionStoreConfiguration: Sendable {
    public var storageURL: URL

    public init(storageURL: URL) {
        self.storageURL = storageURL
    }
}

public actor FileConnectionStore: ConnectionStore {
    private let configuration: ConnectionStoreConfiguration
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: ConnectionStoreConfiguration,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
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

        let data = try Data(contentsOf: configuration.storageURL)
        let document = try decoder.decode(ConnectionDocument.self, from: data)
        return document.connections
    }

    public func saveConnections(_ connections: [ConnectionProfile]) async throws {
        let document = ConnectionDocument(connections: connections)
        let data = try encoder.encode(document)
        try ensureDirectoryExists()
        try data.write(to: configuration.storageURL, options: .atomic)
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
        return connections
    }

    private func ensureDirectoryExists() throws {
        let directory = configuration.storageURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

public enum ConnectionStoreError: Error, Sendable {
    case invalidPayload
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
