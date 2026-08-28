import AppKit
import Diagnostics
import Foundation
import MatrixCore

@MainActor
final class GitHubReleaseUpdater {
    enum Status: Equatable {
        case idle
        case checking
        case downloading(String)
        case ready(String)
        case failed(String)

        var toolbarTitle: String? {
            switch self {
            case .idle, .checking:
                return nil
            case let .downloading(version):
                return "Downloading \(version)…"
            case .ready:
                return "Update ready — relaunch"
            case .failed:
                return "Update failed"
            }
        }

        var toolbarTooltip: String {
            switch self {
            case .idle:
                return "No update available"
            case .checking:
                return "Checking for updates"
            case let .downloading(version):
                return "Downloading Matrix Client \(version)"
            case let .ready(version):
                return "Relaunch to install Matrix Client \(version)"
            case let .failed(message):
                return message
            }
        }
    }

    private enum DefaultsKey {
        static let lastCheckAt = "Updater.lastCheckAt"
        static let applyOnNextLaunch = "Updater.applyOnNextLaunch"
        static let stagedVersion = "Updater.stagedVersion"
        static let lastPromptedVersion = "Updater.lastPromptedVersion"
    }

    private static let checkInterval: TimeInterval = 60 * 60 * 48

    private let diagnostics: DiagnosticsService
    private let applicationSupportURL: URL
    private let defaults: UserDefaults
    private let session: URLSession
    private let fileManager: FileManager
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var started = false
    private var checkTask: Task<Void, Never>?
    private var isPresentingRestartPrompt = false

