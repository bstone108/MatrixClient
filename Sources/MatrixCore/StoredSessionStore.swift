import Foundation
import Persistence
import Security

#if canImport(MatrixRustSDK)
@preconcurrency import MatrixRustSDK
#endif

struct PersistedAccountSession: Codable, Hashable, Sendable {
    let accountID: String
    let userID: String
    let homeserverURL: String
    let storeKey: String
}

private struct SessionManifest: Codable {
    var sessions: [PersistedAccountSession]
}

private struct SessionCredentialRecord: Codable {
    let accessToken: String
    let refreshToken: String?
    let userID: String
    let deviceID: String
    let homeserverURL: String
    let oidcData: String?
    let slidingSyncVersion: String
}

#if canImport(MatrixRustSDK)
final class StoredSessionStore: NSObject, ClientSessionDelegate, @unchecked Sendable {
    private let rootURL: URL
    private let manifestURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keychainService = "com.brandonstone.MatrixClient.session"

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.manifestURL = rootURL.appendingPathComponent("session-manifest.json")
        super.init()
    }

    func loadPersistedSessions() throws -> [PersistedAccountSession] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let data = try Data(contentsOf: manifestURL)
        return try decoder.decode(SessionManifest.self, from: data).sessions
    }

    func save(session: Session, storeKey: String) throws -> PersistedAccountSession {
        let record = PersistedAccountSession(
            accountID: session.userId,
            userID: session.userId,
            homeserverURL: session.homeserverUrl,
            storeKey: storeKey
        )
        try saveSessionInKeychainRecord(session)
        var records = try loadPersistedSessions()
        records.removeAll { $0.accountID == record.accountID }
        records.append(record)
        records.sort { $0.accountID < $1.accountID }
        try writeManifest(records)
        return record
    }

    func remove(accountID: String) throws {
        var records = try loadPersistedSessions()
        guard let record = records.first(where: { $0.accountID == accountID }) else { return }
        records.removeAll { $0.accountID == accountID }
        try writeManifest(records)

        let query = keychainQuery(account: record.userID)
        SecItemDelete(query as CFDictionary)

        let accountRoot = rootURL
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(record.storeKey, isDirectory: true)
        try? FileManager.default.removeItem(at: accountRoot)
    }

    func restoreSession(for record: PersistedAccountSession) throws -> Session {
        try loadSessionFromKeychain(userID: record.userID)
    }

    func accountStorePaths(for storeKey: String) throws -> (dataPath: String, cachePath: String) {
        let accountRoot = rootURL
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(storeKey, isDirectory: true)
        let dataURL = accountRoot.appendingPathComponent("sdk-data", isDirectory: true)
        let cacheURL = accountRoot.appendingPathComponent("sdk-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        return (dataURL.path, cacheURL.path)
    }

    func storeKey(serverNameOrURL: String, username: String) -> String {
        let normalized = "\(serverNameOrURL.lowercased())|\(username.lowercased())"
        let safe = normalized
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .map { character -> Character in
                if character.isLetter || character.isNumber {
                    return character
                }
                return "-"
            }
        return String(safe.prefix(64))
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        try loadSessionFromKeychain(userID: userId)
    }

    func saveSessionInKeychain(session: Session) {
        try? saveSessionInKeychainRecord(session)
    }

    private func loadSessionFromKeychain(userID: String) throws -> Session {
        var query = keychainQuery(account: userID)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw SessionStoreError.keychainLookupFailed(status: status)
        }

        let credentials = try decoder.decode(SessionCredentialRecord.self, from: data)
        return Session(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            userId: credentials.userID,
            deviceId: credentials.deviceID,
            homeserverUrl: credentials.homeserverURL,
            oauthData: credentials.oidcData,
            slidingSyncVersion: slidingSyncVersion(from: credentials.slidingSyncVersion)
        )
    }

    private func saveSessionInKeychainRecord(_ session: Session) throws {
        let payload = SessionCredentialRecord(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userID: session.userId,
            deviceID: session.deviceId,
            homeserverURL: session.homeserverUrl,
            oidcData: session.oauthData,
            slidingSyncVersion: stringValue(for: session.slidingSyncVersion)
        )
        let data = try encoder.encode(payload)

        let query = keychainQuery(account: session.userId)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw SessionStoreError.keychainUpdateFailed(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SessionStoreError.keychainInsertFailed(status: addStatus)
        }
    }

    private func writeManifest(_ records: [PersistedAccountSession]) throws {
        let data = try encoder.encode(SessionManifest(sessions: records))
        try data.write(to: manifestURL, options: .atomic)
    }

    private func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }

    private func stringValue(for version: SlidingSyncVersion) -> String {
        switch version {
        case .none:
            return "none"
        case .native:
            return "native"
        }
    }

    private func slidingSyncVersion(from rawValue: String) -> SlidingSyncVersion {
        switch rawValue {
        case "native":
            return .native
        default:
            return .none
        }
    }
}

enum SessionStoreError: LocalizedError {
    case keychainLookupFailed(status: OSStatus)
    case keychainUpdateFailed(status: OSStatus)
    case keychainInsertFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychainLookupFailed(status):
            return "Unable to load the saved Matrix session from Keychain (\(status))."
        case let .keychainUpdateFailed(status):
            return "Unable to update the Matrix session in Keychain (\(status))."
        case let .keychainInsertFailed(status):
            return "Unable to save the Matrix session in Keychain (\(status))."
        }
    }
}
#else
final class StoredSessionStore {
    init(rootURL: URL) {}
}
#endif
