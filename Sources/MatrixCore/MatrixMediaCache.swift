import Diagnostics
import Foundation

#if canImport(MatrixRustSDK)
@preconcurrency import MatrixRustSDK

public actor MatrixMediaCache {
    private enum CacheVariant: String {
        case original
        case thumbnail
    }

    private struct DownloadKey: Hashable {
        let itemID: String
        let variant: CacheVariant
    }

    private struct PendingDownload {
        let key: DownloadKey
        let item: TimelineItem
    }

    private struct RunningDownload {
        let roomID: RoomIdentifier
        let lane: MediaDownloadLane
    }

    private let client: Client
    private let diagnostics: DiagnosticsService
    private let cacheRootURL: URL
    private let fileManager: FileManager

    private var statesByRoom: [RoomIdentifier: [String: TimelineMediaLoadState]] = [:]
    private var broadcasters: [RoomIdentifier: AsyncBroadcaster<[String: TimelineMediaLoadState]>] = [:]
    private let workerBroadcaster = AsyncBroadcaster<[MediaDownloadWorkerSnapshot]>(initialValue: [])
    private var originalTasks: [String: Task<URL?, Never>] = [:]
    private var thumbnailTasks: [String: Task<URL?, Never>] = [:]
    private var activeRoomID: RoomIdentifier?
    private var pendingDownloads: [DownloadKey: PendingDownload] = [:]
    private var pendingOrder: [DownloadKey] = []
    private var pendingContinuations: [DownloadKey: CheckedContinuation<Void, Error>] = [:]
    private var runningDownloads: [DownloadKey: RunningDownload] = [:]

    public init(
        client: Client,
        diagnostics: DiagnosticsService,
        cacheRootURL: URL,
        fileManager: FileManager = .default
    ) {
        self.client = client
        self.diagnostics = diagnostics
        self.cacheRootURL = cacheRootURL
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: cacheRootURL, withIntermediateDirectories: true)
    }

    public func stream(for roomID: RoomIdentifier) -> AsyncStream<[String: TimelineMediaLoadState]> {
        if broadcasters[roomID] == nil {
            broadcasters[roomID] = AsyncBroadcaster(initialValue: statesByRoom[roomID, default: [:]])
        }
        return broadcasters[roomID]!.stream()
    }

    public func workerStateStream() -> AsyncStream<[MediaDownloadWorkerSnapshot]> {
        workerBroadcaster.stream()
    }

    public func setActiveRoom(_ roomID: RoomIdentifier?) {
        activeRoomID = roomID
        schedulePendingDownloads()
    }

    public func prepareMedia(for item: TimelineItem, prefetchOriginal: Bool) {
        guard let media = item.media else { return }

        switch media.kind {
        case .image, .video:
            ensureThumbnailTask(for: item)
            if prefetchOriginal {
                let thumbnailTask = thumbnailTasks[item.id]
                Task { [weak self] in
                    _ = await thumbnailTask?.value
                    guard let self else { return }
                    _ = await self.ensureOriginalTask(for: item).value
                }
            }
        case .audio, .file:
            if prefetchOriginal {
                _ = ensureOriginalTask(for: item)
            }
        }
    }

    public func ensureOriginalAvailable(for item: TimelineItem) async -> URL? {
        guard item.media != nil else { return nil }
        return await ensureOriginalTask(for: item).value
    }

    public func prune(roomID: RoomIdentifier, keepingItems: [TimelineItem]) {
        let keepingItemIDs = Set(keepingItems.compactMap { $0.media == nil ? nil : $0.id })
        let keepBaseKeys = Set(keepingItems.flatMap { item in
            cacheBaseKeys(for: item)
        })
        let roomDirectory = roomCacheDirectory(for: roomID)

        if let existing = statesByRoom[roomID] {
            for itemID in existing.keys where !keepingItemIDs.contains(itemID) {
                originalTasks[itemID]?.cancel()
                thumbnailTasks[itemID]?.cancel()
                originalTasks[itemID] = nil
                thumbnailTasks[itemID] = nil
            }
        }

        statesByRoom[roomID] = statesByRoom[roomID, default: [:]].filter { keepingItemIDs.contains($0.key) }
        publish(roomID: roomID)

        guard let enumerator = fileManager.enumerator(at: roomDirectory, includingPropertiesForKeys: nil) else { return }
        for case let fileURL as URL in enumerator {
            let name = fileURL.deletingPathExtension().lastPathComponent
            let key = Self.cacheBaseKey(fromCachedFileName: name)
            if !keepBaseKeys.contains(key) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func ensureThumbnailTask(for item: TimelineItem) {
        guard let media = item.media else { return }
        guard thumbnailTasks[item.id] == nil else { return }
        guard media.kind == .image || media.kind == .video else { return }

        if let cachedURL = existingCachedFileURL(for: item, variant: .thumbnail) {
            updateState(for: item) { state in
                TimelineMediaLoadState(
                    thumbnailFileURL: cachedURL,
                    originalFileURL: state.originalFileURL,
                    isLoadingThumbnail: false,
                    isLoadingOriginal: state.isLoadingOriginal,
                    receivedBytes: state.receivedBytes,
                    totalBytes: state.totalBytes,
                    errorDescription: state.errorDescription
                )
            }
            return
        }

        updateState(for: item) { state in
            TimelineMediaLoadState(
                thumbnailFileURL: state.thumbnailFileURL,
                originalFileURL: state.originalFileURL,
                isLoadingThumbnail: true,
                isLoadingOriginal: state.isLoadingOriginal,
                receivedBytes: state.receivedBytes,
                totalBytes: state.totalBytes,
                errorDescription: nil
            )
        }

        let task = Task<URL?, Never> {
            do {
                try await self.awaitDownloadTurn(for: item, variant: .thumbnail)
                let url = try await self.fetchThumbnailFile(for: item)
                self.finishThumbnail(itemID: item.id, roomID: item.roomID, url: url)
                return url
            } catch is CancellationError {
                self.cancelThumbnail(itemID: item.id, roomID: item.roomID)
                return nil
            } catch {
                await self.failThumbnail(itemID: item.id, roomID: item.roomID, error: error)
                return nil
            }
        }
        thumbnailTasks[item.id] = task
    }

    private func ensureOriginalTask(for item: TimelineItem) -> Task<URL?, Never> {
        if let existingTask = originalTasks[item.id] {
            return existingTask
        }

        if let cachedURL = existingCachedFileURL(for: item, variant: .original) {
            updateState(for: item) { state in
                TimelineMediaLoadState(
                    thumbnailFileURL: state.thumbnailFileURL,
                    originalFileURL: cachedURL,
                    isLoadingThumbnail: state.isLoadingThumbnail,
                    isLoadingOriginal: false,
                    receivedBytes: state.receivedBytes,
                    totalBytes: state.totalBytes,
                    errorDescription: state.errorDescription
                )
            }
            return Task { cachedURL }
        }

        updateState(for: item) { state in
            TimelineMediaLoadState(
                thumbnailFileURL: state.thumbnailFileURL,
                originalFileURL: state.originalFileURL,
                isLoadingThumbnail: state.isLoadingThumbnail,
                isLoadingOriginal: true,
                receivedBytes: 0,
                totalBytes: nil,
                errorDescription: nil
            )
        }

        let task = Task<URL?, Never> {
            do {
                try await self.awaitDownloadTurn(for: item, variant: .original)
                let url = try await self.fetchOriginalFile(for: item)
                self.finishOriginal(item: item, url: url)
                return url
            } catch is CancellationError {
                self.cancelOriginal(itemID: item.id, roomID: item.roomID)
                return nil
            } catch {
                await self.failOriginal(itemID: item.id, roomID: item.roomID, error: error)
                return nil
            }
        }
        originalTasks[item.id] = task
        return task
    }

    private func fetchThumbnailFile(for item: TimelineItem) async throws -> URL? {
        guard let media = item.media else { return nil }
        let destinationURL = cacheURL(for: item, variant: .thumbnail, preferredExtension: preferredThumbnailExtension(for: media))

        if let thumbnailSource = media.thumbnailSourceJSON.flatMap(Self.mediaSource(from:)) {
            let data = try await client.getMediaThumbnail(mediaSource: thumbnailSource, width: 720, height: 720)
            try data.write(to: destinationURL, options: .atomic)
            return destinationURL
        }

        let source = try mediaSource(for: media)
        let data = try await client.getMediaThumbnail(mediaSource: source, width: 720, height: 720)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    private func fetchOriginalFile(for item: TimelineItem) async throws -> URL {
        guard let media = item.media else {
            throw MediaCacheError.invalidMedia
        }

        let destinationURL = cacheURL(for: item, variant: .original, preferredExtension: preferredOriginalExtension(for: media))

        if let directURL = try await directDownloadIfPossible(for: item, destinationURL: destinationURL) {
            return directURL
        }

        let source = try mediaSource(for: media)
        let handle = try await client.getMediaFile(
            mediaSource: source,
            body: media.filename ?? media.body,
            mimeType: media.mimeType ?? "application/octet-stream",
            useCache: true,
            tempDir: roomCacheDirectory(for: item.roomID).path
        )
        _ = try handle.persist(path: destinationURL.path)
        return destinationURL
    }

    private func directDownloadIfPossible(for item: TimelineItem, destinationURL: URL) async throws -> URL? {
        guard let media = item.media, media.allowsDirectDownload else { return nil }
        guard let remote = Self.parseMXCURL(media.sourceURL) else { return nil }

        let session = try client.session()
        guard let homeserverURL = Self.sanitizedHomeserverBaseURL(from: client.homeserver()) else { return nil }
        let candidateURLs = Self.mediaCandidateURLs(serverName: remote.serverName, mediaID: remote.mediaID, homeserverURL: homeserverURL)

        for candidateURL in candidateURLs {
            var request = URLRequest(url: candidateURL)
            request.httpMethod = "GET"
            request.setValue("MatrixClient/0.1", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            do {
                let downloader = RemoteMediaDownloader()
                let (downloadedURL, response) = try await downloader.download(
                    request: request,
                    destinationURL: destinationURL,
                    progress: { [itemID = item.id, roomID = item.roomID] receivedBytes, totalBytes in
                        await self.updateTransferProgress(
                            itemID: itemID,
                            roomID: roomID,
                            receivedBytes: receivedBytes,
                            totalBytes: totalBytes
                        )
                    }
                )
                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }

                let fileSize = (try? fileManager.attributesOfItem(atPath: downloadedURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                if (200..<300).contains(httpResponse.statusCode), fileSize > 0 {
                    return downloadedURL
                }

                try? fileManager.removeItem(at: downloadedURL)
            } catch {
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        return nil
    }

    private func mediaSource(for media: TimelineMediaAttachment) throws -> MediaSource {
        if let source = Self.mediaSource(from: media.sourceJSON) {
            return source
        }
        if !media.sourceURL.isEmpty {
            return mediaSourceFromUrl(url: media.sourceURL)
        }
        throw MediaCacheError.invalidMedia
    }

    private func updateTransferProgress(itemID: String, roomID: RoomIdentifier, receivedBytes: Int64, totalBytes: Int64?) {
        updateState(itemID: itemID, roomID: roomID) { state in
            TimelineMediaLoadState(
                thumbnailFileURL: state.thumbnailFileURL,
                originalFileURL: state.originalFileURL,
                isLoadingThumbnail: state.isLoadingThumbnail,
                isLoadingOriginal: state.isLoadingOriginal,
                receivedBytes: receivedBytes,
                totalBytes: totalBytes,
                errorDescription: state.errorDescription
            )
        }
    }

    private func cancelThumbnail(itemID: String, roomID: RoomIdentifier) {
        thumbnailTasks[itemID] = nil
        finishScheduledDownload(itemID: itemID, variant: .thumbnail)
        guard statesByRoom[roomID]?[itemID] != nil else { return }
        updateState(itemID: itemID, roomID: roomID) { state in
            TimelineMediaLoadState(
                thumbnailFileURL: state.thumbnailFileURL,
                originalFileURL: state.originalFileURL,
                isLoadingThumbnail: false,
                isLoadingOriginal: state.isLoadingOriginal,
                receivedBytes: state.receivedBytes,
                totalBytes: state.totalBytes,
                errorDescription: state.errorDescription
            )
        }
    }

    private func cancelOriginal(itemID: String, roomID: RoomIdentifier) {
        originalTasks[itemID] = nil
        finishScheduledDownload(itemID: itemID, variant: .original)
        guard statesByRoom[roomID]?[itemID] != nil else { return }
        updateState(itemID: itemID, roomID: roomID) { state in
            TimelineMediaLoadState(
                thumbnailFileURL: state.thumbnailFileURL,
                originalFileURL: state.originalFileURL,
                isLoadingThumbnail: state.isLoadingThumbnail,
                isLoadingOriginal: false,
                receivedBytes: state.receivedBytes,
                totalBytes: state.totalBytes,
                errorDescription: state.errorDescription
            )
        }
    }

    private func finishThumbnail(itemID: String, roomID: RoomIdentifier, url: URL?) {
        thumbnailTasks[itemID] = nil
        finishScheduledDownload(itemID: itemID, variant: .thumbnail)
        updateState(itemID: itemID, roomID: roomID) { state in
            TimelineMediaLoadState(
                thumbnailFileURL: url ?? state.thumbnailFileURL,
                originalFileURL: state.originalFileURL,
                isLoadingThumbnail: false,
                isLoadingOriginal: state.isLoadingOriginal,
                receivedBytes: state.receivedBytes,
                totalBytes: state.totalBytes,
                errorDescription: state.errorDescription
            )
        }
    }

    private func finishOriginal(item: TimelineItem, url: URL?) {
        originalTasks[item.id] = nil
        finishScheduledDownload(itemID: item.id, variant: .original)
        updateState(itemID: item.id, roomID: item.roomID) { state in
            TimelineMediaLoadState(
                thumbnailFileURL: state.thumbnailFileURL ?? ((item.media?.kind == .image && url?.pathExtension.isEmpty == false) ? url : nil),
                originalFileURL: url ?? state.originalFileURL,
                isLoadingThumbnail: state.isLoadingThumbnail,
                isLoadingOriginal: false,
                receivedBytes: state.totalBytes ?? state.receivedBytes,
                totalBytes: state.totalBytes ?? state.receivedBytes,
                errorDescription: state.errorDescription
            )
        }
    }

    private func failThumbnail(itemID: String, roomID: RoomIdentifier, error: Error) async {
        thumbnailTasks[itemID] = nil
        finishScheduledDownload(itemID: itemID, variant: .thumbnail)
        await diagnostics.record(.error, category: "Media", message: "Failed to fetch media thumbnail", metadata: [
            "itemID": itemID,
            "error": error.localizedDescription
        ])
        updateState(itemID: itemID, roomID: roomID) { state in
            TimelineMediaLoadState(
                thumbnailFileURL: state.thumbnailFileURL,
                originalFileURL: state.originalFileURL,
                isLoadingThumbnail: false,
                isLoadingOriginal: state.isLoadingOriginal,
                receivedBytes: state.receivedBytes,
                totalBytes: state.totalBytes,
                errorDescription: state.errorDescription
            )
        }
    }

    private func failOriginal(itemID: String, roomID: RoomIdentifier, error: Error) async {
        originalTasks[itemID] = nil
        finishScheduledDownload(itemID: itemID, variant: .original)
        await diagnostics.record(.error, category: "Media", message: "Failed to fetch original media", metadata: [
            "itemID": itemID,
            "error": error.localizedDescription
        ])
        updateState(itemID: itemID, roomID: roomID) { state in
            TimelineMediaLoadState(
                thumbnailFileURL: state.thumbnailFileURL,
                originalFileURL: state.originalFileURL,
                isLoadingThumbnail: state.isLoadingThumbnail,
                isLoadingOriginal: false,
                receivedBytes: state.receivedBytes,
                totalBytes: state.totalBytes,
                errorDescription: error.localizedDescription
            )
        }
    }

    private func updateState(for item: TimelineItem, _ update: (TimelineMediaLoadState) -> TimelineMediaLoadState) {
        updateState(itemID: item.id, roomID: item.roomID, update)
    }

    private func updateState(itemID: String, roomID: RoomIdentifier, _ update: (TimelineMediaLoadState) -> TimelineMediaLoadState) {
        var roomStates = statesByRoom[roomID, default: [:]]
        let current = roomStates[itemID] ?? TimelineMediaLoadState()
        roomStates[itemID] = update(current)
        statesByRoom[roomID] = roomStates
        publish(roomID: roomID)
    }

    private func publish(roomID: RoomIdentifier) {
        if broadcasters[roomID] == nil {
            broadcasters[roomID] = AsyncBroadcaster(initialValue: statesByRoom[roomID, default: [:]])
        } else {
            broadcasters[roomID]?.yield(statesByRoom[roomID, default: [:]])
        }
    }

    private func existingCachedFileURL(for item: TimelineItem, variant: CacheVariant) -> URL? {
        guard let media = item.media else { return nil }
        let url = cacheURL(
            for: item,
            variant: variant,
            preferredExtension: variant == .original ? preferredOriginalExtension(for: media) : preferredThumbnailExtension(for: media)
        )
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func cacheURL(for item: TimelineItem, variant: CacheVariant, preferredExtension: String?) -> URL {
        let ext = preferredExtension?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let fileName = cacheBaseKey(for: item, variant: variant) + "--" + variant.rawValue + (ext.map { ".\($0)" } ?? "")
        return roomCacheDirectory(for: item.roomID).appendingPathComponent(fileName, isDirectory: false)
    }

    private func roomCacheDirectory(for roomID: RoomIdentifier) -> URL {
        let url = cacheRootURL.appendingPathComponent(Self.sanitizedKey(for: roomID.rawValue), isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private static func mediaSource(from json: String) -> MediaSource? {
        try? MediaSource.fromJson(json: json)
    }

    private static func parseMXCURL(_ value: String) -> (serverName: String, mediaID: String)? {
        guard value.hasPrefix("mxc://") else { return nil }
        let remainder = String(value.dropFirst("mxc://".count))
        guard let slash = remainder.firstIndex(of: "/") else { return nil }
        let serverName = String(remainder[..<slash])
        let mediaID = String(remainder[remainder.index(after: slash)...])
        guard !serverName.isEmpty, !mediaID.isEmpty else { return nil }
        return (serverName, mediaID)
    }

    static func mediaCandidateURLs(serverName: String, mediaID: String, homeserverURL: URL) -> [URL] {
        let encodedServer = serverName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serverName
        let encodedMediaID = mediaID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mediaID
        let pathVariants = [
            "/_matrix/client/v1/media/download/\(encodedServer)/\(encodedMediaID)",
            "/_matrix/media/v3/download/\(encodedServer)/\(encodedMediaID)",
            "/_matrix/media/r0/download/\(encodedServer)/\(encodedMediaID)",
        ]

        var urls: [URL] = []
        for path in pathVariants {
            if let url = URL(string: path, relativeTo: homeserverURL)?.absoluteURL {
                urls.append(url)
            }
        }

        return urls
    }

    static func sanitizedHomeserverBaseURL(from rawValue: String) -> URL? {
        guard let url = URL(string: rawValue),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host else {
            return nil
        }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil

        return components.url
    }

    private static func sanitizedKey(for rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let unicodeScalars = rawValue.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(unicodeScalars)
    }

    private func cacheBaseKeys(for item: TimelineItem) -> [String] {
        guard item.media != nil else { return [] }
        return Array(Set([
            cacheBaseKey(for: item, variant: .original),
            cacheBaseKey(for: item, variant: .thumbnail)
        ]))
    }

    private func cacheBaseKey(for item: TimelineItem, variant: CacheVariant) -> String {
        guard let media = item.media else {
            return Self.sanitizedKey(for: item.id)
        }

        let rawKey: String?
        switch variant {
        case .original:
            rawKey = Self.firstNonEmpty(media.sourceURL, media.sourceJSON)
        case .thumbnail:
            rawKey = Self.firstNonEmpty(
                media.thumbnailSourceURL,
                media.thumbnailSourceJSON,
                media.sourceURL,
                media.sourceJSON
            )
        }

        return Self.sanitizedKey(for: rawKey ?? item.id)
    }

    private static func cacheBaseKey(fromCachedFileName fileName: String) -> String {
        let originalSuffix = "--" + CacheVariant.original.rawValue
        if fileName.hasSuffix(originalSuffix) {
            return String(fileName.dropLast(originalSuffix.count))
        }

        let thumbnailSuffix = "--" + CacheVariant.thumbnail.rawValue
        if fileName.hasSuffix(thumbnailSuffix) {
            return String(fileName.dropLast(thumbnailSuffix.count))
        }

        return fileName
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        .first
    }

    private func preferredOriginalExtension(for media: TimelineMediaAttachment) -> String? {
        if let filename = media.filename, let fileExtension = filename.split(separator: ".").last, filename.contains(".") {
            return String(fileExtension)
        }
        return Self.fileExtension(forMimeType: media.mimeType)
    }

    private func preferredThumbnailExtension(for media: TimelineMediaAttachment) -> String? {
        Self.fileExtension(forMimeType: media.thumbnailMimeType) ?? Self.fileExtension(forMimeType: media.mimeType) ?? "jpg"
    }

    private func awaitDownloadTurn(for item: TimelineItem, variant: CacheVariant) async throws {
        let key = DownloadKey(itemID: item.id, variant: variant)
        if startDownloadIfPossible(for: item, key: key) != nil {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                pendingDownloads[key] = PendingDownload(key: key, item: item)
                if !pendingOrder.contains(key) {
                    pendingOrder.append(key)
                }
                pendingContinuations[key] = continuation
                schedulePendingDownloads()
            }
        } onCancel: {
            Task {
                await self.cancelPendingDownload(for: key)
            }
        }
    }

    private func startDownloadIfPossible(for item: TimelineItem, key: DownloadKey) -> MediaDownloadLane? {
        let variant = key.variant
        guard let lane = MediaDownloadSchedulingPolicy.immediateLane(
            for: item.roomID.rawValue,
            activeRoomID: activeRoomID?.rawValue,
            pendingRoomIDs: orderedPendingRoomIDs(for: variant),
            runningRoomIDs: runningRoomIDs(for: variant),
            policy: workerPolicy(for: variant)
        ) else {
            return nil
        }

        runningDownloads[key] = RunningDownload(roomID: item.roomID, lane: lane)
        return lane
    }

    private func schedulePendingDownloads() {
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            if schedulePendingDownloads(for: .thumbnail) {
                madeProgress = true
            }
            if schedulePendingDownloads(for: .original) {
                madeProgress = true
            }
        }
        publishWorkerSnapshots()
    }

    private func schedulePendingDownloads(for variant: CacheVariant) -> Bool {
        let orderedKeys = orderedPendingKeys(for: variant)
        let pendingRoomIDs = orderedKeys.compactMap { pendingDownloads[$0]?.item.roomID.rawValue }
        guard let decision = MediaDownloadSchedulingPolicy.nextPendingDecision(
            activeRoomID: activeRoomID?.rawValue,
            pendingRoomIDs: pendingRoomIDs,
            runningRoomIDs: runningRoomIDs(for: variant),
            policy: workerPolicy(for: variant)
        ), decision.pendingIndex < orderedKeys.count else {
            return false
        }

        startPendingDownload(for: orderedKeys[decision.pendingIndex], lane: decision.lane)
        return true
    }

    private func startPendingDownload(for key: DownloadKey, lane: MediaDownloadLane) {
        guard let pending = pendingDownloads[key] else { return }
        guard let continuation = pendingContinuations.removeValue(forKey: key) else { return }
        pendingDownloads.removeValue(forKey: key)
        pendingOrder.removeAll { $0 == key }

        runningDownloads[key] = RunningDownload(roomID: pending.item.roomID, lane: lane)
        continuation.resume()
    }

    private func cancelPendingDownload(for key: DownloadKey) {
        pendingDownloads.removeValue(forKey: key)
        pendingOrder.removeAll { $0 == key }
        guard let continuation = pendingContinuations.removeValue(forKey: key) else { return }
        continuation.resume(throwing: CancellationError())
        publishWorkerSnapshots()
    }

    private func finishScheduledDownload(itemID: String, variant: CacheVariant) {
        let key = DownloadKey(itemID: itemID, variant: variant)
        guard runningDownloads.removeValue(forKey: key) != nil else {
            pendingDownloads.removeValue(forKey: key)
            pendingOrder.removeAll { $0 == key }
            pendingContinuations.removeValue(forKey: key)
            publishWorkerSnapshots()
            return
        }

        schedulePendingDownloads()
    }

    private func orderedPendingKeys(for variant: CacheVariant? = nil) -> [DownloadKey] {
        pendingOrder.filter { key in
            guard let pending = pendingDownloads[key] else { return false }
            guard let variant else { return true }
            return pending.key.variant == variant
        }
    }

    private func orderedPendingRoomIDs(for variant: CacheVariant) -> [String] {
        orderedPendingKeys(for: variant).compactMap { pendingDownloads[$0]?.item.roomID.rawValue }
    }

    private func runningRoomIDs(for variant: CacheVariant? = nil) -> [String] {
        runningDownloads.compactMap { key, value in
            guard variant == nil || key.variant == variant else { return nil }
            return value.roomID.rawValue
        }
    }

    private func workerPolicy(for variant: CacheVariant) -> MediaDownloadWorkerPolicy {
        switch variant {
        case .original:
            return .originals
        case .thumbnail:
            return .thumbnails
        }
    }

    private func publishWorkerSnapshots() {
        workerBroadcaster.yield(makeWorkerSnapshots())
    }

    private func makeWorkerSnapshots() -> [MediaDownloadWorkerSnapshot] {
        makeWorkerSnapshots(for: .thumbnail, workerCount: 2) +
            makeWorkerSnapshots(for: .original, workerCount: 3)
    }

    private func makeWorkerSnapshots(for variant: CacheVariant, workerCount: Int) -> [MediaDownloadWorkerSnapshot] {
        let runningEntries = orderedRunningEntries(for: variant)
        let pendingCount = orderedPendingKeys(for: variant).count
        let kind: MediaDownloadWorkerKind = variant == .thumbnail ? .thumbnail : .original

        return (0..<workerCount).map { index in
            let label = workerLabel(for: variant, slot: index + 1)
            if runningEntries.indices.contains(index) {
                let (key, running) = runningEntries[index]
                let statusText = running.lane == .activeRoom ? "Active" : "Back"
                return MediaDownloadWorkerSnapshot(
                    workerID: "\(variant.rawValue)-\(index + 1)",
                    kind: kind,
                    slot: index + 1,
                    label: label,
                    statusText: statusText,
                    pendingCount: pendingCount,
                    roomID: running.roomID.rawValue,
                    itemID: key.itemID
                )
            }

            return MediaDownloadWorkerSnapshot(
                workerID: "\(variant.rawValue)-\(index + 1)",
                kind: kind,
                slot: index + 1,
                label: label,
                statusText: "Idle",
                pendingCount: pendingCount,
                roomID: nil,
                itemID: nil
            )
        }
    }

    private func orderedRunningEntries(for variant: CacheVariant) -> [(DownloadKey, RunningDownload)] {
        runningDownloads
            .filter { $0.key.variant == variant }
            .sorted { lhs, rhs in
                if lhs.value.lane != rhs.value.lane {
                    return lhs.value.lane == .activeRoom
                }
                if lhs.value.roomID != rhs.value.roomID {
                    return lhs.value.roomID.rawValue < rhs.value.roomID.rawValue
                }
                return lhs.key.itemID < rhs.key.itemID
            }
    }

    private func workerLabel(for variant: CacheVariant, slot: Int) -> String {
        switch variant {
        case .thumbnail:
            return "Thumb \(slot)"
        case .original:
            return "Orig \(slot)"
        }
    }

    private static func fileExtension(forMimeType mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/avif":
            return "avif"
        case "image/heic", "image/heif":
            return "heic"
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        case "video/webm":
            return "webm"
        case "video/x-matroska":
            return "mkv"
        default:
            return nil
        }
    }
}

enum MediaDownloadLane: Equatable {
    case activeRoom
    case background
}

struct MediaDownloadWorkerPolicy: Equatable {
    let maxConcurrentDownloads: Int
    let maxActiveRoomDownloads: Int
    let maxBackgroundDownloadsWhileActiveBusy: Int
    let blocksBackgroundWhileActiveRunning: Bool

    static let originals = MediaDownloadWorkerPolicy(
        maxConcurrentDownloads: 3,
        maxActiveRoomDownloads: 2,
        maxBackgroundDownloadsWhileActiveBusy: 1,
        blocksBackgroundWhileActiveRunning: true
    )

    static let thumbnails = MediaDownloadWorkerPolicy(
        maxConcurrentDownloads: 2,
        maxActiveRoomDownloads: 2,
        maxBackgroundDownloadsWhileActiveBusy: 0,
        blocksBackgroundWhileActiveRunning: false
    )
}

struct MediaDownloadSchedulingDecision: Equatable {
    let pendingIndex: Int
    let lane: MediaDownloadLane
}

enum MediaDownloadSchedulingPolicy {
    static func immediateLane(
        for roomID: String,
        activeRoomID: String?,
        pendingRoomIDs: [String],
        runningRoomIDs: [String],
        policy: MediaDownloadWorkerPolicy = .originals
    ) -> MediaDownloadLane? {
        guard runningRoomIDs.count < policy.maxConcurrentDownloads else { return nil }

        let activeRunning = currentActiveRunningCount(activeRoomID: activeRoomID, runningRoomIDs: runningRoomIDs)
        if roomID == activeRoomID {
            guard activeRunning < policy.maxActiveRoomDownloads else { return nil }
            return .activeRoom
        }

        let backgroundRunning = runningRoomIDs.count - activeRunning
        if activeDemandExists(
            activeRoomID: activeRoomID,
            pendingRoomIDs: pendingRoomIDs,
            runningRoomIDs: runningRoomIDs,
            policy: policy
        ),
           backgroundRunning >= policy.maxBackgroundDownloadsWhileActiveBusy {
            return nil
        }

        return .background
    }

    static func nextPendingDecision(
        activeRoomID: String?,
        pendingRoomIDs: [String],
        runningRoomIDs: [String],
        policy: MediaDownloadWorkerPolicy = .originals
    ) -> MediaDownloadSchedulingDecision? {
        guard runningRoomIDs.count < policy.maxConcurrentDownloads else { return nil }

        let activeRunning = currentActiveRunningCount(activeRoomID: activeRoomID, runningRoomIDs: runningRoomIDs)
        if let activeRoomID,
           activeRunning < policy.maxActiveRoomDownloads,
           let pendingIndex = pendingRoomIDs.firstIndex(of: activeRoomID) {
            return MediaDownloadSchedulingDecision(pendingIndex: pendingIndex, lane: .activeRoom)
        }

        let activeDemand = activeDemandExists(
            activeRoomID: activeRoomID,
            pendingRoomIDs: pendingRoomIDs,
            runningRoomIDs: runningRoomIDs,
            policy: policy
        )
        let backgroundRunning = runningRoomIDs.count - activeRunning
        if activeDemand, backgroundRunning >= policy.maxBackgroundDownloadsWhileActiveBusy {
            return nil
        }

        if activeDemand, let activeRoomID {
            guard let pendingIndex = pendingRoomIDs.firstIndex(where: { $0 != activeRoomID }) else {
                return nil
            }
            return MediaDownloadSchedulingDecision(pendingIndex: pendingIndex, lane: .background)
        }

        guard !pendingRoomIDs.isEmpty else { return nil }
        return MediaDownloadSchedulingDecision(pendingIndex: 0, lane: .background)
    }

    static func activeDemandExists(
        activeRoomID: String?,
        pendingRoomIDs: [String],
        runningRoomIDs: [String],
        policy: MediaDownloadWorkerPolicy
    ) -> Bool {
        guard let activeRoomID else { return false }
        if pendingRoomIDs.contains(activeRoomID) {
            return true
        }
        return policy.blocksBackgroundWhileActiveRunning && runningRoomIDs.contains(activeRoomID)
    }

    static func currentActiveRunningCount(activeRoomID: String?, runningRoomIDs: [String]) -> Int {
        guard let activeRoomID else { return 0 }
        return runningRoomIDs.filter { $0 == activeRoomID }.count
    }
}

private enum MediaCacheError: LocalizedError {
    case invalidMedia

    var errorDescription: String? {
        switch self {
        case .invalidMedia:
            return "Invalid media metadata."
        }
    }
}

private final class RemoteMediaDownloader: NSObject, @unchecked Sendable {
    func download(
        request: URLRequest,
        destinationURL: URL,
        progress: (@Sendable (Int64, Int64?) async -> Void)?
    ) async throws -> (URL, URLResponse) {
        let delegate = RemoteMediaDownloadDelegate(
            destinationURL: destinationURL,
            allowedRedirectHost: request.url?.host,
            allowedRedirectScheme: request.url?.scheme,
            progress: progress
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        defer {
            session.finishTasksAndInvalidate()
        }

        return try await delegate.start(session: session, request: request)
    }
}

private final class RemoteMediaDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let allowedRedirectHost: String?
    private let allowedRedirectScheme: String?
    private let progress: (@Sendable (Int64, Int64?) async -> Void)?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var hasCompleted = false

    init(
        destinationURL: URL,
        allowedRedirectHost: String?,
        allowedRedirectScheme: String?,
        progress: (@Sendable (Int64, Int64?) async -> Void)?
    ) {
        self.destinationURL = destinationURL
        self.allowedRedirectHost = allowedRedirectHost?.lowercased()
        self.allowedRedirectScheme = allowedRedirectScheme?.lowercased()
        self.progress = progress
    }

    func start(session: URLSession, request: URLRequest) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let progress = self.progress
        Task {
            await progress?(totalBytesWritten, totalBytes)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response else {
            finish(with: .failure(MediaCacheError.invalidMedia))
            return
        }

        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            finish(with: .success((destinationURL, response)))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirectedURL = request.url,
              redirectedURL.host?.lowercased() == allowedRedirectHost,
              redirectedURL.scheme?.lowercased() == allowedRedirectScheme else {
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<(URL, URLResponse), Error>) {
        guard !hasCompleted else { return }
        hasCompleted = true
        continuation?.resume(with: result)
        continuation = nil
    }
}
#else
public actor MatrixMediaCache {
    public init(client: Any, diagnostics: DiagnosticsService, cacheRootURL: URL, fileManager: FileManager = .default) {}
    public func stream(for roomID: RoomIdentifier) -> AsyncStream<[String: TimelineMediaLoadState]> { AsyncStream { _ in } }
    public func setActiveRoom(_ roomID: RoomIdentifier?) {}
    public func prepareMedia(for item: TimelineItem, prefetchOriginal: Bool) {}
    public func ensureOriginalAvailable(for item: TimelineItem) async -> URL? { nil }
    public func prune(roomID: RoomIdentifier, keepingItems: [TimelineItem]) {}
}
#endif
