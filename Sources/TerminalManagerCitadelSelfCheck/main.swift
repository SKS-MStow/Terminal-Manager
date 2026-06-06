import TerminalManagerCitadelSupport
import TerminalManagerCore

private struct StaticPasswordProvider: CitadelPasswordProvider {
    var password: String

    func password(service: String, account: String) throws -> String {
        password
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

private func passwordProfile(hostKeyPolicy: SSHHostKeyPolicy = .knownHosts) -> SSHConnectionProfile {
    SSHConnectionProfile(
        host: HostProfile(
            displayName: "Test",
            hostname: "example.com",
            username: "mark",
            preferredTransport: .ssh
        ),
        authentication: .passwordKeychain(service: "terminal-manager", account: "mark@example.com"),
        hostKeyPolicy: hostKeyPolicy
    )
}

let smokeFactory = CitadelConnectionFactory(
    allowUnsafeHostKeyPolicy: true,
    passwordProvider: StaticPasswordProvider(password: "secret")
)
let settings = try smokeFactory.settings(for: passwordProfile(hostKeyPolicy: .acceptAnyForSmokeOnly))
expect(settings.host == "example.com", "Expected host to map into Citadel settings")
expect(settings.port == 22, "Expected default SSH port to map into Citadel settings")
_ = settings.authenticationMethod()

let pinnedSettings = try CitadelConnectionFactory(passwordProvider: StaticPasswordProvider(password: "secret"))
    .settings(for: passwordProfile(hostKeyPolicy: .pinnedSHA256("SHA256:abc123=")))
expect(pinnedSettings.host == "example.com", "Expected pinned host-key settings to map host")
expect(pinnedSettings.port == 22, "Expected pinned host-key settings to map port")
_ = pinnedSettings.authenticationMethod()

do {
    _ = try CitadelConnectionFactory(passwordProvider: StaticPasswordProvider(password: "secret"))
        .settings(for: passwordProfile(hostKeyPolicy: .pinnedSHA256("  ")))
    fatalError("Expected empty pinned host-key fingerprint to throw")
} catch CitadelSupportError.invalidPinnedHostKeyFingerprint(_) {
} catch {
    fatalError("Unexpected empty pinned host-key error: \(error)")
}

do {
    _ = try CitadelConnectionFactory(passwordProvider: StaticPasswordProvider(password: "secret"))
        .settings(for: passwordProfile(hostKeyPolicy: .acceptAnyForSmokeOnly))
    fatalError("Expected unsafe host-key policy to throw without explicit smoke allowance")
} catch CitadelSupportError.unsafeHostKeyPolicyNotAllowed {
} catch {
    fatalError("Unexpected unsafe host-key policy error: \(error)")
}

do {
    _ = try CitadelConnectionFactory().settings(for: passwordProfile(hostKeyPolicy: .acceptAnyForSmokeOnly))
    fatalError("Expected unsafe host-key policy to throw before password lookup")
} catch CitadelSupportError.unsafeHostKeyPolicyNotAllowed {
} catch {
    fatalError("Unexpected unsafe host-key policy error: \(error)")
}

do {
    _ = try CitadelConnectionFactory(allowUnsafeHostKeyPolicy: true).settings(
        for: passwordProfile(hostKeyPolicy: .acceptAnyForSmokeOnly)
    )
    fatalError("Expected missing password provider to throw")
} catch CitadelSupportError.passwordNotAvailable(service: "terminal-manager", account: "mark@example.com") {
} catch {
    fatalError("Unexpected missing password error: \(error)")
}

do {
    _ = try CitadelConnectionFactory(passwordProvider: StaticPasswordProvider(password: "secret"))
        .settings(for: passwordProfile())
    fatalError("Expected unsupported host-key policy to throw")
} catch CitadelSupportError.unsupportedHostKeyPolicy(.knownHosts) {
} catch {
    fatalError("Unexpected known-hosts policy error: \(error)")
}

do {
    let profile = SSHConnectionProfile(
        host: HostProfile(displayName: "Test", hostname: "example.com", username: "mark", preferredTransport: .ssh),
        authentication: .agent,
        hostKeyPolicy: .acceptAnyForSmokeOnly
    )
    _ = try CitadelConnectionFactory(allowUnsafeHostKeyPolicy: true).settings(for: profile)
    fatalError("Expected unsupported agent auth to throw")
} catch CitadelSupportError.unsupportedAuthentication(.agent) {
} catch {
    fatalError("Unexpected agent auth error: \(error)")
}

print("Terminal Manager Citadel self-check passed")
