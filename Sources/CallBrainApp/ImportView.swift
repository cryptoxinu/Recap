import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CallBrainCore

struct ImportView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var raw = ""
    @State private var showPaste = false
    @State private var dropTargeted = false
    @State private var openMeetingID: String?

    private var coordinator: ImportCoordinator { env.importCoordinator }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let err = coordinator.lastError {
                    errorBanner(err).transition(.move(edge: .top).combined(with: .opacity))
                }
                dropZone
                pasteSection
                queueSection
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .topLeading)
            .animation(Theme.smooth, value: coordinator.lastError)
            .animation(Theme.springy, value: coordinator.jobs.count)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Import")
        .sheet(item: $openMeetingID) { id in
            NavigationStack {
                MeetingDetailView(meetingID: id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { openMeetingID = nil }
                    } }
            }
            .frame(minWidth: 720, minHeight: 600)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import a call").font(.title2).bold()
            Text("Drop a Fathom / Fireflies / Cluely / Google-Meet export (or any transcript) below — "
                 + "CallBrain detects the format, structures it, names it, and indexes it. "
                 + "Unknown layouts are resolved by AI and flagged for a quick review.")
                .foregroundStyle(.secondary)
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(msg).font(.callout).foregroundStyle(.primary)
            Spacer()
            Button { coordinator.lastError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.3)))
    }

    // MARK: drop zone + file picker

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 34)).foregroundStyle(Theme.accent.opacity(0.85))
            Text(dropTargeted ? "Release to import" : "Drag transcripts or recordings here")
                .font(.headline)
            Text(".docx · .txt · .srt · .vtt   ·   .mp4 · .mov · .m4a (transcribed on-device)")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { chooseFiles() } label: { Label("Choose files…", systemImage: "doc") }
                    .buttonStyle(.bordered)
                Button { chooseFolder() } label: { Label("Import a folder…", systemImage: "folder") }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1.2, dash: [7, 5]))
            .foregroundStyle(dropTargeted ? Theme.accent : Theme.hairline))
        .animation(.easeInOut(duration: 0.15), value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await coordinator.enqueueFiles(urls) }   // enqueue off-main; accept if any are importable
            return !ImportCoordinator.importable(urls).isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "docx"), .plainText, .json,
                                     .init(filenameExtension: "srt"), .init(filenameExtension: "vtt"),
                                     .init(filenameExtension: "md"), .movie, .audio, .mpeg4Movie,
                                     .init(filenameExtension: "m4a")].compactMap { $0 }
        if panel.runModal() == .OK { let urls = panel.urls; Task { await coordinator.enqueueFiles(urls) } }
    }

    /// Archive migration: pick a folder; recursively enqueue every transcript/recording inside it.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a folder of transcripts and recordings — CallBrain imports them all."
        if panel.runModal() == .OK, let folder = panel.url {
            Task {
                let n = await coordinator.enqueueFolder(folder)
                if n == 0 { coordinator.lastError = "No importable transcripts or recordings found in that folder." }
            }
        }
    }

    // MARK: paste

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { showPaste.toggle() } } label: {
                Label(showPaste ? "Hide paste box" : "…or paste text instead",
                      systemImage: showPaste ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)

            if showPaste {
                VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $raw)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8).frame(height: 200)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardFill))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
                HStack {
                    Button {
                        // Only clear the box once the job is durably queued (MEDIUM-3: never lose paste).
                        let text = raw
                        Task { if await coordinator.enqueuePaste(text) { raw = "" } }
                    } label: {
                        Label("Import pasted text", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    // Trim newlines too so the button disables for newline-only content — matching
                    // enqueuePaste's .whitespacesAndNewlines trim (a newline-only box was a dead control).
                    .disabled(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: queue

    /// "12 of 30 · 2 failed" — a glance at a large folder migration (Phase 7).
    private var queueSummary: String {
        let jobs = coordinator.jobs
        guard jobs.count > 1 else { return "" }
        let done = jobs.filter { $0.state == .done || $0.state == .needsReview }.count
        let failed = jobs.filter { $0.state == .failed }.count
        var s = "\(done) of \(jobs.count)"
        if failed > 0 { s += " · \(failed) failed" }
        return s
    }

    @ViewBuilder private var queueSection: some View {
        if !coordinator.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Import queue").font(.headline)
                    if coordinator.processing {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                    Text(queueSummary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear finished") { Task { await coordinator.clearFinished() } }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(coordinator.jobs) { job in
                        JobRow(job: job,
                               onOpen: { openMeetingID = job.meetingID },
                               onConfirm: { Task { await coordinator.confirmReviewed(job) } },
                               onRemove: { Task { await coordinator.remove(job) } })
                        if job.id != coordinator.jobs.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            }
        }
    }
}

private struct JobRow: View {
    let job: ImportJob
    let onOpen: () -> Void
    let onConfirm: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3).frame(width: 24)
                .symbolEffect(.pulse, isActive: job.state == .running)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title ?? job.sourceName).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(statusLabel).foregroundStyle(tint)
                    if let f = job.format, job.state == .done || job.state == .needsReview {
                        Text("· \(formatLabel(f))").foregroundStyle(.secondary)
                    }
                    if job.chunkCount > 0 { Text("· \(job.chunkCount) chunks").foregroundStyle(.secondary) }
                }
                .font(.caption)
                if let msg = job.message {
                    Text(msg).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            actions
        }
        .padding(12)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if job.state == .needsReview {
                Button("Confirm") { onConfirm() }.buttonStyle(.bordered).controlSize(.small)
            }
            if job.meetingID != nil, job.state == .done || job.state == .needsReview {
                Button("Open") { onOpen() }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            }
            if job.state == .done || job.state == .failed || job.state == .needsReview {
                Button { onRemove() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch job.state {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .needsReview: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
    private var tint: Color {
        switch job.state {
        case .queued: .secondary
        case .running: Theme.accent
        case .done: .green
        case .needsReview: .orange
        case .failed: .red
        }
    }
    private var statusLabel: String {
        switch job.state {
        case .queued: "Queued"
        case .running: "Importing…"
        case .done: "Imported"
        case .needsReview: "Needs review"
        case .failed: "Failed"
        }
    }
    private func formatLabel(_ f: String) -> String {
        switch f {
        case "firefliesJSON": "Fireflies"
        case "firefliesCopy": "Fireflies"
        case "fathom": "Fathom"
        case "geminiNotes": "Gemini notes"
        case "unknown": "AI-resolved"
        default: f
        }
    }
}

// Let a String meeting-id drive a `.sheet(item:)`.
extension String: @retroactive Identifiable { public var id: String { self } }
