import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section("Answers") {
                LabeledContent("Provider", value: "Claude (claude -p)")
                Text("Answers use your Claude/ChatGPT CLI subscription (a cloud service); relevant transcript excerpts are sent there. Embeddings, search, and storage stay on your Mac.")
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
    }
}
