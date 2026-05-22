import SwiftUI

/// Small circular avatar for an agent (claude, codex, hermes, pi,
/// opencode). Used in any place that lists or picks agents — the
/// `AgentPickerSheet` rows, the `ThreadSwitcherSheet` peek strip and
/// row list, and the `SessionInfoView` hero. Not used inside the
/// chat composer or the header pill — those are already tinted via
/// `SweKittyTheme.accent(forAgent:)` directly.
///
/// Renders a single-letter monogram (Claude → "C", Codex → "X", …)
/// on a filled disc using `accentStrong(forAgent:)`. Falling back to
/// a letter rather than a logo means we don't ship third-party brand
/// marks (no Anthropic / OpenAI artwork in the bundle) and the
/// avatar works for any agent the harness exposes even when we
/// don't have an SF Symbol ready.
struct AgentAvatar: View {
    let assistant: String
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .fill(SweKittyTheme.accentStrong(forAgent: assistant))
            Text(monogram)
                .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                .foregroundStyle(SweKittyTheme.textOnAccent)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
        .overlay(
            Circle()
                .strokeBorder(SweKittyTheme.textOnAccent.opacity(0.15), lineWidth: 0.5)
        )
        .accessibilityLabel(Text(assistant.capitalized))
    }

    /// Per-agent monogram. Codex breaks the "first letter" pattern —
    /// "C" already belongs to Claude, so Codex gets "X" (its OpenAI
    /// internal codename rendered as "Codex eXecution" — and visually
    /// distinct from C). Everything else is the first letter.
    private var monogram: String {
        switch assistant.lowercased() {
        case "claude":   return "C"
        case "codex":    return "X"
        case "hermes":   return "H"
        case "pi":       return "π"
        case "opencode": return "O"
        default:
            return String(assistant.prefix(1)).uppercased()
        }
    }
}

#Preview("Agent avatars") {
    HStack(spacing: 12) {
        AgentAvatar(assistant: "claude")
        AgentAvatar(assistant: "codex")
        AgentAvatar(assistant: "hermes")
        AgentAvatar(assistant: "pi")
        AgentAvatar(assistant: "opencode")
        AgentAvatar(assistant: "unknown")
    }
    .padding()
}
