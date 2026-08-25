import Foundation

enum NotificationDefaultsKey {
    static let desktopNotificationsEnabled = "Workspace.notifications.enabled"
    static let soundEnabled = "Workspace.notifications.soundEnabled"
}

public struct NotificationPreferences: Equatable {
    public let desktopNotificationsEnabled: Bool
    public let soundEnabled: Bool

    public init(defaults: UserDefaults = .standard) {
        Self.registerDefaults(in: defaults)
        desktopNotificationsEnabled = defaults.object(forKey: NotificationDefaultsKey.desktopNotificationsEnabled) == nil
            ? true
            : defaults.bool(forKey: NotificationDefaultsKey.desktopNotificationsEnabled)
        soundEnabled = defaults.object(forKey: NotificationDefaultsKey.soundEnabled) == nil
            ? true
            : defaults.bool(forKey: NotificationDefaultsKey.soundEnabled)
    }

    public static func registerDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: [
            NotificationDefaultsKey.desktopNotificationsEnabled: true,
            NotificationDefaultsKey.soundEnabled: true
        ])
    }
}
