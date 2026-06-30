import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CallBrainCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var primary: ProviderID = .claude
    @State private var taskReminders = false
    @State private var backupStatus: String?
    @State private var restoreStaged = false

    var body: some View {
        Form {
            Section("Answers") {
                Picker("Provider", selection: $primary) {
                    Text("Claude (claude -p)").tag(ProviderID.claude)
                    Text("Codex (codex exec)").tag(ProviderID.codex)
                }
                .onChange(of: primary) { _, new in env.setProviderPrimary(new) }
                Text("Pick which subscription answers first. If it hits a rate limit or is unavailable, "
                     + "CallBrain automatically falls back to the other — you never get blocked. Relevant "
                     + "transcript excerpts are sent to the chosen CLI; embeddings, search, and storage stay on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Auto-import") {
                if let folder = env.autoImport.folderPath {
                    LabeledContent("Watching") {
                        Text((folder as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Change folder…") { pickWatchFolder() }
                        Button("Stop watching") { env.autoImport.setFolder(nil) }
                        Spacer()
                        if env.autoImport.importedCount > 0 {
                            Text("\(env.autoImport.importedCount) auto-imported this session").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("New transcripts & recordings dropped into this folder import automatically. "
                         + "Point it at your Google-Drive-synced “Meet Recordings” folder so Gemini notes flow in on their own.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Watch a folder for new calls…") { pickWatchFolder() }
                    Text("Pick a folder (e.g. a Google-Drive-synced “Meet Recordings” folder) and CallBrain "
                         + "imports new transcripts & recordings automatically as they land — no manual step.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Reminders") {
                Toggle("Daily action-item reminder", isOn: $taskReminders)
                    .onChange(of: taskReminders) { _, on in
                        Task { await NotificationManager.setEnabled(on, openTaskCount: env.openTaskCount()) }
                    }
                Text("A once-a-day nudge summarizing how many open action items you have across your calls "
                     + (NotificationManager.available ? "— fires even when CallBrain is closed."
                        : "(notifications activate in the installed app)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local engine") {
                LabeledContent("Embeddings", value: "nomic-embed-text (Ollama)")
                LabeledContent("Search", value: "SQLite FTS5 + vector (RRF)")
            }
            Section("Storage") {
                LabeledContent("Data folder", value: env.dataRoot.path)
                LabeledContent("Calls indexed", value: "\(env.meetingCount())")
                HStack {
                    Button("Back up…") { backUp() }
                    Button("Restore from backup…") { restore() }
                    Spacer()
                    if let s = backupStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
                if restoreStaged {
                    Text("Backup restored — quit and reopen CallBrain to finish.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("A backup (.cbk) is a complete, encryptable-at-rest copy of all your calls, tasks, and chats.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { primary = env.providerPrimary; taskReminders = NotificationManager.isEnabled }
    }

    private func pickWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Pick a folder CallBrain should watch for new calls (e.g. your Google-Drive “Meet Recordings” folder)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        env.autoImport.setFolder(url)
    }

    private var cbkType: UTType { UTType(filenameExtension: "cbk") ?? .data }

    private func backUp() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [cbkType]
        panel.nameFieldStringValue = "CallBrain-\(TimeCode.ymd(Date())).cbk"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try env.backup(to: url); backupStatus = "Backed up." }
        catch { backupStatus = "Backup failed: \(error.localizedDescription)" }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [cbkType]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if env.stageRestore(from: url) { restoreStaged = true; backupStatus = nil }
        else { backupStatus = "That isn't a valid CallBrain backup." }
    }
}
