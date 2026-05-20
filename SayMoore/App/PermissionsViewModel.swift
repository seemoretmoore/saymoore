// SayMoore/App/PermissionsViewModel.swift
import Foundation

@MainActor
final class PermissionsViewModel: ObservableObject {
    @Published private(set) var statuses: PermissionStatuses = .initial

    let checker: any PermissionChecker

    var onAllGranted: () -> Void = {} {
        didSet { allGrantedFired = false }
    }

    private var micRequestedOnce = false
    private var notifRequestedOnce = false
    private var allGrantedFired = false

    init(checker: any PermissionChecker) {
        self.checker = checker
    }

    func recheck() async {
        if !micRequestedOnce && checker.microphoneStatus() == .notDetermined {
            micRequestedOnce = true
            await checker.requestMicrophoneAccess()
        }

        let mic = checker.microphoneStatus()
        let access = checker.accessibilityStatus()
        let input = checker.inputMonitoringStatus()
        var notif = await checker.notificationsStatus()

        if mic == .granted && access == .granted && input == .granted &&
           notif == .notDetermined && !notifRequestedOnce {
            notifRequestedOnce = true
            await checker.requestNotificationsAccess()
            notif = await checker.notificationsStatus()
        }

        statuses = PermissionStatuses(
            microphone: mic,
            accessibility: access,
            inputMonitoring: input,
            notifications: notif
        )

        if statuses.allRequiredGranted && !allGrantedFired {
            allGrantedFired = true
            onAllGranted()
        }
    }

    func skipNotifications() {
        if statuses.allRequiredGranted && !allGrantedFired {
            allGrantedFired = true
            onAllGranted()
        }
    }
}
