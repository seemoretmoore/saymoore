import SwiftUI
import AppKit

/// Root SwiftUI view for the Settings window. TabView with four tabs:
/// General, Presets, Vocabulary, About. Snippets editor + per-app preset
/// prompt editor are deferred to a v1.1.1 polish pass.
struct SettingsView: View {
    // VM is owned by SettingsWindow (externally), not the view — @ObservedObject
    // matches that ownership. @StateObject would silently retain the original
    // VM across reassignments.
    @ObservedObject var viewModel: SettingsViewModel
    let onOpenPresetsFile: () -> Void
    let onReloadPresets: () -> Void
    let onCheckForPresetUpdates: () -> Void

    var body: some View {
        TabView {
            GeneralPane(viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gearshape") }
            PresetsPane(
                onOpenFile: onOpenPresetsFile,
                onReload: onReloadPresets,
                onCheckUpdates: onCheckForPresetUpdates
            )
            .tabItem { Label("Presets", systemImage: "doc.text") }
            VocabularyPane(viewModel: viewModel)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            AboutPane(viewModel: viewModel)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
        .padding(20)
    }
}

private struct GeneralPane: View {
    @ObservedObject var viewModel: SettingsViewModel
    var body: some View {
        Form {
            Section {
                Toggle("Mute audio chimes", isOn: $viewModel.muted)
                Text("Plays chimes on record start/stop. Takes effect on next app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}

private struct PresetsPane: View {
    let onOpenFile: () -> Void
    let onReload: () -> Void
    let onCheckUpdates: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Presets live in `~/Library/Application Support/SayMoore/presets.json`. Changes hot-reload automatically; no restart needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Open presets.json") { onOpenFile() }
                Button("Reload Presets")     { onReload() }
                Button("Check for Updates…") { onCheckUpdates() }
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}

private struct VocabularyPane: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var selectedRowID: UUID? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Map phonetic spellings Whisper produces (\"FS event stream\") to canonical written forms (\"FSEventStream\"). Applied after every dictation.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Table($viewModel.vocab, selection: $selectedRowID) {
                TableColumn("Phonetic (what Whisper hears)") { $row in
                    TextField("phonetic", text: $row.phonetic)
                        .textFieldStyle(.roundedBorder)
                }
                TableColumn("Canonical (what we paste)") { $row in
                    TextField("canonical", text: $row.canonical)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(minHeight: 200)

            HStack {
                Button("Add row") { viewModel.addVocabRow() }
                Button("Remove selected") {
                    if let id = selectedRowID, let r = viewModel.vocab.first(where: { $0.id == id }) {
                        viewModel.removeVocabRow(r)
                        selectedRowID = nil
                    }
                }
                .disabled(selectedRowID == nil)
                Spacer()
                Button("Save") {
                    // VM keeps in-memory state authoritative post-save; no
                    // refresh-from-disk needed (would rotate UUIDs and steal
                    // text-field focus).
                    viewModel.commitVocabulary()
                }
                .keyboardShortcut(.defaultAction)
            }
            if let err = viewModel.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 8)
    }
}

private struct AboutPane: View {
    @ObservedObject var viewModel: SettingsViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SayMoore")
                .font(.title2.bold())
            Text("Version \(viewModel.bundleShortVersion) (build \(viewModel.bundleBuild))")
                .foregroundStyle(.secondary)
            Text("Local dictation for macOS. Whisper-large-v3-turbo transcription, Ollama Qwen 2.5 7B cleanup. Everything runs on-device.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link(
                "View on GitHub",
                destination: URL(string: "https://github.com/seemoretmoore/saymoore")!
            )
            Spacer()
        }
        .padding(.top, 8)
    }
}
