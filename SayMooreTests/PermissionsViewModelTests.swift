// SayMooreTests/PermissionsViewModelTests.swift
import XCTest
@testable import SayMoore

// MARK: - MockPermissionChecker

final class MockPermissionChecker: PermissionChecker, @unchecked Sendable {
    var micStatus: PermissionStatus = .notDetermined
    var accessStatus: PermissionStatus = .notDetermined
    var inputStatus: PermissionStatus = .notDetermined
    var notifStatus: PermissionStatus = .notDetermined

    var micRequestCount = 0
    var notifRequestCount = 0

    func microphoneStatus() -> PermissionStatus { micStatus }
    func accessibilityStatus() -> PermissionStatus { accessStatus }
    func inputMonitoringStatus() -> PermissionStatus { inputStatus }
    func notificationsStatus() async -> PermissionStatus { notifStatus }
    func requestMicrophoneAccess() async { micRequestCount += 1 }
    func requestNotificationsAccess() async { notifRequestCount += 1 }
}

// MARK: - PermissionStatuses tests

@MainActor
final class PermissionStatusesTests: XCTestCase {

    func test_allRequiredGranted_whenAllThreeGranted() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .notDetermined)
        XCTAssertTrue(s.allRequiredGranted)
    }

    func test_allRequiredGranted_false_whenMicMissing() {
        let s = PermissionStatuses(microphone: .notDetermined, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertFalse(s.allRequiredGranted)
    }

    func test_allRequiredGranted_false_whenAccessibilityMissing() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .notDetermined,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertFalse(s.allRequiredGranted)
    }

    func test_allRequiredGranted_false_whenInputMonitoringMissing() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .notDetermined, notifications: .granted)
        XCTAssertFalse(s.allRequiredGranted)
    }

    func test_allRequiredGranted_true_whenNotificationsDenied() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .denied)
        XCTAssertTrue(s.allRequiredGranted)
    }

    func test_currentStep_one_whenMicNotGranted() {
        let s = PermissionStatuses(microphone: .notDetermined, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertEqual(s.currentStep, 1)
    }

    func test_currentStep_two_whenMicGrantedAccessibilityNotGranted() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .notDetermined,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertEqual(s.currentStep, 2)
    }

    func test_currentStep_three_whenMicAndAccessibilityGrantedInputMonitoringNotGranted() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .notDetermined, notifications: .granted)
        XCTAssertEqual(s.currentStep, 3)
    }

    func test_currentStep_four_whenAllRequiredGrantedNotificationsMissing() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .notDetermined)
        XCTAssertEqual(s.currentStep, 4)
    }

    func test_currentStep_five_whenAllGranted() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertEqual(s.currentStep, 5)
    }
}
