import Foundation
import Security

public protocol KeychainService: Sendable {
    func storePassword(_ password: String, account: String, service: String) throws
    func password(account: String, service: String) throws -> String?
    func deletePassword(account: String, service: String) throws
}

public enum KeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
    case conversionFailure
}

public final class DefaultKeychainService: KeychainService {
    public init() {}

    public func storePassword(_ password: String, account: String, service: String) throws {
        let passwordData = Data(password.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let update: [CFString: Any] = [kSecValueData: passwordData]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData] = passwordData
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func password(account: String, service: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.conversionFailure
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func deletePassword(account: String, service: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// Note: @unchecked Sendable is used because:
// 1. All mutable state access is protected by NSLock
// 2. KeychainService protocol methods are synchronous, preventing use of actor
public final class InMemoryKeychainService: KeychainService, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func storePassword(_ password: String, account: String, service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key(account: account, service: service)] = password
    }

    public func password(account: String, service: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(account: account, service: service)]
    }

    public func deletePassword(account: String, service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key(account: account, service: service))
    }

    private func key(account: String, service: String) -> String {
        "\(service)::\(account)"
    }
}
