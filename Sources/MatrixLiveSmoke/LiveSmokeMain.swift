import Diagnostics
import Darwin
import Foundation
import MatrixCore
import Persistence

private struct LiveSmokeConfiguration {
    let serverName: String
    let username: String
    let password: String
    let expectedHomeserverHost: String?

    static func load(from environment: [String: String] = ProcessInfo.processInfo.environment) -> LiveSmokeConfiguration? {
        guard let serverName = environment["MATRIX_LIVE_TEST_SERVER"], !serverName.isEmpty,
              let username = environment["MATRIX_LIVE_TEST_USERNAME"], !username.isEmpty,
              let password = environment["MATRIX_LIVE_TEST_PASSWORD"], !password.isEmpty else {
            return nil
        }

        return LiveSmokeConfiguration(
            serverName: serverName,
            username: username,
            password: password,
            expectedHomeserverHost: environment["MATRIX_LIVE_TEST_EXPECTED_HOMESERVER_HOST"]
        )
    }
}

private enum LiveSmokeError: LocalizedError {
    case missingConfiguration
    case loginFailed(String)
    case timeout(String)
    case unexpectedState(String)
    case missingAccountSummary
    case homeserverMismatch(expected: String, actual: String?)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return """
            Missing configuration. Set MATRIX_LIVE_TEST_SERVER, MATRIX_LIVE_TEST_USERNAME, and MATRIX_LIVE_TEST_PASSWORD.
            """
        case let .loginFailed(message):
            return message
        case let .timeout(message):
            return message
        case let .unexpectedState(message):
            return message
        case .missingAccountSummary:
            return "Login completed without publishing an account summary."
        case let .homeserverMismatch(expected, actual):
            return "Expected discovered homeserver host \(expected), got \(actual ?? "<nil>")."
        }
    }
}

@main
struct MatrixLiveSmoke {
    static func main() async {
        do {
            guard let configuration = LiveSmokeConfiguration.load() else {
                throw LiveSmokeError.missingConfiguration
            }

            let diagnostics = DiagnosticsService(subsystem: "com.brandonstone.MatrixClient.live-smoke")
            let paths = try makePaths()
            let database = try AppDatabase(paths: paths, diagnostics: diagnostics)
            let service = MatrixClientService(database: database, diagnostics: diagnostics)

            let stateStream = await service.sessionStateStream()
            try await performLogin(on: service, configuration: configuration)
            let resolvedState = try await waitForSessionResolution(from: stateStream)

            switch resolvedState {
            case .connected:
                break
            case let .signedOut(message):
                throw LiveSmokeError.loginFailed(message ?? "The homeserver rejected the login.")
            case .launching, .restoring, .signingIn, .reconnecting:
                throw LiveSmokeError.unexpectedState("Login never reached a terminal state.")
            }

            let accountSummaries = await service.accountSummaries()
            guard let summary = accountSummaries.first else {
                throw LiveSmokeError.missingAccountSummary
            }

            if let expectedHomeserverHost = configuration.expectedHomeserverHost {
                let actualHost = summary.homeserver.host(percentEncoded: false)
                guard actualHost == expectedHomeserverHost else {
                    throw LiveSmokeError.homeserverMismatch(expected: expectedHomeserverHost, actual: actualHost)
                }
            }

            let roomListStream = await service.roomListStream(for: summary.accountID, spaceID: nil)
            let initialRooms = try await waitForFirstValue(from: roomListStream, timeout: .seconds(20))

            print("Connected as \(summary.userID)")
            print("Homeserver: \(summary.homeserver.absoluteString)")
            print("Initial room snapshot count: \(initialRooms.count)")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Live smoke failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func makePaths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixClientLiveSmoke", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appSupportURL = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        return AppPaths(
            applicationSupportURL: appSupportURL,
            databaseURL: appSupportURL.appendingPathComponent("MatrixClient.sqlite")
        )
    }

    private static func performLogin(
        on service: MatrixClientService,
        configuration: LiveSmokeConfiguration,
        timeout: Duration = .seconds(30)
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await service.login(
                    serverNameOrURL: configuration.serverName,
                    username: configuration.username,
                    password: configuration.password
                )
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw LiveSmokeError.timeout("Timed out waiting for the live Matrix login request to complete.")
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private static func waitForSessionResolution(
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
                    case .launching, .restoring, .signingIn, .reconnecting:
                        continue
                    }
                }
                throw LiveSmokeError.unexpectedState("The session-state stream ended before login completed.")
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw LiveSmokeError.timeout("Timed out waiting for the session-state stream to resolve.")
            }

            let state = try await group.next()!
            group.cancelAll()
            return state
        }
    }

    private static func waitForFirstValue<Value: Sendable>(
        from stream: AsyncStream<Value>,
        timeout: Duration
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                for await value in stream {
                    return value
                }
                throw LiveSmokeError.unexpectedState("The room-list stream ended before producing a value.")
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw LiveSmokeError.timeout("Timed out waiting for the room-list stream.")
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
