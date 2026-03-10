import AppKit
import Diagnostics
import Foundation
import MatrixCore
import TimelineUI

@MainActor
public final class WorkspaceStateController: NSObject, TimelineWorkspaceState, LoginWorkspaceState {
    private enum DefaultsKey {
        static let selectedAccountID = "Workspace.selectedAccountID"
        static let selectedSpacePrefix = "Workspace.selectedSpace."
        static let selectedRoomPrefix = "Workspace.selectedRoom."
        static let selectedSettingsPrefix = "Workspace.selectedSettings."
    }

    private let matrixClient: any MatrixClientFacade
    private let diagnostics: DiagnosticsService
    private let supportBundleBuilder: SupportBundleBuilder
    private let defaults: UserDefaults

    private var sessionObservers: [UUID: @MainActor () -> Void] = [:]
    private var sidebarObservers: [UUID: @MainActor () -> Void] = [:]
    private var roomListObservers: [UUID: @MainActor () -> Void] = [:]
    private var timelineObservers: [UUID: @MainActor () -> Void] = [:]
    private var mediaObservers: [UUID: @MainActor () -> Void] = [:]
    private var inspectorObservers: [UUID: @MainActor () -> Void] = [:]
    private var selectionObservers: [UUID: @MainActor () -> Void] = [:]

    private var sessionTask: Task<Void, Never>?
    private var roomListTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var verificationTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var knownRoomDisplayNames: [RoomIdentifier: String] = [:]

    public private(set) var sessionState: ClientSessionState = .launching
    public private(set) var accounts: [AccountSummary] = []
    public private(set) var spaces: [SpaceSummary] = []
    public private(set) var rooms: [RoomSummary] = []
    public private(set) var timelineItems: [TimelineItem] = []
    public private(set) var mediaStates: [String: TimelineMediaLoadState] = [:]
    public private(set) var mediaWorkerSnapshots: [MediaDownloadWorkerSnapshot] = []
    public private(set) var verificationSnapshot: VerificationSnapshot = .initial
    public private(set) var selectedAccountID: AccountIdentifier?
    public private(set) var selectedSpaceID: SpaceIdentifier?
    public private(set) var selectedRoomID: RoomIdentifier?
    public private(set) var selectedSettingsDestination: WorkspaceSettingsDestination?
    public private(set) var selectedRoomDetails: RoomDetails?

    public var selectedAccountSummary: AccountSummary? {
        guard let selectedAccountID else { return nil }
        return accounts.first(where: { $0.accountID == selectedAccountID })
    }

    public var selectedRoomSummary: RoomSummary? {
        guard let selectedRoomID else { return nil }
        return rooms.first(where: { $0.roomID == selectedRoomID })
    }

    public var currentWindowTitle: String {
        if let selectedSettingsDestination {
            return selectedSettingsDestination.title
        }
        return selectedRoomSummary?.displayName ?? "Matrix Client"
    }

    public init(
        matrixClient: any MatrixClientFacade,
        diagnostics: DiagnosticsService,
        supportBundleBuilder: SupportBundleBuilder,
        defaults: UserDefaults = .standard
    ) {
        self.matrixClient = matrixClient
        self.diagnostics = diagnostics
        self.supportBundleBuilder = supportBundleBuilder
        self.defaults = defaults
    }

