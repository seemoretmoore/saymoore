// SayMoore/Services/PermissionChecker.swift
import AVFoundation
import IOKit.hid
import ApplicationServices
import UserNotifications

enum PermissionStatus: Equatable {
    case granted
    case notDetermined
    case denied
}

struct PermissionStatuses: Equatable {
    var microphone: PermissionStatus
    var accessibility: PermissionStatus
    var inputMonitoring: PermissionStatus
    var notifications: PermissionStatus

    var allRequiredGranted: Bool {
        microphone == .granted && accessibility == .granted && inputMonitoring == .granted
    }

    var currentStep: Int {
        if microphone != .granted { return 1 }
        if accessibility != .granted { return 2 }
        if inputMonitoring != .granted { return 3 }
        if notifications != .granted { return 4 }
        return 5
    }

    static let initial = PermissionStatuses(
        microphone: .notDetermined,
        accessibility: .notDetermined,
        inputMonitoring: .notDetermined,
        notifications: .notDetermined
    )
}

protocol PermissionChecker: AnyObject, Sendable {
    func microphoneStatus() -> PermissionStatus
    func accessibilityStatus() -> PermissionStatus
    func inputMonitoringStatus() -> PermissionStatus
    func notificationsStatus() async -> PermissionStatus
    func requestMicrophoneAccess() async
    func requestNotificationsAccess() async
}

final class LivePermissionChecker: PermissionChecker {
    func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .notDetermined
    }

    func inputMonitoringStatus() -> PermissionStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    func notificationsStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestMicrophoneAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestNotificationsAccess() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }
}
