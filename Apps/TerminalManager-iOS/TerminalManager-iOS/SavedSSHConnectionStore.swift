import Foundation
import Security
import TerminalManagerCitadelSupport
import TerminalManagerCore

struct SavedSSHConnection: Codable, Equatable, Sendable {
    var displayName: String
    var hostname: String
    var port: Int
    var username: String
    var allowUnsafeHostKeyPolicy: Bool

    var host: HostProfile {
        HostProfile(
            displayName: displayName.isEmpty ? hostname : displayName,
            hostname: hostname,
            port: port,
            username: username,
            preferredTransport: .ssh
        )
    }
}

enum SavedSSHConnectionStoreError: Error, Equatable {
    case missingHostname
    case missingUsername
    case invalidPort
    case missingPassword
    case passwordEncodingFailed
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
}

struct SavedSSHConnectionDraft: Equatable {
    var displayName: String = ""
    var hostname: String = ""
    var port: String = "22"
    var username: String = NSUserName()
    var password: String = ""
    var allowUnsafeHostKeyPolicy: Bool = true

    init() {}

    init(saved: SavedSSHConnection, password: String = "") {
        self.displayName = saved.displayName
        self.hostname = saved.hostname
        self.port = String(saved.port)
        self.username = saved.username
        self.password = password
        self.allowUnsafeHostKeyPolicy = saved.allowUnsafeHostKeyPolicy
    }
}

struct SavedSSHConnectionStore: @unchecked Sendable {
    static let shared = SavedSSHConnectionStore()

    static let passwordService = "TerminalManagerSavedSSH"

    private let defaults: UserDefaults
    private let keyPrefix = "TerminalManager.savedSSH."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SavedSSHConnection? {
        guard
            let hostname = defaults.string(forKey: key("hostname")),
            !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let username = defaults.string(forKey: key("username")),
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let port = defaults.integer(forKey: key("port"))
        return SavedSSHConnection(
            displayName: defaults.string(forKey: key("displayName")) ?? hostname,
            hostname: hostname,
            port: port > 0 ? port : 22,
            username: username,
            allowUnsafeHostKeyPolicy: defaults.bool(forKey: key("allowUnsafeHostKeyPolicy"))
        )
    }

    func loadPassword(for connection: SavedSSHConnection) throws -> String {
        try KeychainPasswordProvider().password(
            service: Self.passwordService,
            account: Self.passwordAccount(for: connection.host)
        )
    }

    func save(_ draft: SavedSSHConnectionDraft) throws -> SavedSSHConnection {
        let hostname = draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else {
            throw SavedSSHConnectionStoreError.missingHostname
        }
        guard !username.isEmpty else {
            throw SavedSSHConnectionStoreError.missingUsername
        }
        guard let port = Int(draft.port), (1...65_535).contains(port) else {
            throw SavedSSHConnectionStoreError.invalidPort
        }
        guard !draft.password.isEmpty else {
            throw SavedSSHConnectionStoreError.missingPassword
        }

        let connection = SavedSSHConnection(
            displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            hostname: hostname,
            port: port,
            username: username,
            allowUnsafeHostKeyPolicy: draft.allowUnsafeHostKeyPolicy
        )
        try savePassword(draft.password, for: connection)

        defaults.set(connection.displayName, forKey: key("displayName"))
        defaults.set(connection.hostname, forKey: key("hostname"))
        defaults.set(connection.port, forKey: key("port"))
        defaults.set(connection.username, forKey: key("username"))
        defaults.set(connection.allowUnsafeHostKeyPolicy, forKey: key("allowUnsafeHostKeyPolicy"))

        return connection
    }

    func delete() throws {
        if let connection = load() {
            try deletePassword(for: connection)
        }
        ["displayName", "hostname", "port", "username", "allowUnsafeHostKeyPolicy"].forEach {
            defaults.removeObject(forKey: key($0))
        }
    }

    static func passwordAccount(for host: HostProfile) -> String {
        "\(host.username)@\(host.hostname):\(host.port)"
    }

    private func savePassword(_ password: String, for connection: SavedSSHConnection) throws {
        guard let data = password.data(using: .utf8) else {
            throw SavedSSHConnectionStoreError.passwordEncodingFailed
        }

        let query = passwordQuery(account: Self.passwordAccount(for: connection.host))
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SavedSSHConnectionStoreError.keychainWriteFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SavedSSHConnectionStoreError.keychainWriteFailed(status)
        }
    }

    private func deletePassword(for connection: SavedSSHConnection) throws {
        let status = SecItemDelete(passwordQuery(account: Self.passwordAccount(for: connection.host)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SavedSSHConnectionStoreError.keychainDeleteFailed(status)
        }
    }

    private func key(_ suffix: String) -> String {
        keyPrefix + suffix
    }
}

struct KeychainPasswordProvider: CitadelPasswordProvider {
    func password(service: String, account: String) throws -> String {
        var query = passwordQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw SavedSSHConnectionStoreError.keychainReadFailed(status)
        }
        guard
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        else {
            throw SavedSSHConnectionStoreError.missingPassword
        }

        return password
    }
}

private func passwordQuery(
    service: String = SavedSSHConnectionStore.passwordService,
    account: String
) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
}
