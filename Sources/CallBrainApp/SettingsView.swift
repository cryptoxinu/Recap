import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CallBrainCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var primary: ProviderID = .claude
    @State private var taskReminders = false
    @State private var reminderDenied = false        // macOS notification permission was refused
    @State private var backupStatus: String?
    @State private var backingUp = false
    @State private var restoring = false
    @State private var restoreStaged = false
    @State private var tokenCopied = false            // brief "Copied" confirmation on the pairing token
    // Google Drive setup
    @State private var driveSetupShown = false
    @State private var driveConnecting = false   // single-flight guard for the OAuth round-trip
    @State private var driveClientID = ""
    @State private var driveClientSecret = ""
    // Fathom setup
    @State private var fathomKey = ""
    // Vocabulary (#42) — a new glossary term to teach the transcriber.
    @State private var newTerm = ""
    // Note templates (Granola Phase C) — a new custom template.
    @State private var newTemplateName = ""
    @State private var newTemplateSections = ""
    // Recordings storage (#72) — folder size/count + wipe.
    // Names the user right-clicked → "Not a person" in the People tab (undo surface below).
    @State private var hiddenPeople: [String] = NotPeople.list()
    @State private var recordingsSummary = "…"
    @State private var recordingsEmpty = true
    @State private var showWipeRecordings = false
    // Who "you" are — so the AI can tell which tasks are yours.
    @AppStorage(FounderIdentity.defaultsKey) private var founderNames = ""
    @AppStorage(TeamDomains.overrideKey) private var teamDomains = ""
    // The user's ventures (companies/projects) for call categorization — NOT hardcoded; entered here.
    @State private var ventures: [Venture] = VentureConfig.load()
    @State private var newVentureName = ""
    @State private var newVentureKeywords = ""
    // Deep-answer routing (Task 5.3) — persisted; read at each ask.
    @AppStorage(AppEnvironment.deepAnswersKey) private var deepAnswers = "auto"
    // Local-only mode (Task 9.4) — nothing leaves this Mac.
    @AppStorage(AppEnvironment.localOnlyKey) private var localOnly = false
    // Local summary model (F13: was consumed for live + post-call summaries but had NO UI — the user was
    // permanently locked to the hardcoded qwen2.5:3b even if they'd only pulled a bigger model).
    @AppStorage("callbrain.localSummaryModel") private var localSummaryModel = "qwen2.5:3b"
    // Personal profile (Task 1.4) — catered answers + plain-language jargon glossing.
    @State private var profileRole = ""
    @State private var profileCompany = ""
    @State private var profileFocus = ""
    @State private var profileNote = ""
    @State private var profileRawAbout = ""
    @State private var profileImproving = false
    @State private var profileStatus: String?
    @State private var profileDraft: ProfileEnricher.ProfileDraft?
    @State private var profileSaveTask: Task<Void, Never>?

    /// A settings text field that ALWAYS stacks: label above a full-width, left-aligned field, with an
    /// optional help caption below. macOS grouped Form inlines short labels (pushing the value to the
    /// trailing edge, so it reads right-to-left); `.labelsHidden()` + an explicit label above forces the
    /// natural left-to-right layout uniformly for every field.
    @ViewBuilder
    private func labeledField(_ title: String, text: Binding<String>, prompt: String,
                              help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(Theme.textPrimary)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Ventures (the user's companies/projects) — call categorization is driven by these, entered here
    /// rather than hardcoded, so the shipped app carries no personal company names.
    @ViewBuilder private var venturesSection: some View {
        Section("Ventures (call categories)") {
            Text("Add the companies or projects you take calls for. Recap tags each call to the best "
                 + "match using the keywords you list, so you can filter your meetings by venture. Everything "
                 + "else stays “Other”.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ventures) { v in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(CategoryTag.color(v.id, ventures: ventures)).frame(width: 10, height: 10).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.label).font(.callout.weight(.medium))
                        Text(v.keywords.isEmpty ? "no keywords yet" : v.keywords.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(role: .destructive) { removeVenture(v) } label: {
                        Image(systemName: "trash").font(.system(size: 12))
                    }.buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a venture").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                TextField("Name (e.g. Acme)", text: $newVentureName)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                TextField("Keywords, comma-separated (e.g. widget, gizmo, acme app)", text: $newVentureKeywords)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                    .onSubmit(addVenture)
                HStack {
                    Spacer()
                    Button("Add venture", action: addVenture)
                        .disabled(newVentureName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func addVenture() {
        let name = newVentureName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Audit #5: dedupe keywords so a repeated term ("acme, acme") can't inflate the distinct-term score.
        var seen = Set<String>()
        let keywords = newVentureKeywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        // A keyword-less venture still matches on its own name.
        let kw = keywords.isEmpty ? [name.lowercased()] : keywords
        // Audit #6: a fresh, suffixed id (never a bare reusable slug) so deleting + re-adding a same-named
        // venture can't silently reattribute the old venture's already-tagged calls.
        let id = VentureConfig.freshID(for: name, existing: ventures.map(\.id))
        ventures.append(Venture(id: id, label: name, keywords: kw))
        newVentureName = ""; newVentureKeywords = ""
        persistVentures()
    }

    private func removeVenture(_ v: Venture) {
        ventures.removeAll { $0.id == v.id }
        persistVentures()
    }

    private func persistVentures() {
        VentureConfig.save(ventures)
        env.reloadVentures()          // classifier + filter bar pick up the change without a relaunch
    }

    var body: some View {
        Form {
            Section("You") {
                labeledField("Your name(s)", text: $founderNames, prompt: "e.g. Alex, AJ",
                    help: "Recap is just for you. Enter the name(s) people call you in meetings "
                        + "(comma-separated) so the AI can separate what is directly for you from what "
                        + "is for the broader team.")
                labeledField("Your team's email domain(s)", text: $teamDomains,
                    prompt: "e.g. acme.com, acme-labs.com",
                    help: "Attendee research looks up people on a call who AREN'T on your team. List your "
                        + "own work email domain(s), comma-separated, so teammates are never treated as "
                        + "outside guests. Leave blank and Recap will learn them from your calendar.")
                // F6: don't silently swallow input that parses to nothing (e.g. "acme" with no dot).
                if TeamDomains.overrideHasInvalidOnly(teamDomains) {
                    Label("Use a domain like acme.com — each entry needs a dot (an email like alex@acme.com works too).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            venturesSection
            if !hiddenPeople.isEmpty {
                Section("Hidden from People") {
                    Text("Names you marked “Not a person” by right-clicking in the People tab. They're never "
                         + "listed again. Restore one if you hid it by mistake.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(hiddenPeople, id: \.self) { name in
                        HStack {
                            Text(name).font(.callout)
                            Spacer()
                            Button("Restore") { NotPeople.remove(name); hiddenPeople = NotPeople.list() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Section("About you") {
                labeledField("Role", text: $profileRole, prompt: "e.g. Founder / operator")
                labeledField("Company & context", text: $profileCompany, prompt: "e.g. Acme (what your company does)")
                labeledField("Focus areas (comma-separated)", text: $profileFocus, prompt: "e.g. a product area, a key initiative")
                labeledField("Notes for the AI", text: $profileNote, prompt: "e.g. explain technical jargon plainly and flag direct asks for me")
                VStack(alignment: .leading, spacing: 6) {
                    Text("About me brief")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    CBPlainTextView(text: $profileRawAbout)
                        .frame(minHeight: 100)
                        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(Theme.hairline))
                    HStack {
                        Button {
                            improveProfileWithAI()
                        } label: {
                            Label(profileImproving ? "Improving…" : "Improve profile with AI",
                                  systemImage: "text.badge.checkmark")
                        }
                        .buttonStyle(.cbSecondary)
                        .disabled(profileImproving || profileRawAbout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if profileImproving { ProgressView().controlSize(.small) }
                        if let profileStatus {
                            Text(profileStatus).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                if let draft = profileDraft {
                    VStack(alignment: .leading, spacing: Space.s) {
                        CBSectionHeader(title: "Suggested profile", systemImage: "person.text.rectangle")
                        LabeledContent("Role", value: draft.profile.role)
                        LabeledContent("Context", value: draft.profile.company)
                        if !draft.profile.focusAreas.isEmpty {
                            LabeledContent("Focus", value: draft.profile.focusAreas.joined(separator: ", "))
                        }
                        if !draft.aliases.isEmpty {
                            LabeledContent("Aliases", value: draft.aliases.joined(separator: ", "))
                        }
                        HStack {
                            Button("Apply") { applyProfileDraft() }.buttonStyle(.cbPrimary)
                            Button("Dismiss") { profileDraft = nil; profileStatus = nil }.buttonStyle(.cbSecondary)
                        }
                    }
                    .padding(.top, Space.s)
                }
                Text("Every answer is written FOR this person: jargon gets explained in plain language, "
                     + "and next steps are tailored to your role.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Answers") {
                Toggle("Local-only mode", isOn: $localOnly)
                    .help("Nothing leaves this Mac: answers show your calls' exact moments (no cloud AI writing, no web research). Slower questions, total privacy.")
                Picker("Deep answers (Opus)", selection: $deepAnswers) {
                    Text("Auto — deep for open questions, fast for lists").tag("auto")
                    Text("Always (slower, most thorough)").tag("always")
                    Text("Never (fastest)").tag("never")
                }
                .help("Action items, recaps, and person lookups read just as well from the fast model at a fraction of the wait.")
                Picker("Provider", selection: $primary) {
                    Text("Claude (claude -p)").tag(ProviderID.claude)
                    Text("Codex (codex exec)").tag(ProviderID.codex)
                }
                .onChange(of: primary) { _, new in env.setProviderPrimary(new) }
                Text("Pick which subscription answers first. If it hits a rate limit or is unavailable, "
                     + "Recap automatically falls back to the other — you never get blocked. Relevant "
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
                    Text("Pick a folder (e.g. a Google-Drive-synced “Meet Recordings” folder) and Recap "
                         + "imports new transcripts & recordings automatically as they land — no manual step.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Detect Google Drive “Meet Recordings” folder") { detectDriveFolder() }
                Text("If you run the Google Drive app, this finds where your Google Meet (Gemini) notes sync "
                     + "and watches it automatically — no sign-in needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            calendarsSection
            driveSection
            fathomSection
            Section("Recording") {
                Toggle("Auto-record meetings with a video link", isOn: Binding(
                    get: { env.autoRecorder.isEnabled },
                    set: { env.autoRecorder.setEnabled($0, env: env) }))
                Text("When on, Recap starts recording automatically as a calendar meeting that "
                     + "has a Zoom / Google Meet / Teams link begins, and links the recording to that "
                     + "call. Off by default — audio is transcribed on-device and never leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("More accurate live transcription", isOn: Binding(
                    get: { env.liveTranscriptionAccurate },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: AppEnvironment.liveAccurateKey)
                        env.ensureLiveTranscriptionModel()   // auto-download the newly-chosen model + show status
                    }))
                // One-click + automatic: flipping it on downloads the model in the background and shows the
                // status here, so there's nothing to configure and no silent "did it work?" moment (F3).
                if env.liveTranscriptionAccurate {
                    switch env.liveModelStatus {
                    case .downloading:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Downloading the accurate model (~240 MB, one time)… keep using Recap as "
                                 + "normal — it turns on automatically the moment it's ready.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .ready:
                        Label("Accurate model ready — used for your next recording.", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Theme.success).labelStyle(.titleAndIcon)
                    case .failed:
                        HStack(spacing: 8) {
                            Label("Couldn't download the model — check your connection.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Theme.warning)
                            Button("Retry") { env.ensureLiveTranscriptionModel() }.controlSize(.small)
                        }
                    }
                }
                Text("Uses a larger on-device model for the LIVE in-call transcript — reads real calls better "
                     + "but uses more CPU/battery. The saved transcript is already high-accuracy, and Google "
                     + "Meet calls use captions. It downloads automatically the first time you turn it on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            vocabularySection
            templatesSection
            recordingsSection
            Section("Browser extension") {
                Text("Capture Google Meet calls in Chrome (no bot), record from the toolbar, and ask the AI "
                     + "questions live. Load the Recap extension in Chrome, then click Pair — no copy-paste.")
                    .font(.caption).foregroundStyle(.secondary)
                if let port = env.localServerPort {
                    LabeledContent("Status") {
                        Label("Running · port \(port)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success).labelStyle(.titleAndIcon)
                    }
                    // Pairing is now ONE-CLICK from the extension itself: clicking "Pair with Recap" in
                    // the extension opens `callbrain://pair`, which launches/focuses this app and opens the
                    // pairing window automatically. This button is just a manual fallback.
                    switch env.pairingState {
                    case .idle:
                        Text("Just click **Pair with Recap** in the Chrome extension — it opens this app "
                             + "and connects on its own. Nothing to do here.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            env.startExtensionPairing()
                        } label: {
                            Label("Open pairing window (fallback)", systemImage: "link")
                        }
                        .controlSize(.small)
                    case .waiting:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Ready to pair — the extension is connecting…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .paired:
                        Label("Extension paired", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success).labelStyle(.titleAndIcon)
                    }
                    // Manual fallback (rarely needed): the raw token, if auto-pair can't reach the extension.
                    DisclosureGroup("Pair manually") {
                        HStack(spacing: 8) {
                            Text(env.extensionPairingToken)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 180, alignment: .leading)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(env.extensionPairingToken, forType: .string)
                                tokenCopied = true
                                Task { try? await Task.sleep(for: .seconds(2)); tokenCopied = false }
                            } label: {
                                Label(tokenCopied ? "Copied" : "Copy token",
                                      systemImage: tokenCopied ? "checkmark" : "doc.on.doc")
                            }
                        }
                        Text("Paste into the extension's options along with port \(port).")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Label("The local server isn't running (the port may be in use). Restart Recap to retry.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Section("Reminders") {
                Toggle("Daily action-item reminder", isOn: $taskReminders)
                    .onChange(of: taskReminders) { _, on in
                        Task {
                            await NotificationManager.setEnabled(on, openTaskCount: env.openTaskCountCached)
                            // If the user flipped the toggle AGAIN while the permission request was in flight,
                            // this result is stale — don't reconcile it (audit MED: false "denied" after a
                            // user-initiated OFF). Only act if the toggle still reflects the state we handled.
                            guard taskReminders == on else { return }
                            // Reconcile with the EFFECTIVE state: if permission was denied, setEnabled wrote
                            // the flag back to false — sync the toggle so it doesn't lie (stay ON doing nothing).
                            if on && !NotificationManager.isEnabled {
                                taskReminders = false
                                reminderDenied = true
                            } else if on {
                                reminderDenied = false
                            }
                        }
                    }
                if reminderDenied {
                    Label("Notifications are turned off for Recap. Enable them in System Settings ›"
                          + " Notifications, then try again.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                Text("A once-a-day nudge summarizing how many open action items you have across your calls "
                     + (NotificationManager.available ? "— fires even when Recap is closed."
                        : "(notifications activate in the installed app)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local engine") {
                Picker("Summary model", selection: $localSummaryModel) {
                    Text("qwen2.5:3b — fastest, least memory").tag("qwen2.5:3b")
                    Text("qwen2.5:7b — sharper, more memory").tag("qwen2.5:7b")
                    Text("qwen2.5:14b — best, most memory").tag("qwen2.5:14b")
                }
                Text("The on-device model that writes your local call summaries (live and post-call). Bigger "
                     + "reads better but is slower and uses more memory — and it must be installed first "
                     + "(Terminal: `ollama pull <model>`). Applies to your next summary.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Embeddings", value: "nomic-embed-text (Ollama)")
                LabeledContent("Search", value: "SQLite FTS5 + vector (RRF)")
            }
            Section("Storage") {
                LabeledContent("Data folder", value: (env.dataRoot.path as NSString).abbreviatingWithTildeInPath)
                LabeledContent("Calls indexed", value: "\(env.meetingCount())")
                HStack {
                    Button("Back up…") { backUp() }.disabled(backingUp || restoring)
                    Button("Restore from backup…") { restore() }.disabled(backingUp || restoring)
                    Spacer()
                    if backingUp || restoring { ProgressView().controlSize(.small) }
                    if let s = backupStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
                if restoreStaged {
                    Text("Backup restored — quit and reopen Recap to finish.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                Text("A backup (.cbk) is a complete, encryptable-at-rest copy of all your calls, tasks, and chats.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            corpusSection
        }
        .formStyle(.grouped)
        .animation(Theme.smooth, value: env.fathom.connected)
        .animation(Theme.smooth, value: env.drive.connected)
        .animation(Theme.smooth, value: env.autoImport.folderPath)
        .animation(Theme.smooth, value: env.corpus.status.enabled)
        .navigationTitle("Settings")
        .onAppear {
            primary = env.providerPrimary; taskReminders = NotificationManager.isEnabled
            loadProfile()
            hiddenPeople = NotPeople.list()
            env.ensureLiveTranscriptionModel()   // refresh the accurate-model status (and auto-fetch if needed)
            if env.drive.connected, env.drive.availableFolders.isEmpty {
                Task { await env.drive.loadFolders() }
            }
        }
        .onChange(of: localOnly) { _, _ in
            // Local-only is a real egress gate: (un)install the corpus sync LaunchAgent to match, and warm
            // the transcription-model status for the (possibly) newly-relevant model.
            Task { await env.corpus.reconcileLocalOnly() }
        }
        .onChange(of: profileRole) { saveProfile() }
        .onChange(of: profileCompany) { saveProfile() }
        .onChange(of: profileFocus) { saveProfile() }
        .onChange(of: profileNote) { saveProfile() }
        .onChange(of: profileRawAbout) { scheduleProfileSave() }
        .onDisappear {
            profileSaveTask?.cancel()
            saveProfile()
        }
    }

    private func loadProfile() {
        let p = PersonalProfile.load()
        profileRole = p.role; profileCompany = p.company
        profileFocus = p.focusAreas.joined(separator: ", "); profileNote = p.expertiseNote
        profileRawAbout = p.rawAbout
    }

    /// Field edits persist immediately (a non-coder won't hunt for a Save button); `extras`
    /// (Task 8.6 auto-enrichment) is preserved untouched.
    private func saveProfile() {
        var p = PersonalProfile.load()
        p.role = profileRole
        p.company = profileCompany
        p.focusAreas = profileFocus.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.expertiseNote = profileNote
        p.rawAbout = profileRawAbout
        p.save()
    }

    private func scheduleProfileSave() {
        profileSaveTask?.cancel()
        profileSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            saveProfile()
        }
    }

    private func improveProfileWithAI() {
        let raw = profileRawAbout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !profileImproving else { return }
        profileImproving = true
        profileStatus = nil
        profileDraft = nil
        let current = PersonalProfile.load()
        let aliases = FounderIdentity.aliases
        Task { @MainActor in
            do {
                let json = try await env.router.completeJSON(
                    prompt: ProfileEnricher.profileDraftPrompt(rawAbout: raw, current: current, aliases: aliases),
                    system: "You structure one user's profile for a meeting-memory app. JSON only.",
                    schema: ProfileEnricher.profileDraftSchema,
                    model: "sonnet",
                    timeout: 90)
                let draft = try ProfileEnricher.parseProfileDraft(json, rawAbout: raw)
                profileDraft = draft
                profileStatus = "Review before applying."
            } catch {
                profileStatus = "Could not improve profile. Check the AI engine and try again."
            }
            profileImproving = false
        }
    }

    private func applyProfileDraft() {
        guard let draft = profileDraft else { return }
        // F8: the AI draft never sees the user's saved `extras` (they aren't fed to the model), so saving it
        // wholesale would WIPE them (unlike manual save, which preserves them). Carry current extras forward,
        // and APPEND only genuinely-new aliases to the name field rather than replacing what the user typed.
        var merged = draft.profile
        merged.extras = PersonalProfile.load().extras
        merged.save()
        if !draft.aliases.isEmpty {
            let existing = Set(FounderIdentity.aliases)
            let newOnes = draft.aliases.filter { !existing.contains($0.lowercased()) }
            if !newOnes.isEmpty {
                let base = founderNames.trimmingCharacters(in: .whitespaces)
                founderNames = base.isEmpty ? newOnes.joined(separator: ", ")
                                            : base + ", " + newOnes.joined(separator: ", ")
            }
        }
        profileDraft = nil
        profileStatus = "Profile updated."
        loadProfile()
    }

    @ViewBuilder private var vocabularySection: some View {
        Section("Vocabulary (transcript accuracy)") {
            Text("Crypto & company terms Recap listens for, so they're transcribed correctly at the "
                 + "source — like Otter's custom vocabulary. Add your own here, or right-click a word in "
                 + "any transcript to fix it. Learned instantly, no re-training.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Add a term (a product, company, or piece of jargon)", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let corrections = env.corrections.entries.filter { $0.origin != .seed }
            if !corrections.isEmpty {
                DisclosureGroup("Your corrections (\(corrections.count))") {
                    ForEach(corrections) { e in
                        HStack {
                            Text("“\(e.wrong)”").foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(e.right)
                            Spacer()
                            Button(role: .destructive) {
                                env.updateCorrections { $0.removingEntry(id: e.id) }
                            } label: { Image(systemName: "trash").font(.caption) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    env.recorrectEntireLibrary()
                } label: {
                    HStack(spacing: 5) {
                        if env.recorrectingLibrary { ProgressView().controlSize(.small) }
                        Text(env.recorrectingLibrary ? "Re-correcting…" : "Re-correct my library")
                    }
                }
                .disabled(env.recorrectingLibrary || env.corrections.entries.isEmpty)
                Text("Apply your corrections to ALL past calls so old transcripts + search catch up.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Text("\(env.corrections.watchlist.count) glossary terms · \(env.corrections.entries.count) corrections")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func addTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        env.updateCorrections { $0.addingWatch(t) }
        newTerm = ""
    }

    @ViewBuilder private var recordingsSection: some View {
        Section("Recordings storage") {
            Text("All your recorded meeting audio is saved in ONE folder. Your transcripts, notes, and "
                 + "meetings live in the app database and are NOT affected if you clear this.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(RecordingStorage.directory().path)
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([RecordingStorage.directory()])
                }
            }
            HStack {
                Text(recordingsSummary).font(.callout)
                Spacer()
                Button("Clear all recordings…", role: .destructive) { showWipeRecordings = true }
                    .disabled(recordingsEmpty || env.recording.phase != .idle)   // never wipe mid-record
            }
            if env.recording.phase != .idle {
                Text("Finish the current recording before clearing.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .task { refreshRecordingsSummary() }
        .confirmationDialog("Delete all recorded audio?", isPresented: $showWipeRecordings, titleVisibility: .visible) {
            Button("Delete all recordings", role: .destructive) {
                // Protect audio still backing a not-yet-done import (so Retry keeps working) — audit HIGH.
                // Query the DURABLE store, not the in-memory jobs list (which is capped at the newest 100,
                // so a failed import beyond that window would otherwise lose its audio — audit F10). Fall
                // back to the in-memory set only if the query fails.
                let protected = (try? env.store.protectedImportPayloads())
                    ?? Set(env.importCoordinator.jobs
                        .filter { $0.state != .done && $0.payloadKind == .file }
                        .compactMap { $0.payload })
                _ = RecordingStorage.clearAll(protecting: protected)
                refreshRecordingsSummary()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes recorded audio files to free up space. Your transcripts, notes, "
                 + "and meetings are kept, and any recording still waiting to import (or a failed one you "
                 + "can Retry) is preserved.")
        }
    }

    private func refreshRecordingsSummary() {
        let n = RecordingStorage.count()
        recordingsEmpty = n == 0
        recordingsSummary = "\(n) recording\(n == 1 ? "" : "s") · \(RecordingStorage.formattedSize())"
    }

    @ViewBuilder private var templatesSection: some View {
        Section("AI note templates") {
            Text("Shape how the AI structures your live meeting notes by the kind of call — like Granola. "
                 + "Pick a default; you can also switch per-recording in the record window.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Default template", selection: Binding(
                get: { env.noteTemplates.defaultID },
                set: { id in env.updateTemplates { $0.settingDefault(id: id) } })) {
                ForEach(env.noteTemplates.all) { t in
                    Label(t.name, systemImage: t.icon).tag(t.id)
                }
            }
            let custom = env.noteTemplates.custom
            if !custom.isEmpty {
                DisclosureGroup("Your templates (\(custom.count))") {
                    ForEach(custom) { t in
                        HStack {
                            Text(t.name)
                            Text(t.instructions).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                env.updateTemplates { $0.removingCustom(id: t.id) }
                            } label: { Image(systemName: "trash").font(.caption) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("New template name (e.g. Board meeting)", text: $newTemplateName)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                HStack {
                    TextField("Sections, separated by ; (e.g. Updates; Decisions; Risks)", text: $newTemplateSections)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                    Button("Add", action: addTemplate)
                        .disabled(newTemplateName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newTemplateSections.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addTemplate() {
        let name = newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections = newTemplateSections.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !sections.isEmpty else { return }
        // A stable id from the name; fall back for non-ASCII names, and append a numeric suffix until it's
        // UNIQUE so two "Board meeting"s (or unicode collisions) don't silently overwrite each other.
        var base = "custom_" + name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.isEmpty || base == "custom" { base = "custom_template" }
        let existing = Set(env.noteTemplates.all.map(\.id))
        var slug = base, n = 2
        while existing.contains(slug) { slug = "\(base)_\(n)"; n += 1 }
        let t = NoteTemplate(id: slug, name: name, icon: "doc.text", instructions: sections)
        env.updateTemplates { $0.upserting(t) }
        newTemplateName = ""; newTemplateSections = ""
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
                Text("New Fathom calls import automatically in the background (about every 30 minutes, and "
                     + "whenever you reopen Recap) — "
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
                     + "paste it here. Recap then pulls in every new Fathom call on its own — no exporting, "
                     + "no folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Founder: "I don't see add gmail accounts in settings at all?" — calendar accounts get
    /// a visible home. macOS Internet Accounts is the primary path (covers Google/iCloud/
    /// Exchange incl. work accounts); direct Google is the no-macOS-account alternative.
    @ViewBuilder private var calendarsSection: some View {
        let hub = env.calendarHub
        Section("Calendars") {
            LabeledContent("macOS Calendar") {
                switch hub.eventKitState {
                case .some(.some(true)):
                    Text(hub.calendarNames.isEmpty ? "Connected"
                         : "\(hub.calendarNames.count) calendars connected")
                case .some(.some(false)):
                    Text("Access denied — enable in Privacy & Security").foregroundStyle(Theme.warning)
                default:
                    Text("Not connected — open the Calendar tab to connect")
                }
            }
            Button("Add account (Google, iCloud, Exchange)…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
            }
            Text("Accounts you add to macOS (System Settings → Internet Accounts) show up in "
                 + "Recap automatically — the easiest way to add a Gmail or work Google "
                 + "Workspace calendar, and how recorded work meetings get linked to transcripts.")
                .font(.caption).foregroundStyle(.secondary)
            if hub.googleConfigured {
                ForEach(hub.googleAccounts) { account in
                    HStack {
                        Label(account.display, systemImage: "g.circle")
                        Spacer()
                        Button("Disconnect", role: .destructive) {
                            Task { await hub.disconnectGoogle(account) }
                        }
                        .controlSize(.small)
                    }
                }
                Button(hub.googleAccounts.isEmpty ? "Connect Google Calendar directly…"
                                                  : "Add another Google account…") {
                    Task { await hub.connectGoogle() }
                }
                if let status = hub.googleStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Text("Direct connection (read-only) for Google accounts you'd rather not add "
                     + "to macOS Calendar. Each account connects separately.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The direct Google Calendar connection shares Google Drive's OAuth client "
                     + "— set up Google Drive sync below to enable it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            await hub.probe()
            await hub.probeGoogle()
        }
    }

    @ViewBuilder private var driveSection: some View {
        Section("Google Drive (cloud sync)") {
            let drive = env.drive!
            if drive.connected {
                LabeledContent("Folder") {
                    Menu(drive.folderName ?? "Choose a folder…") {
                        if drive.foldersLoading {
                            Button("Loading folders…") {}.disabled(true)
                        } else if drive.foldersError {
                            Button("Couldn't load — retry") { Task { await drive.loadFolders() } }
                        } else if drive.availableFolders.isEmpty {
                            Button("Load my folders…") { Task { await drive.loadFolders() } }
                        }
                        ForEach(drive.availableFolders) { f in
                            Button(f.name) { drive.selectFolder(f) }
                        }
                    }
                    .disabled(drive.foldersLoading)
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
                HStack(spacing: 8) {
                    // Single-flight: OAuth is a multi-second round-trip; without this the button
                    // stayed live and a second click launched a second flow (audit G3 MED).
                    Button("Connect Google Drive…") {
                        driveConnecting = true
                        Task { await drive.connect(); driveConnecting = false }
                    }
                    .disabled(driveConnecting)
                    if driveConnecting { ProgressView().controlSize(.small) }
                }
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
            TextField("Client ID", text: $driveClientID).textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
            SecureField("Client secret", text: $driveClientSecret).textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
            HStack {
                Spacer()
                Button("Cancel") { driveSetupShown = false }
                Button("Save") {
                    let id = driveClientID, secret = driveClientSecret
                    Task { await env.drive.configure(clientID: id, clientSecret: secret) }
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

    // MARK: Call corpus (Part B) — export every call to a folder that syncs to the founder's server bot.

    private var corpusSection: some View {
        Section("Call corpus") {
            Toggle("Export every call to a folder", isOn: Binding(
                get: { env.corpus.status.enabled },
                set: { env.corpus.setEnabled($0) }))
            if env.corpus.status.enabled {
                LabeledContent("Folder") {
                    Text((env.corpus.folderURL.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose folder…") { pickCorpusFolder() }
                    Button("Export all now") { Task { await env.corpus.exportAll(force: true) } }
                        .disabled(env.corpus.status.isExporting)
                    Button("Reveal in Finder") { env.corpus.revealInFinder() }
                    Spacer()
                    if env.corpus.status.isExporting { ProgressView().controlSize(.small) }
                }
                Text(corpusStatusLine).font(.caption).foregroundStyle(.secondary)
                if let err = env.corpus.status.lastError {
                    Text(err).font(.caption).foregroundStyle(Theme.danger)
                }
                Text("Every call — its summary and full transcript — is written as a clean file (one per "
                     + "call) into this folder. The folder copies automatically over your private Tailscale "
                     + "network to your server Mac, where your assistant bot (hermes) reads and indexes them. "
                     + "Files are overwritten in place; deleting a call in Recap deletes its file there too.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Write every call — summary and full transcript — as a clean file per call into a folder "
                     + "that syncs to your server Mac for your assistant bot (hermes). Off by default; nothing "
                     + "leaves your Mac until you turn this on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var corpusStatusLine: String {
        let s = env.corpus.status
        let calls = "\(s.exportedCount) call\(s.exportedCount == 1 ? "" : "s") exported"
        guard let last = s.lastExport else { return calls }
        return "\(calls) · last export \(last.formatted(date: .omitted, time: .shortened))"
    }

    private func pickCorpusFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        panel.message = "Choose where Recap writes your call corpus (this folder syncs to your server Mac)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        env.corpus.setFolder(url)
    }

    private func pickWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Pick a folder Recap should watch for new calls (e.g. your Google-Drive “Meet Recordings” folder)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        env.autoImport.setFolder(url)
    }

    private var cbkType: UTType { UTType(filenameExtension: "cbk") ?? .data }

    private func backUp() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [cbkType]
        panel.nameFieldStringValue = "Recap-\(TimeCode.ymd(Date())).cbk"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Run the full-copy OFF the main thread (a large .cbk beachballs the window otherwise) — show a
        // spinner + "Backing up…" while it runs, then report the result back on the main actor.
        let store = env.store
        backingUp = true
        backupStatus = "Backing up…"
        Task {
            let result: Result<Void, Error> = await Task.detached {
                do { try store.backup(to: url); return .success(()) } catch { return .failure(error) }
            }.value
            backingUp = false
            switch result {
            case .success: backupStatus = "Backed up."
            case .failure(let error): backupStatus = "Backup failed: \(error.localizedDescription)"
            }
        }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [cbkType]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Validate + copy OFF the main thread (a large .cbk beachballs the window otherwise) with a spinner.
        restoring = true
        backupStatus = "Preparing restore…"
        Task {
            let ok = await env.stageRestoreAsync(from: url)
            restoring = false
            if ok { restoreStaged = true; backupStatus = nil }
            else { backupStatus = "That isn't a valid Recap backup." }
        }
    }
}
