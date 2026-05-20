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

// MARK: - PermissionsViewModel tests

@MainActor
final class PermissionsViewModelTests: XCTestCase {

    func test_recheck_requestsMicrophoneOnce_whenNotDetermined() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        await vm.recheck()
        XCTAssertEqual(checker.micRequestCount, 1)
    }

    func test_recheck_doesNotRequestMicrophone_whenAlreadyGranted() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .granted
        checker.notifStatus = .granted
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        XCTAssertEqual(checker.micRequestCount, 0)
    }

    func test_recheck_updatesStatuses_afterCheck() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .denied
        checker.inputStatus = .notDetermined
        checker.notifStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        XCTAssertEqual(vm.statuses.microphone, .granted)
        XCTAssertEqual(vm.statuses.accessibility, .denied)
        XCTAssertEqual(vm.statuses.inputMonitoring, .notDetermined)
    }

    func test_recheck_firesOnAllGranted_whenAllRequiredGranted() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .granted
        checker.notifStatus = .granted
        let vm = PermissionsViewModel(checker: checker)
        var fireCount = 0
        vm.onAllGranted = { fireCount += 1 }
        await vm.recheck()
        await vm.recheck()
        XCTAssertEqual(fireCount, 1)
    }

    func test_recheck_doesNotFireOnAllGranted_whenInputMonitoringMissing() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .notDetermined
        checker.notifStatus = .granted
        let vm = PermissionsViewModel(checker: checker)
        var fired = false
        vm.onAllGranted = { fired = true }
        await vm.recheck()
        XCTAssertFalse(fired)
    }

    func test_recheck_requestsNotificationsOnce_whenNotificationsPending() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .granted
        checker.notifStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        await vm.recheck()
        XCTAssertEqual(checker.notifRequestCount, 1)
    }

    func test_recheck_doesNotRequestNotifications_whenRequiredPermissionsMissing() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .notDetermined   // still on step 3
        checker.notifStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        XCTAssertEqual(checker.notifRequestCount, 0)
    }

    func test_skipNotifications_firesOnAllGranted_whenRequiredGranted() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .granted
        checker.notifStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()   // populates statuses
        var fired = false
        vm.onAllGranted = { fired = true }
        vm.skipNotifications()
        XCTAssertTrue(fired)
    }

    func test_skipNotifications_doesNotFire_whenRequiredPermissionsMissing() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        var fired = false
        vm.onAllGranted = { fired = true }
        vm.skipNotifications()
        XCTAssertFalse(fired)
    }
}
