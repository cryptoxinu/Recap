import SwiftUI
import CallBrainCore

/// First-run welcome (Phase 8): what Recap is, the one honest cloud-generation acknowledgment, and
/// how to get a call in. Shown once (UserDefaults `hasSeenWelcome`).
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let seenKey = "callbrain.hasSeenWelcome"
    @State private var appeared = false
    @State private var ctaHover = false
    @State private var status = SystemStatus()   // Task 9.3 — live engine checks
    @State private var pulling = false
    @State private var showCLIHelp = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 46)).foregroundStyle(Theme.accent)
            Text("Welcome to Recap").font(.largeTitle).bold()
            Text("Your private memory across every work call — search months of meetings, ask questions, "
                 + "and get grounded answers with citations.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 12) {
                row("tray.and.arrow.down", "Import anything", "Drop a Fathom / Fireflies / Google-Meet export, a folder of them, or a raw recording — Recap transcribes recordings on-device.")
                row(CBIcon.ask, "Ask your calls", "Every answer cites the exact call, speaker, and moment — it refuses rather than guess.")
                row("checklist", "Stay on top of tasks", "Action items are pulled out automatically into a Tasks list.")
                row("lock.shield", "Private by default", "Search, embeddings, and storage stay on your Mac. Answers use your Claude/ChatGPT CLI subscription — relevant transcript excerpts are sent to that cloud service to generate the reply.")
            }
            .frame(maxWidth: 520)
            .padding(.vertical, 4)

            // Task 9.3 — zero-Terminal setup: live checks + one-click fixes, right in the welcome.
            VStack(alignment: .leading, spacing: 8) {
                Text("Engine check").font(.headline)
                checkRow(ok: status.snap.loaded ? status.snap.ollamaOK : nil,
                         "Local AI (Ollama)",
                         fixTitle: "Get Ollama") {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!)
                }
                if status.snap.loaded, status.snap.ollamaOK, !status.hasModel("nomic-embed-text") {
                    checkRow(ok: pulling ? nil : false, "Search model (nomic-embed-text)",
                             fixTitle: pulling ? "Downloading…" : "Download") { pullModels() }
                }
                checkRow(ok: status.snap.loaded ? (status.snap.claudeOK || status.snap.codexOK) : nil,
                         "Answer engine (Claude or Codex CLI)",
                         fixTitle: "How to sign in") { showCLIHelp = true }
            }
            .frame(maxWidth: 520)
            .padding(Space.m)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.surfaceSunken))
            .popover(isPresented: $showCLIHelp, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect an answer engine").font(.headline)
                    Text("Recap writes answers with your existing AI subscription — no API keys.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("• Claude: install Claude Code, then run “claude” once in Terminal and sign in.\n• ChatGPT: install Codex CLI, then run “codex” once and sign in.")
                        .font(.callout)
                    Text("Recap finds them automatically after that — nothing else to configure.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16).frame(width: 380)
            }

            Button {
                markSeen()
                dismiss()
            } label: {
                Text("Get started").font(.headline).frame(maxWidth: 220).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            // Restrained native hover — no violet glow (it blooms in dark); a tiny lift + neutral shadow.
            .scaleEffect(reduceMotion ? 1 : (ctaHover ? 1.015 : 1))
            .shadow(color: .black.opacity(!reduceMotion && ctaHover ? 0.15 : 0), radius: 8, y: 3)
            .animation(reduceMotion ? nil : Theme.springy, value: ctaHover)
            .onHover { ctaHover = $0 }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(minWidth: 620, minHeight: 600)
        .opacity(appeared ? 1 : 0)
        .offset(y: reduceMotion ? 0 : (appeared ? 0 : 14))
        // Respect Reduce Motion: no slide/fade entrance when the user has asked the system to reduce motion.
        .task { await status.refresh() }
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
        }
        // Persist "seen" on ANY dismissal (Escape / click-outside), not only the CTA — otherwise the welcome
        // sheet reappears on the next launch when dismissed without tapping "Get started".
        .onDisappear { markSeen() }
    }

    private func markSeen() { UserDefaults.standard.set(true, forKey: Self.seenKey) }

    /// One row of the engine check: green ✓ / red ✗ + a one-click fix (Task 9.3).
    @ViewBuilder private func checkRow(ok: Bool?, _ title: String, fixTitle: String, fix: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            if let ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? Theme.success : Theme.danger)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(title).font(.callout)
            Spacer()
            if ok == false {
                Button(fixTitle, action: fix).buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    /// Pull the required models via Ollama's API (progress = spinner; simple by design).
    private func pullModels() {
        pulling = true
        Task {
            for model in ["nomic-embed-text", "qwen2.5:3b"] {
                var req = URLRequest(url: SystemStatus.ollamaBase.appendingPathComponent("api/pull"))
                req.httpMethod = "POST"
                req.timeoutInterval = 600
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": model, "stream": false])
                _ = try? await URLSession.shared.data(for: req)
            }
            await status.refresh()
            pulling = false
        }
    }

    private func row(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
