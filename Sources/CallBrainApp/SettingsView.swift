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
    // Google Drive setup
    @State private var driveSetupShown = false
    @State private var driveClientID = ""
    @State private var driveClientSecret = ""
    // Fathom setup
    @State private var fathomKey = ""

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
                Button("Detect Google Drive “Meet Recordings” folder") { detectDriveFolder() }
                Text("If you run the Google Drive app, this finds where your Google Meet (Gemini) notes sync "
                     + "and watches it automatically — no sign-in needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            driveSection
            fathomSection
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
        .onAppear {
            primary = env.providerPrimary; taskReminders = NotificationManager.isEnabled
            if env.drive.connected, env.drive.availableFolders.isEmpty {
                Task { await env.drive.loadFolders() }
            }
        }
    }

    @ViewBuilder private var fathomSection: some View {
        Section("Fathom (auto-import calls)") {
            let f = env.fathom!
            if f.connected {
                HStack {
                    Button(f.syncing ? "Importing…" : "Sync now") { Task { await f.syncNow() } }
                        .disabled(f.syncing)
                    Button("Disconnect", role: .destructive) { f.disconnect() }
                    Spacer()
                    if f.lastSyncCount > 0 {
                        Text("\(f.lastSyncCount) imported this session").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !f.status.isEmpty { Text(f.status).font(.caption).foregroundStyle(.secondary) }
                Text("New Fathom calls import automatically in the background (about every 15 minutes) — "
                     + "transcript + attendees, run through summaries, tasks, and categories. No per-call step.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                SecureField("Fathom API key", text: $fathomKey).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect Fathom") {
                        let k = fathomKey; fathomKey = ""
                        Task { await env.fathom.connect(apiKey: k) }
                    }
                    .buttonStyle(.borderedProminent).disabled(fathomKey.isEmpty)
                    Spacer()
                }
                if !f.status.isEmpty { Text(f.status).font(.caption).foregroundStyle(.secondary) }
                Text("Get a free key in Fathom → Settings → Integrations → API Access → Generate API Key, then "
                     + "paste it here. CallBrain then pulls in every new Fathom call on its own — no exporting, "
                     + "no folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var driveSection: some View {
        Section("Google Drive (cloud sync)") {
            let drive = env.drive!
            if drive.connected {
                LabeledContent("Folder") {
                    Menu(drive.folderName ?? "Choose a folder…") {
                        if drive.availableFolders.isEmpty {
                            Button("Load my folders…") { Task { await drive.loadFolders() } }
                        }
                        ForEach(drive.availableFolders) { f in
                            Button(f.name) { drive.selectFolder(f) }
                        }
                    }
                }
                Toggle("Also import files shared with me", isOn: Binding(
                    get: { drive.includeShared }, set: { drive.includeShared = $0 }))
                Text("Catches Gemini notes & recordings a meeting host shared with you (when you're not the host) "
                     + "— they don't land in your own folders.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(drive.syncing ? "Syncing…" : "Sync now") { Task { await drive.syncNow() } }
                        // Allow a manual sync for a folder OR a shared-with-me-only setup (no folder chosen).
                        .disabled(drive.syncing || (drive.folderName == nil && !drive.includeShared))
                    Button("Disconnect", role: .destructive) { drive.disconnect() }
                    Spacer()
                    if drive.lastSyncCount > 0 {
                        Text("\(drive.lastSyncCount) imported this session").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !drive.status.isEmpty { Text(drive.status).font(.caption).foregroundStyle(.secondary) }
            } else if drive.isConfigured {
                Button("Connect Google Drive…") { Task { await drive.connect() } }
                Button("Change OAuth client") { driveSetupShown = true }
                if !drive.status.isEmpty { Text(drive.status).font(.caption).foregroundStyle(.secondary) }
            } else {
                Button("Set up Google Drive sync…") { driveSetupShown = true }
                Text("Pull your Google Meet notes & transcripts straight from Drive — no desktop app needed. "
                     + "One-time setup: create a free Google OAuth client (≈5 min, see docs/GOOGLE-DRIVE-SETUP.md). "
                     + "For zero setup, use “Detect Google Drive folder” above instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $driveSetupShown) { driveSetupSheet }
    }

    private var driveSetupSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Google Drive").font(.title2).bold()
            Text("Paste your Google OAuth client ID and secret (a “Desktop app” client). The exact steps are "
                 + "in docs/GOOGLE-DRIVE-SETUP.md — it takes about 5 minutes and keeps everything on your account.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Client ID", text: $driveClientID).textFieldStyle(.roundedBorder)
            SecureField("Client secret", text: $driveClientSecret).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { driveSetupShown = false }
                Button("Save") {
                    env.drive.configure(clientID: driveClientID, clientSecret: driveClientSecret)
                    driveClientID = ""; driveClientSecret = ""; driveSetupShown = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(driveClientID.isEmpty || driveClientSecret.isEmpty)
            }
        }
        .padding(24).frame(width: 480)
    }

    private func detectDriveFolder() {
        if let url = GoogleDriveDetect.meetRecordingsFolder() { env.autoImport.setFolder(url) }
        else { pickWatchFolder() }   // none found locally → let them point at it manually
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
