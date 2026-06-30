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
                if let err = coordinator.lastError { errorBanner(err) }
                dropZone
                pasteSection
                queueSection
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .topLeading)
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
            Button { chooseFiles() } label: { Label("Choose files…", systemImage: "folder") }
                .buttonStyle(.bordered)
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
            coordinator.enqueueFiles(urls) > 0
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
        if panel.runModal() == .OK { coordinator.enqueueFiles(panel.urls) }
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
                TextEditor(text: $raw)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8).frame(height: 200)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardFill))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
                HStack {
                    Button {
                        // Only clear the box once the job is durably queued (MEDIUM-3: never lose paste).
                        if coordinator.enqueuePaste(raw) { raw = "" }
                    } label: {
                        Label("Import pasted text", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(raw.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
            }
        }
    }

    // MARK: queue

    @ViewBuilder private var queueSection: some View {
        if !coordinator.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Import queue").font(.headline)
                    if coordinator.processing {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                    Spacer()
                    Button("Clear finished") { coordinator.clearFinished() }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(coordinator.jobs) { job in
                        JobRow(job: job,
                               onOpen: { openMeetingID = job.meetingID },
                               onConfirm: { coordinator.confirmReviewed(job) },
                               onRemove: { coordinator.remove(job) })
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
