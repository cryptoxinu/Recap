import SwiftUI

/// First-run welcome (Phase 8): what CallBrain is, the one honest cloud-generation acknowledgment, and
/// how to get a call in. Shown once (UserDefaults `hasSeenWelcome`).
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let seenKey = "callbrain.hasSeenWelcome"
    @State private var appeared = false
    @State private var ctaHover = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 46)).foregroundStyle(Theme.accent)
            Text("Welcome to CallBrain").font(.largeTitle).bold()
            Text("Your private memory across every work call — search months of meetings, ask questions, "
                 + "and get grounded answers with citations.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 12) {
                row("tray.and.arrow.down", "Import anything", "Drop a Fathom / Fireflies / Google-Meet export, a folder of them, or a raw recording — CallBrain transcribes recordings on-device.")
                row("sparkles", "Ask your calls", "Every answer cites the exact call, speaker, and moment — it refuses rather than guess.")
                row("checklist", "Stay on top of tasks", "Action items are pulled out automatically into a Tasks list.")
                row("lock.shield", "Private by default", "Search, embeddings, and storage stay on your Mac. Answers use your Claude/ChatGPT CLI subscription — relevant transcript excerpts are sent to that cloud service to generate the reply.")
            }
            .frame(maxWidth: 520)
            .padding(.vertical, 4)

            Button {
                markSeen()
                dismiss()
            } label: {
                Text("Get started").font(.headline).frame(maxWidth: 220).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .scaleEffect(reduceMotion ? 1 : (ctaHover ? 1.03 : 1))
            .shadow(color: Theme.accent.opacity(!reduceMotion && ctaHover ? 0.35 : 0), radius: 10, y: 4)
            .animation(reduceMotion ? nil : Theme.springy, value: ctaHover)
            .onHover { ctaHover = $0 }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(minWidth: 620, minHeight: 600)
        .opacity(appeared ? 1 : 0)
        .offset(y: reduceMotion ? 0 : (appeared ? 0 : 14))
        // Respect Reduce Motion: no slide/fade entrance when the user has asked the system to reduce motion.
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
        }
        // Persist "seen" on ANY dismissal (Escape / click-outside), not only the CTA — otherwise the welcome
        // sheet reappears on the next launch when dismissed without tapping "Get started".
        .onDisappear { markSeen() }
    }

    private func markSeen() { UserDefaults.standard.set(true, forKey: Self.seenKey) }

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
