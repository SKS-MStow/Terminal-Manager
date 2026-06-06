import Foundation

public enum SSHAuthenticationReference: Equatable, Sendable {
    case passwordKeychain(service: String, account: String)
    case privateKeyFile(path: String, passphraseKeychain: KeychainReference?)
    case agent
    case none
}

public struct KeychainReference: Equatable, Sendable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public enum SSHHostKeyPolicy: Equatable, Sendable {
    case knownHosts
    case pinnedSHA256(String)
    case acceptAnyForSmokeOnly

    public var isUnsafe: Bool {
        if case .acceptAnyForSmokeOnly = self {
            return true
        }
        return false
    }
}

public struct SSHConnectionProfile: Equatable, Sendable {
    public var host: HostProfile
    public var authentication: SSHAuthenticationReference
    public var hostKeyPolicy: SSHHostKeyPolicy

    public init(
        host: HostProfile,
        authentication: SSHAuthenticationReference = .agent,
        hostKeyPolicy: SSHHostKeyPolicy = .knownHosts
    ) {
        self.host = host
        self.authentication = authentication
        self.hostKeyPolicy = hostKeyPolicy
    }
}

public enum SSHConfigurationError: Error, Equatable {
    case unsafeHostKeyPolicyNotAllowed
    case missingPrivateKey(path: String)
    case passwordNotAvailable(KeychainReference)
}
