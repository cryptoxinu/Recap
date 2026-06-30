import SwiftUI
import CallBrainCore

struct ImportView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var raw = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import a call").font(.title2).bold()
            Text("Paste a transcript from Fathom, Fireflies, Cluely, or Google Meet — or any raw dump. "
                 + "CallBrain detects the format, structures it, names it, and indexes it. Unknown formats are resolved by AI.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $raw)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 260)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))

            HStack(spacing: 12) {
                Button { runImport() } label: {
                    Label("Import", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(busy || raw.trimmingCharacters(in: .whitespaces).isEmpty)

                if busy { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Import")
    }

    private func runImport() {
        let text = raw
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !busy else { return }
        Task { await run(text) }
    }

    @MainActor
    private func run(_ text: String) async {
        busy = true
        status = "Resolving format…"
        defer { busy = false }
        do {
            let (outcome, resolved) = try await env.ingest.ingestRaw(text, importer: env.importer)
            let how = resolved.usedAI ? "AI-resolved" : resolved.format.rawValue
            status = "Imported “\(resolved.transcript.title ?? "call")” — \(outcome.chunkCount) chunks (\(how)). Ask AI about it now."
            raw = ""
        } catch {
            status = "Couldn't import: \(error)"
        }
    }
}