    private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            notifyObservers()
            if case .ready = status {
                presentRestartPromptIfNeeded()
            }
        }
    }

    init(
        diagnostics: DiagnosticsService,
        applicationSupportURL: URL,
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.diagnostics = diagnostics
        self.applicationSupportURL = applicationSupportURL
        self.defaults = defaults
        self.session = session
        self.fileManager = fileManager
    }

    func addObserver(_ observer: @escaping @MainActor () -> Void) {
        observers[UUID()] = observer
    }

    func start() {
        guard !started else { return }
        started = true

        if stagedApplicationURL() != nil, defaults.bool(forKey: DefaultsKey.applyOnNextLaunch) {
            applyStagedUpdateAndRelaunch()
            return
        }

        if let stagedVersion = stagedVersionLabel() {
            status = .ready(stagedVersion)
        }

        if shouldCheckAutomatically() {
            checkForUpdates(force: false)
        }
    }

    func checkForUpdates(force: Bool) {
        if !force, !shouldCheckAutomatically(), stagedApplicationURL() == nil {
            return
        }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            await self?.performCheck(force: force)
        }
    }

    func relaunchIfReady() {
        applyStagedUpdateAndRelaunch()
    }

    /// Show Restart now / Later once per staged version. Toolbar refresh and
    /// later 48h checks that land on the same `.ready(version)` must not nag.
    private func presentRestartPromptIfNeeded() {
        guard case let .ready(version) = status else { return }
        guard defaults.string(forKey: DefaultsKey.lastPromptedVersion) != version else { return }
        guard !isPresentingRestartPrompt else { return }
        isPresentingRestartPrompt = true
        Task { [weak self] in
            self?.showRestartPrompt(for: version)
        }
    }

    private func showRestartPrompt(for version: String) {
        guard case let .ready(current) = status, current == version else {
            isPresentingRestartPrompt = false
            return
        }
        guard defaults.string(forKey: DefaultsKey.lastPromptedVersion) != version else {
            isPresentingRestartPrompt = false
            return
        }

        defaults.set(version, forKey: DefaultsKey.lastPromptedVersion)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update Ready"
        alert.informativeText = "Matrix Client \(version) is ready to install."
        alert.addButton(withTitle: "Restart now")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        isPresentingRestartPrompt = false
        if response == .alertFirstButtonReturn {
            relaunchIfReady()
        }
    }

    private func shouldCheckAutomatically() -> Bool {
        guard let lastCheck = defaults.object(forKey: DefaultsKey.lastCheckAt) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastCheck) >= Self.checkInterval
    }

    private func performCheck(force: Bool) async {
        if Task.isCancelled { return }
        status = .checking
        defaults.set(Date(), forKey: DefaultsKey.lastCheckAt)

        do {
            var request = URLRequest(url: GitHubReleaseFeed.releasesURL)
            request.setValue("MatrixClient", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UpdateError.httpStatus(http.statusCode)
            }

            let releases = try GitHubReleaseFeed.parseReleases(from: data)
            let current = Self.runningVersion()
            let architecture = Self.currentArchitecture()
            guard let (release, asset) = GitHubReleaseFeed.newestRelease(
                in: releases,
                newerThan: current,
                architecture: architecture
            ) else {
                if let stagedVersion = stagedVersionLabel(), stagedApplicationURL() != nil {
                    status = .ready(stagedVersion)
                } else {
                    status = .idle
                }
                await diagnostics.record(.info, category: "Updater", message: "No newer GitHub release", metadata: [
                    "current": current?.rawValue ?? "unversioned",
                    "architecture": architecture,
                    "forced": force ? "true" : "false"
                ])
                return
            }

            if let staged = stagedVersionLabel(),
               let stagedVersion = DateBuildVersion.parse(staged),
               stagedVersion >= release.version,
               stagedApplicationURL() != nil {
                status = .ready(staged)
                return
            }

            status = .downloading(release.version.rawValue)
            try await downloadAndStage(release: release, asset: asset)
            defaults.set(true, forKey: DefaultsKey.applyOnNextLaunch)
            defaults.set(release.version.rawValue, forKey: DefaultsKey.stagedVersion)
            status = .ready(release.version.rawValue)
            await diagnostics.record(.info, category: "Updater", message: "Staged GitHub release update", metadata: [
                "version": release.version.rawValue
            ])
        } catch is CancellationError {
            return
        } catch {
            let message = "Couldn’t check for updates"
            status = .failed(message)
            await diagnostics.record(.error, category: "Updater", message: "Update check failed", metadata: [
                "error": error.localizedDescription
            ])
        }
    }

    private func downloadAndStage(release: GitHubReleaseSummary, asset: GitHubReleaseAsset) async throws {
        let updatesDirectory = try updatesDirectoryURL()
        let downloadURL = updatesDirectory.appendingPathComponent("MatrixClient-download.dmg")
        if fileManager.fileExists(atPath: downloadURL.path) {
            try fileManager.removeItem(at: downloadURL)
        }

        let (tempURL, response) = try await session.download(from: asset.downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        try fileManager.moveItem(at: tempURL, to: downloadURL)
        guard isDiskImage(downloadURL) else {
            try? fileManager.removeItem(at: downloadURL)
            throw UpdateError.invalidDiskImage
        }

        let stagedApp = try extractAndVerifyApplication(from: downloadURL, version: release.version)
        defaults.set(release.version.rawValue, forKey: DefaultsKey.stagedVersion)
        _ = stagedApp
        try? fileManager.removeItem(at: downloadURL)
    }

    private func extractAndVerifyApplication(from dmgURL: URL, version: DateBuildVersion) throws -> URL {
        #if os(macOS)
        let mountPoint = fileManager.temporaryDirectory.appendingPathComponent("MatrixClient-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"])
            try? fileManager.removeItem(at: mountPoint)
        }

        let attach = run("/usr/bin/hdiutil", [
            "attach", dmgURL.path,
            "-nobrowse",
            "-readonly",
            "-mountpoint", mountPoint.path
        ])
        guard attach.exitCode == 0 else {
            throw UpdateError.invalidDiskImage
        }

        guard let appURL = try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.missingApplication
        }

        try verifyDeveloperID(at: appURL)

        let stagedURL = try updatesDirectoryURL().appendingPathComponent("MatrixClient.app", isDirectory: true)
        if fileManager.fileExists(atPath: stagedURL.path) {
            try fileManager.removeItem(at: stagedURL)
        }
        try fileManager.copyItem(at: appURL, to: stagedURL)
        try version.rawValue.write(
            to: stagedURL.deletingLastPathComponent().appendingPathComponent("STAGED_VERSION.txt"),
            atomically: true,
            encoding: .utf8
        )
        return stagedURL
        #else
        throw UpdateError.unsupportedPlatform
        #endif
    }

    private func verifyDeveloperID(at appURL: URL) throws {
        #if os(macOS)
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        guard verify.exitCode == 0 else {
            throw UpdateError.codesignFailed
        }
        let details = run("/usr/bin/codesign", ["-dv", "--verbose=2", appURL.path])
        let output = details.standardError + details.standardOutput
        guard output.contains("Developer ID Application") else {
            throw UpdateError.codesignFailed
        }
        _ = run("/usr/sbin/spctl", ["--assess", "--type", "execute", appURL.path])
        #endif
    }

    private func applyStagedUpdateAndRelaunch() {
        guard let staged = stagedApplicationURL() else {
            status = .failed("No update is staged")
            return
        }
        let destination = Bundle.main.bundleURL
        do {
            let scriptURL = try writeRelaunchScript()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                scriptURL.path,
                String(ProcessInfo.processInfo.processIdentifier),
                staged.path,
                destination.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defaults.set(false, forKey: DefaultsKey.applyOnNextLaunch)
            Task { [diagnostics] in
                await diagnostics.record(.info, category: "Updater", message: "Relaunching into staged update")
            }
            NSApp.terminate(nil)
        } catch {
            status = .failed("Couldn’t relaunch into the update")
            Task { [diagnostics] in
                await diagnostics.record(.error, category: "Updater", message: "Failed to relaunch staged update", metadata: [
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func writeRelaunchScript() throws -> URL {
        let scriptURL = try updatesDirectoryURL().appendingPathComponent("relaunch.sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        OLD_PID="$1"
        STAGED="$2"
        DEST="$3"
        BACKUP="${DEST}.updating"
        for _ in $(seq 1 50); do
          if ! kill -0 "$OLD_PID" 2>/dev/null; then
            break
          fi
          sleep 0.2
        done
        sleep 0.4
        rm -rf "$BACKUP"
        if [ -d "$DEST" ]; then
          mv "$DEST" "$BACKUP"
        fi
        if ! /usr/bin/ditto "$STAGED" "$DEST"; then
          if [ -d "$BACKUP" ]; then
            mv "$BACKUP" "$DEST"
          fi
          exit 1
        fi
        rm -rf "$BACKUP"
        /usr/bin/open "$DEST"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func stagedApplicationURL() -> URL? {
        let url = applicationSupportURL
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent("MatrixClient.app", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private func stagedVersionLabel() -> String? {
        if let stored = defaults.string(forKey: DefaultsKey.stagedVersion), DateBuildVersion.parse(stored) != nil {
            return stored
        }
        let marker = applicationSupportURL
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent("STAGED_VERSION.txt")
        return try? String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updatesDirectoryURL() throws -> URL {
        let url = applicationSupportURL.appendingPathComponent("Updates", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private func isDiskImage(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dmg" else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return size > 100_000
    }

    private func notifyObservers() {
        observers.values.forEach { $0() }
    }

    static func runningVersion(bundle: Bundle = .main) -> DateBuildVersion? {
        let candidates = [
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ]
        return candidates.compactMap { value in value.flatMap(DateBuildVersion.parse) }.first
    }

    static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) -> (exitCode: Int32, standardOutput: String, standardError: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output, err)
    }

    private enum UpdateError: LocalizedError {
        case httpStatus(Int)
        case invalidDiskImage
        case missingApplication
        case codesignFailed
        case unsupportedPlatform

        var errorDescription: String? {
            switch self {
            case .httpStatus:
                return "GitHub releases are unavailable."
            case .invalidDiskImage:
                return "The downloaded update was not a valid disk image."
            case .missingApplication:
                return "The update disk image did not contain MatrixClient.app."
            case .codesignFailed:
                return "The update did not pass Developer ID verification."
            case .unsupportedPlatform:
                return "Updates can only be installed on macOS."
            }
        }
    }
}
