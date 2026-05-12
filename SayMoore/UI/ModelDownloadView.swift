import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var bootstrap: ModelBootstrap
    let onRetry: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("First-run setup")
                .font(.title2)
                .bold()
            Text("Downloading Whisper transcription model (~1.6 GB). This happens once.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch bootstrap.phase {
            case .checking:
                ProgressView("Checking…")
                    .progressViewStyle(.linear)
            case .downloading(let p):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p)
                    Text(percent(p))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            case .verifying:
                ProgressView("Verifying SHA256…")
                    .progressViewStyle(.linear)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let err):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message(for: err), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    HStack {
                        Button("Retry", action: onRetry)
                            .keyboardShortcut(.defaultAction)
                        Button("Quit", action: onQuit)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func percent(_ p: Double) -> String {
        let pct = Int((p * 100).rounded())
        return "\(pct)%"
    }

    private func message(for err: SayMooreError) -> String {
        switch err {
        case .modelCorrupted:
            return "Downloaded file did not match expected SHA256. Try again."
        case .diskFull:
            return "Disk full — free space and retry."
        case .modelMissing:
            return "Could not reach the model download. Check your connection."
        default:
            return "Setup failed: \(err)"
        }
    }
}
