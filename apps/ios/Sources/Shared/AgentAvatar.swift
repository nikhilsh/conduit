import SwiftUI
import UIKit

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
    @Environment(\.neonTheme) private var neon

    var body: some View {
        ZStack {
            if let asset = AgentAvatar.logoAsset(forAgent: assistant) {
                // Real brand logo on a white disc: the marks are designed
                // for a light background, so without this the black Codex
                // knot is invisible on the dark sheet (device feedback).
                // Padding keeps the mark off the rim.
                Circle().fill(Color.white)
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.16)
            } else {
                Circle()
                    .fill(neon.agentTint(forAgent: assistant))
                if let symbol = AgentAvatar.symbol(forAgent: assistant) {
                    // Claude / Codex get a distinctive brand glyph; other
                    // agents keep the monogram.
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundStyle(SweKittyTheme.textOnAccent)
                        .accessibilityHidden(true)
                } else {
                    Text(monogram)
                        .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(SweKittyTheme.textOnAccent)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(SweKittyTheme.textOnAccent.opacity(0.15), lineWidth: 0.5)
        )
        .accessibilityLabel(Text(assistant.capitalized))
    }

    /// Real brand-logo asset name for an agent, if the app owner has
    /// bundled the official artwork. Returns nil when no asset is present
    /// in the catalog (looked up at runtime) — the avatar then degrades to
    /// [symbol] / [monogram], so a missing asset never breaks the build.
    /// The artwork itself is supplied by the app owner under the trademark
    /// attribution shipped in the Licenses screen — we don't bundle it here.
    static func logoAsset(forAgent assistant: String) -> String? {
        let name: String
        switch assistant.lowercased() {
        case "claude": name = "ClaudeMark"
        case "codex":  name = "CodexMark"
        default:       return nil
        }
        return UIImage(named: name) != nil ? name : nil
    }

    /// Per-agent brand glyph as an SF Symbol name. Claude → a sparkle,
    /// Codex → the code-brackets mark. Returns nil for agents we don't
    /// have a glyph for (they fall back to [monogram]). We use neutral
    /// system symbols rather than shipping Anthropic / OpenAI logo
    /// artwork in the bundle.
    static func symbol(forAgent assistant: String) -> String? {
        switch assistant.lowercased() {
        case "claude": return "sparkle"
        case "codex":  return "chevron.left.forwardslash.chevron.right"
        default:       return nil
        }
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
