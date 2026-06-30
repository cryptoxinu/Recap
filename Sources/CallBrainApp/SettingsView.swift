import SwiftUI
import CallBrainCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var primary: ProviderID = .claude
    @State private var taskReminders = false

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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { primary = env.providerPrimary; taskReminders = NotificationManager.isEnabled }
    }
}
