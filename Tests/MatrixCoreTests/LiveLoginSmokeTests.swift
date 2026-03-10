import Diagnostics
import Foundation
import MatrixCore
import Persistence
import Testing

private struct LiveMatrixTestConfiguration {
    let serverName: String
    let username: String
    let password: String
    let expectedHomeserverHost: String?

    static func load(from environment: [String: String] = ProcessInfo.processInfo.environment) -> LiveMatrixTestConfiguration? {
        guard let serverName = environment["MATRIX_LIVE_TEST_SERVER"], !serverName.isEmpty,
              let username = environment["MATRIX_LIVE_TEST_USERNAME"], !username.isEmpty,
              let password = environment["MATRIX_LIVE_TEST_PASSWORD"], !password.isEmpty else {
            return nil
        }

        return LiveMatrixTestConfiguration(
            serverName: serverName,
            username: username,
            password: password,
            expectedHomeserverHost: environment["MATRIX_LIVE_TEST_EXPECTED_HOMESERVER_HOST"]
        )
    }
}

private enum LiveMatrixTestError: LocalizedError {
    case loginFailed(String)
    case unexpectedSessionState(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .loginFailed(message):
            return message
        case let .unexpectedSessionState(message):
            return message
        case let .timeout(message):
            return message
        }
    }
}

@Test
func wellKnownDiscoveryAndPasswordLoginConnectToLiveHomeserver() async throws {
    guard let config = LiveMatrixTestConfiguration.load() else {
        return
    }

    let diagnostics = DiagnosticsService(subsystem: "test.live-login")
    let paths = try makeLiveTestPaths()
    let database = try AppDatabase(paths: paths, diagnostics: diagnostics)
    let service = MatrixClientService(database: database, diagnostics: diagnostics)

    let sessionStream = await service.sessionStateStream()
    try await performLogin(
        on: service,
        serverNameOrURL: config.serverName,
        username: config.username,
        password: config.password
    )

    let state = try await waitForSessionResolution(from: sessionStream)
    switch state {
    case .connected:
        break
    case let .signedOut(message):
        throw LiveMatrixTestError.loginFailed(message ?? "The homeserver rejected the login.")
    case .launching, .restoring, .signingIn:
        throw LiveMatrixTestError.unexpectedSessionState("Login did not reach a terminal state.")
    }

    let accounts = await service.accountSummaries()
    #expect(accounts.count == 1)

    guard let summary = accounts.first else {
        throw LiveMatrixTestError.unexpectedSessionState("No account summary was published after a successful login.")
    }

    if let expectedHomeserverHost = config.expectedHomeserverHost {
        #expect(summary.homeserver.host(percentEncoded: false) == expectedHomeserverHost)
    }

    let roomListStream = await service.roomListStream(for: summary.accountID, spaceID: nil)
    _ = try await waitForFirstValue(from: roomListStream, timeout: .seconds(20))
}

private func makeLiveTestPaths() throws -> AppPaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MatrixClientLiveTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appSupportURL = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
    try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    return AppPaths(
        applicationSupportURL: appSupportURL,
        databaseURL: appSupportURL.appendingPathComponent("MatrixClient.sqlite")
    )
}

private func waitForSessionResolution(
    from stream: AsyncStream<ClientSessionState>,
    timeout: Duration = .seconds(30)
) async throws -> ClientSessionState {
    try await withThrowingTaskGroup(of: ClientSessionState.self) { group in
        group.addTask {
            for await state in stream {
                switch state {
                case .connected:
                    return state
                case let .signedOut(message):
                    if let message, !message.isEmpty {
                        return .signedOut(message: message)
                    }
                case .launching, .restoring, .signingIn:
                    continue
                }
            }
            throw LiveMatrixTestError.unexpectedSessionState("The session-state stream ended before login completed.")
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            throw LiveMatrixTestError.timeout("Timed out waiting for the live Matrix login to finish.")
        }

        let resolved = try await group.next()!
        group.cancelAll()
        return resolved
    }
}

private func performLogin(
    on service: MatrixClientService,
    serverNameOrURL: String,
    username: String,
    password: String,
    timeout: Duration = .seconds(30)
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await service.login(serverNameOrURL: serverNameOrURL, username: username, password: password)
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            throw LiveMatrixTestError.timeout("Timed out waiting for the live Matrix login request to complete.")
        }

        _ = try await group.next()
        group.cancelAll()
    }
}

private func waitForFirstValue<Value: Sendable>(
    from stream: AsyncStream<Value>,
    timeout: Duration
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            for await value in stream {
                return value
            }
            throw LiveMatrixTestError.unexpectedSessionState("The expected stream ended before producing a value.")
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            throw LiveMatrixTestError.timeout("Timed out waiting for a value from the live Matrix stream.")
        }

        let firstValue = try await group.next()!
        group.cancelAll()
        return firstValue
    }
}