    public func bootstrap() {
        sessionTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.matrixClient.sessionStateStream()
            Task { [weak self] in
                guard let self else { return }
                for await state in stream {
                    await MainActor.run {
                        self.applySessionState(state)
                    }
                }
            }
            await self.matrixClient.bootstrapIfNeeded()
        }
    }

    public func addSessionObserver(_ observer: @escaping @MainActor () -> Void) {
        sessionObservers[UUID()] = observer
    }

    public func addSidebarObserver(_ observer: @escaping @MainActor () -> Void) {
        sidebarObservers[UUID()] = observer
    }

    public func addRoomListObserver(_ observer: @escaping @MainActor () -> Void) {
        roomListObservers[UUID()] = observer
    }

    public func addTimelineObserver(_ observer: @escaping @MainActor () -> Void) {
        timelineObservers[UUID()] = observer
    }

    public func addMediaObserver(_ observer: @escaping @MainActor () -> Void) {
        mediaObservers[UUID()] = observer
    }

    public func addInspectorObserver(_ observer: @escaping @MainActor () -> Void) {
        inspectorObservers[UUID()] = observer
    }

    public func addSelectionObserver(_ observer: @escaping @MainActor () -> Void) {
        selectionObservers[UUID()] = observer
    }

    public func selectAccount(_ accountID: AccountIdentifier) {
        guard selectedAccountID != accountID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.loadAccount(accountID)
        }
    }

    public func selectSpace(_ spaceID: SpaceIdentifier?) {
        guard selectedSpaceID != spaceID || selectedSettingsDestination != nil else { return }
        selectedSpaceID = spaceID
        selectedSettingsDestination = nil
        persistSelectedSpaceID(spaceID, for: selectedAccountID)
        persistSelectedSettingsDestination(nil, for: selectedAccountID)
        notify(selectionObservers)
        Task { [weak self] in
            guard let self else { return }
            await self.subscribeToRoomList()
        }
    }

    public func selectRoom(_ roomID: RoomIdentifier) {
        guard selectedRoomID != roomID || selectedSettingsDestination != nil else { return }
        selectedRoomID = roomID
        selectedSettingsDestination = nil
        persistSelectedRoomID(roomID, for: selectedAccountID)
        persistSelectedSettingsDestination(nil, for: selectedAccountID)
        notify(selectionObservers)
        Task { [weak self] in
            guard let self else { return }
            await self.loadRoomDetails()
            await self.subscribeToTimeline()
            self.markSelectedRoomAsRead()
        }
    }

    public func selectSettings(_ destination: WorkspaceSettingsDestination) {
        guard selectedSettingsDestination != destination else { return }
        selectedSettingsDestination = destination
        persistSelectedSettingsDestination(destination, for: selectedAccountID)
        notify(selectionObservers)
    }

    public func sendMessage(_ body: String) {
        guard let selectedRoomID, let selectedAccountID else { return }
        Task {
            await matrixClient.sendMessage(body, in: selectedRoomID, accountID: selectedAccountID)
        }
    }

    public func markSelectedRoomAsRead() {
        guard let selectedRoomID, let selectedAccountID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.matrixClient.markRoomAsRead(selectedRoomID, accountID: selectedAccountID)
        }
    }

    public func exportSupportBundle() async throws -> URL {
        let queueData = try JSONEncoder.prettyPrinted.encode(await matrixClient.queueDiagnostics())
        return try await supportBundleBuilder.exportBundle(attachments: [
            SupportBundleAttachment(fileName: "send-queue.json", data: queueData)
        ])
    }

    public func login(serverNameOrURL: String?, username: String, password: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.matrixClient.login(serverNameOrURL: serverNameOrURL, username: username, password: password)
        }
    }

    public func mediaState(for itemID: String) -> TimelineMediaLoadState? {
        mediaStates[itemID]
    }

    public func mediaWorkerSnapshots(for kind: MediaDownloadWorkerKind) -> [MediaDownloadWorkerSnapshot] {
        mediaWorkerSnapshots
            .filter { $0.kind == kind }
            .sorted { $0.slot < $1.slot }
    }

    public func mediaWorkerRoomDisplayName(for roomID: String?) -> String {
        guard let roomID, !roomID.isEmpty else { return "Idle" }
        let identifier = RoomIdentifier(rawValue: roomID)
        if let displayName = knownRoomDisplayNames[identifier], !displayName.isEmpty {
            return displayName
        }
        if let displayName = rooms.first(where: { $0.roomID == identifier })?.displayName, !displayName.isEmpty {
            return displayName
        }
        if selectedRoomID == identifier, let displayName = selectedRoomSummary?.displayName, !displayName.isEmpty {
            return displayName
        }
        return roomID
    }

    public func requestVerification() {
        guard let selectedAccountID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.matrixClient.requestVerification(for: selectedAccountID)
        }
    }

    public func startSasVerification() {
        guard let selectedAccountID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.matrixClient.startSasVerification(for: selectedAccountID)
        }
    }

    public func approveVerification() {
        guard let selectedAccountID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.matrixClient.approveVerification(for: selectedAccountID)
        }
    }

    public func declineVerification() {
        guard let selectedAccountID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.matrixClient.declineVerification(for: selectedAccountID)
        }
    }

    public func cancelVerification() {
        guard let selectedAccountID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.matrixClient.cancelVerification(for: selectedAccountID)
        }
    }

    public func prepareMedia(for item: TimelineItem, prefetchOriginal: Bool) {
        guard let selectedAccountID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.matrixClient.prepareMedia(item, in: selectedAccountID, prefetchOriginal: prefetchOriginal)
        }
    }

    public func resolveOriginalMediaURL(for item: TimelineItem) async -> URL? {
        guard let selectedAccountID else { return nil }
        return await matrixClient.resolveOriginalMediaURL(for: item, in: selectedAccountID)
    }

    public func resolveReceiptAvatarFileURL(for receipt: ReadReceipt) async -> URL? {
        guard let selectedAccountID else { return nil }
        return await matrixClient.resolveReceiptAvatarFileURL(for: receipt, in: selectedAccountID)
    }

    private func applySessionState(_ state: ClientSessionState) {
        sessionState = state
        switch state {
        case .connected:
            Task { [weak self] in
                guard let self else { return }
                await self.loadConnectedState()
            }
        case .signedOut:
            clearWorkspaceState()
        case .launching, .restoring, .signingIn:
            if accounts.isEmpty {
                clearWorkspaceState()
            }
        }
        notify(sessionObservers)
    }

    private func loadConnectedState() async {
        accounts = await matrixClient.accountSummaries()
        notify(sidebarObservers)
        guard !accounts.isEmpty else {
            clearWorkspaceState()
            return
        }

        let persistedAccountID = persistedSelectedAccountID()
        let accountToLoad: AccountIdentifier
        if let persistedAccountID, accounts.contains(where: { $0.accountID == persistedAccountID }) {
            accountToLoad = persistedAccountID
        } else if let selectedAccountID, accounts.contains(where: { $0.accountID == selectedAccountID }) {
            accountToLoad = selectedAccountID
        } else {
            accountToLoad = accounts[0].accountID
        }

        await loadAccount(accountToLoad)
    }

    private func loadAccount(_ accountID: AccountIdentifier) async {
        selectedAccountID = accountID
        persistSelectedAccountID(accountID)

        spaces = await matrixClient.spaceSummaries(for: accountID)
        if let persistedSpaceID = persistedSelectedSpaceID(for: accountID),
           spaces.contains(where: { $0.spaceID == persistedSpaceID }) {
            selectedSpaceID = persistedSpaceID
        } else {
            selectedSpaceID = nil
            persistSelectedSpaceID(nil, for: accountID)
        }

        selectedRoomID = persistedSelectedRoomID(for: accountID)
        selectedSettingsDestination = persistedSelectedSettingsDestination(for: accountID)
        selectedRoomDetails = nil

        notify(sidebarObservers)
        notify(selectionObservers)
        notify(inspectorObservers)

        await subscribeToVerification()
        await subscribeToMediaWorkers()
        await subscribeToRoomList()
    }

    private func subscribeToRoomList() async {
        roomListTask?.cancel()
        timelineTask?.cancel()
        mediaTask?.cancel()
        timelineItems = []
        mediaStates = [:]
        notify(timelineObservers)
        notify(mediaObservers)

        guard let selectedAccountID else {
            rooms = []
            notify(roomListObservers)
            return
        }

        let stream = await matrixClient.roomListStream(for: selectedAccountID, spaceID: selectedSpaceID)
        roomListTask = Task { [weak self] in
            guard let self else { return }
            for await roomSnapshot in stream {
                let shouldSubscribeToTimeline = await MainActor.run { () -> Bool in
                    let previousSelectedRoomID = self.selectedRoomID
                    self.rooms = roomSnapshot
                    for room in roomSnapshot {
                        self.knownRoomDisplayNames[room.roomID] = room.displayName
                    }

                    let persistedRoomID = self.persistedSelectedRoomID(for: selectedAccountID)
                    if let current = self.selectedRoomID,
                       roomSnapshot.contains(where: { $0.roomID == current }) {
                        self.selectedRoomID = current
                    } else if let persistedRoomID,
                              roomSnapshot.contains(where: { $0.roomID == persistedRoomID }) {
                        self.selectedRoomID = persistedRoomID
                    } else {
                        self.selectedRoomID = roomSnapshot.first?.roomID
                    }

                    self.persistSelectedRoomID(self.selectedRoomID, for: selectedAccountID)
                    self.notify(self.roomListObservers)
                    if self.selectedRoomID != previousSelectedRoomID {
                        self.notify(self.selectionObservers)
                    }
                    return self.selectedRoomID != previousSelectedRoomID || self.timelineTask == nil
                }
                await self.loadRoomDetails()
                if shouldSubscribeToTimeline {
                    await self.subscribeToTimeline()
                }
            }
        }
    }

    private func subscribeToTimeline() async {
        timelineTask?.cancel()
        mediaTask?.cancel()
        mediaStates = [:]
        notify(mediaObservers)

        guard let selectedAccountID, let selectedRoomID else {
            timelineItems = []
            notify(timelineObservers)
            return
        }

        let stream = await matrixClient.timelineStream(for: selectedAccountID, roomID: selectedRoomID)
        let mediaStream = await matrixClient.mediaStateStream(for: selectedAccountID, roomID: selectedRoomID)
        timelineTask = Task { [weak self] in
            guard let self else { return }
            for await items in stream {
                await MainActor.run {
                    self.timelineItems = items
                    self.notify(self.timelineObservers)
                }
            }
        }
        mediaTask = Task { [weak self] in
            guard let self else { return }
            for await states in mediaStream {
                await MainActor.run {
                    self.mediaStates = states
                    self.notify(self.mediaObservers)
                }
            }
        }
    }

    private func loadRoomDetails() async {
        guard let selectedAccountID, let selectedRoomID else {
            selectedRoomDetails = nil
            notify(inspectorObservers)
            return
        }
        selectedRoomDetails = await matrixClient.roomDetails(for: selectedAccountID, roomID: selectedRoomID)
        notify(inspectorObservers)
    }

    private func subscribeToMediaWorkers() async {
        workerTask?.cancel()
        mediaWorkerSnapshots = []
        notify(inspectorObservers)

        guard let selectedAccountID else { return }
        let stream = await matrixClient.mediaWorkerStateStream(for: selectedAccountID)
        workerTask = Task { [weak self] in
            guard let self else { return }
            for await snapshots in stream {
                await MainActor.run {
                    self.mediaWorkerSnapshots = snapshots.sorted {
                        if $0.kind != $1.kind {
                            return $0.kind.rawValue < $1.kind.rawValue
                        }
                        return $0.slot < $1.slot
                    }
                    self.notify(self.inspectorObservers)
                }
            }
        }
    }

    private func subscribeToVerification() async {
        verificationTask?.cancel()
        verificationSnapshot = .initial
        notify(inspectorObservers)

        guard let selectedAccountID else { return }
        let stream = await matrixClient.verificationStateStream(for: selectedAccountID)
        verificationTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in stream {
                await MainActor.run {
                    self.verificationSnapshot = snapshot
                    self.notify(self.inspectorObservers)
                }
            }
        }
    }

    private func clearWorkspaceState() {
        roomListTask?.cancel()
        timelineTask?.cancel()
        mediaTask?.cancel()
        verificationTask?.cancel()
        workerTask?.cancel()
        accounts = []
        spaces = []
        rooms = []
        timelineItems = []
        mediaStates = [:]
        mediaWorkerSnapshots = []
        verificationSnapshot = .initial
        selectedAccountID = nil
        selectedSpaceID = nil
        selectedRoomID = nil
        selectedSettingsDestination = nil
        selectedRoomDetails = nil
        knownRoomDisplayNames = [:]
        notify(sidebarObservers)
        notify(roomListObservers)
        notify(timelineObservers)
        notify(mediaObservers)
        notify(inspectorObservers)
        notify(selectionObservers)
    }

    private func persistedSelectedAccountID() -> AccountIdentifier? {
        guard let value = defaults.string(forKey: DefaultsKey.selectedAccountID), !value.isEmpty else { return nil }
        return AccountIdentifier(rawValue: value)
    }

    private func persistSelectedAccountID(_ accountID: AccountIdentifier?) {
        if let accountID {
            defaults.set(accountID.rawValue, forKey: DefaultsKey.selectedAccountID)
        } else {
            defaults.removeObject(forKey: DefaultsKey.selectedAccountID)
        }
    }

    private func persistedSelectedSpaceID(for accountID: AccountIdentifier) -> SpaceIdentifier? {
        guard let value = defaults.string(forKey: DefaultsKey.selectedSpacePrefix + accountID.rawValue), !value.isEmpty else {
            return nil
        }
        return SpaceIdentifier(rawValue: value)
    }

    private func persistSelectedSpaceID(_ spaceID: SpaceIdentifier?, for accountID: AccountIdentifier?) {
        guard let accountID else { return }
        let key = DefaultsKey.selectedSpacePrefix + accountID.rawValue
        if let spaceID {
            defaults.set(spaceID.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func persistedSelectedRoomID(for accountID: AccountIdentifier) -> RoomIdentifier? {
        guard let value = defaults.string(forKey: DefaultsKey.selectedRoomPrefix + accountID.rawValue), !value.isEmpty else {
            return nil
        }
        return RoomIdentifier(rawValue: value)
    }

    private func persistSelectedRoomID(_ roomID: RoomIdentifier?, for accountID: AccountIdentifier?) {
        guard let accountID else { return }
        let key = DefaultsKey.selectedRoomPrefix + accountID.rawValue
        if let roomID {
            defaults.set(roomID.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func persistedSelectedSettingsDestination(for accountID: AccountIdentifier) -> WorkspaceSettingsDestination? {
        guard let value = defaults.string(forKey: DefaultsKey.selectedSettingsPrefix + accountID.rawValue), !value.isEmpty else {
            return nil
        }
        return WorkspaceSettingsDestination(rawValue: value)
    }

    private func persistSelectedSettingsDestination(_ destination: WorkspaceSettingsDestination?, for accountID: AccountIdentifier?) {
        guard let accountID else { return }
        let key = DefaultsKey.selectedSettingsPrefix + accountID.rawValue
        if let destination {
            defaults.set(destination.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func notify(_ observers: [UUID: @MainActor () -> Void]) {
        for observer in observers.values {
            observer()
        }
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
