// SayMoore/UI/PermissionsWizardView.swift
import SwiftUI
import AppKit

struct PermissionsWizardView: View {
    @ObservedObject var viewModel: PermissionsViewModel
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Grant Permissions")
                .font(.title2)
                .bold()
                .padding(.bottom, 4)
            Text("SayMoore needs these permissions to work.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    label: "Microphone",
                    reason: "To capture your voice for transcription.",
                    status: viewModel.statuses.microphone,
                    deeplink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    isActive: viewModel.statuses.currentStep == 1,
                    isSkippable: false,
                    onManual: { Task { await viewModel.recheck() } },
                    onSkip: nil
                )
                PermissionRow(
                    label: "Accessibility",
                    reason: "To detect your Ctrl+Ctrl hotkey.",
                    status: viewModel.statuses.accessibility,
                    deeplink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    isActive: viewModel.statuses.currentStep == 2,
                    isSkippable: false,
                    onManual: { Task { await viewModel.recheck() } },
                    onSkip: nil
                )
                PermissionRow(
                    label: "Input Monitoring",
                    reason: "To listen for your keyboard hotkey globally.",
                    status: viewModel.statuses.inputMonitoring,
                    deeplink: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                    isActive: viewModel.statuses.currentStep == 3,
                    isSkippable: false,
                    onManual: { Task { await viewModel.recheck() } },
                    onSkip: nil
                )
                PermissionRow(
                    label: "Notifications (optional)",
                    reason: "To show transcription status and error alerts.",
                    status: viewModel.statuses.notifications,
                    deeplink: "x-apple.systempreferences:com.apple.preference.notifications",
                    isActive: viewModel.statuses.currentStep == 4,
                    isSkippable: true,
                    onManual: { Task { await viewModel.recheck() } },
                    onSkip: { viewModel.skipNotifications() }
                )
            }

            Spacer(minLength: 20)

            HStack {
                Spacer()
                Button("Quit", action: onQuit)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}

private struct PermissionRow: View {
    let label: String
    let reason: String
    let status: PermissionStatus
    let deeplink: String
    let isActive: Bool
    let isSkippable: Bool
    let onManual: () -> Void
    let onSkip: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? .primary : (status == .granted ? .secondary : .primary))

                if isActive {
                    Text(status == .denied
                        ? "You previously denied this. Open Settings to re-enable it."
                        : reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Open Settings") {
                            if let url = URL(string: deeplink) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .keyboardShortcut(.defaultAction)

                        if isSkippable {
                            Button("Skip for now") { onSkip?() }
                        } else {
                            Button("Check Again") { onManual() }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .imageScale(.large)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .imageScale(.large)
        case .notDetermined:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .imageScale(.large)
        }
    }
}
