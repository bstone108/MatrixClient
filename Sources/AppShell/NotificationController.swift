import AppKit
import Diagnostics
import MatrixCore
@preconcurrency import UserNotifications

final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private actor StateSnapshot {
        private var selectedAccountID: AccountIdentifier?
        private var selectedRoomID: RoomIdentifier?
        private var isViewingTimeline = true
        private var accountCount = 0

        func update(
            selectedAccountID: AccountIdentifier?,
            selectedRoomID: RoomIdentifier?,
            isViewingTimeline: Bool,
            accountCount: Int
        ) {
            self.selectedAccountID = selectedAccountID
            self.selectedRoomID = selectedRoomID
            self.isViewingTimeline = isViewingTimeline
            self.accountCount = accountCount
        }

        func frontmostState(for event: RoomNotificationEvent, appIsActive: Bool) -> (isSelectedRoom: Bool, hasMultipleAccounts: Bool) {
            (
                TimelineNotificationPolicy.shouldSuppressFrontmostRoom(
                    appIsActive: appIsActive,
                    isViewingTimeline: isViewingTimeline,
                    selectedAccountID: selectedAccountID,
                    selectedRoomID: selectedRoomID,
                    eventAccountID: event.accountID,
                    eventRoomID: event.roomID
                ),
                accountCount > 1
            )
        }
    }

    private let matrixClient: any MatrixClientFacade
    private let state: WorkspaceStateController
    private let diagnostics: DiagnosticsService
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let stateSnapshot = StateSnapshot()
    private var streamTask: Task<Void, Never>?
    private var didLogDeniedAuthorization = false

    init(
        matrixClient: any MatrixClientFacade,
        state: WorkspaceStateController,
        diagnostics: DiagnosticsService,
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.matrixClient = matrixClient
        self.state = state
        self.diagnostics = diagnostics
        self.center = center
        self.defaults = defaults
        super.init()
        NotificationPreferences.registerDefaults(in: defaults)
        center.delegate = self
    }

    @MainActor
    func start() {
        center.delegate = self
        syncStateSnapshot()
        state.addSessionObserver { [weak self] in
            self?.syncStateSnapshot()
            Task { @MainActor [weak self] in
                await self?.refreshAuthorizationIfNeeded()
            }
        }
        state.addSelectionObserver { [weak self] in
            self?.syncStateSnapshot()
        }
        Task { @MainActor [weak self] in
            await self?.refreshAuthorizationIfNeeded()
        }

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await matrixClient.notificationEventStream()
            for await event in stream {
                await self.deliver(event)
            }
        }
    }

    @MainActor
    func applicationDidBecomeActive() {
        syncStateSnapshot()
        Task { await refreshAuthorizationIfNeeded() }
    }

    @MainActor
    private func syncStateSnapshot() {
        let selectedAccountID = state.selectedAccountID
        let selectedRoomID = state.selectedRoomID
        let isViewingTimeline = state.selectedSettingsDestination == nil
        let accountCount = state.accounts.count
        Task { [stateSnapshot] in
            await stateSnapshot.update(
                selectedAccountID: selectedAccountID,
                selectedRoomID: selectedRoomID,
                isViewingTimeline: isViewingTimeline,
                accountCount: accountCount
            )
        }
    }

    func refreshAuthorizationIfNeeded() async {
        guard NotificationPreferences(defaults: defaults).desktopNotificationsEnabled else { return }
        let settings = await currentNotificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await requestAuthorization()
                if !granted {
                    await diagnostics.record(.notice, category: "Notifications", message: "Notification authorization was not granted")
                }
            } catch {
                await diagnostics.record(.error, category: "Notifications", message: "Failed to request notification authorization", metadata: [
                    "error": error.localizedDescription
                ])
            }
        case .denied:
            await logDeniedAuthorizationIfNeeded()
        default:
            break
        }
    }

    private func deliver(_ event: RoomNotificationEvent) async {
        let preferences = NotificationPreferences(defaults: defaults)
        guard preferences.desktopNotificationsEnabled else { return }
        guard await ensureAuthorizedToDeliver() else { return }

        let appIsActive = await MainActor.run { NSApp.isActive }
        let frontmostState = await stateSnapshot.frontmostState(for: event, appIsActive: appIsActive)
        guard !frontmostState.isSelectedRoom else { return }

        let roomMode = RoomNotificationPreferenceStore(defaults: defaults).mode(
            accountID: event.accountID,
            roomID: event.roomID
        )
        guard MatrixMentionMatcher.shouldNotify(
            mode: roomMode,
            desktopNotificationsEnabled: true,
            isMention: event.isMention
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = event.roomDisplayName
        let accountSuffix = frontmostState.hasMultipleAccounts ? " • \(event.accountDisplayName)" : ""
        content.subtitle = event.senderDisplayName + accountSuffix
        content.body = event.previewText
        if preferences.soundEnabled {
            content.sound = .default
        }
        content.interruptionLevel = .active
        content.userInfo = [
            "accountID": event.accountID.rawValue,
            "roomID": event.roomID.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: event.id,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            await diagnostics.record(.error, category: "Notifications", message: "Failed to schedule macOS notification", metadata: [
                "error": error.localizedDescription
            ])
        }
    }

    private func ensureAuthorizedToDeliver() async -> Bool {
        var settings = await currentNotificationSettings()
        if settings.authorizationStatus == .notDetermined {
            await refreshAuthorizationIfNeeded()
            settings = await currentNotificationSettings()
        }
        switch settings.authorizationStatus {
        case .denied:
            await logDeniedAuthorizationIfNeeded()
            return false
        case .notDetermined:
            return false
        default:
            return true
        }
    }

    private func logDeniedAuthorizationIfNeeded() async {
        guard !didLogDeniedAuthorization else { return }
        didLogDeniedAuthorization = true
        await diagnostics.record(.notice, category: "Notifications", message: "macOS notification permission is denied. Enable banners for Matrix Client in System Settings → Notifications.")
    }

    private func currentNotificationSettings() async -> UNNotificationSettings {
        await center.notificationSettings()
    }

    private func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let preferences = NotificationPreferences(defaults: defaults)
        guard preferences.desktopNotificationsEnabled else { return [] }

        let userInfo = notification.request.content.userInfo
        let appIsActive = await MainActor.run { NSApp.isActive }
        if let accountID = userInfo["accountID"] as? String,
           let roomID = userInfo["roomID"] as? String,
           await stateSnapshot.frontmostState(for:
            RoomNotificationEvent(
                accountID: AccountIdentifier(rawValue: accountID),
                accountDisplayName: "",
                roomID: RoomIdentifier(rawValue: roomID),
                roomDisplayName: "",
                senderID: "",
                senderDisplayName: "",
                eventID: notification.request.identifier,
                previewText: "",
                timestamp: .now
            ),
            appIsActive: appIsActive
           ).isSelectedRoom {
            return []
        }

        var options: UNNotificationPresentationOptions = [.banner, .list]
        if preferences.soundEnabled {
            options.insert(.sound)
        }
        return options
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo
        guard let accountID = userInfo["accountID"] as? String,
              let roomID = userInfo["roomID"] as? String else {
            return
        }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            state.revealRoom(
                RoomIdentifier(rawValue: roomID),
                accountID: AccountIdentifier(rawValue: accountID)
            )
        }
    }
}

extension NotificationController: @unchecked Sendable {}
