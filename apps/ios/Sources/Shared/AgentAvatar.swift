import SwiftUI
import UIKit

/// Small circular avatar for an agent (claude, codex, hermes, pi,
/// opencode). Used in any place that lists or picks agents — the
/// `AgentPickerSheet` rows, the `ThreadSwitcherSheet` peek strip and
/// row list, and the `SessionInfoView` hero. Not used inside the
/// chat composer or the header pill — those are already tinted via
/// `ConduitTheme.accent(forAgent:)` directly.
///
/// Renders the real brand mark (or an SF Symbol / monogram fallback)
/// tinted in the agent's theme color over a tint-at-18%-opacity disc,
/// with a solid-tint ring -- the `AgentDot` idiom (see
/// `ConduitUI.AgentDot` in `ConduitFlowAtoms.swift`), not a white disc.
/// A white disc read as a jarring light patch against the dark sheet
/// and buried the mark's own color identity (device feedback); tinting
/// the mark itself (`.renderingMode(.template)`, via `AgentGlyph`) keeps
/// the dark Codex knot visible without one.
struct AgentAvatar: View {
    let assistant: String
    var size: CGFloat = 24
    @Environment(\.neonTheme) private var neon

    var body: some View {
        let tint = neon.agentTint(forAgent: assistant)
        return ZStack {
            Circle().fill(tint.opacity(0.18))
            AgentGlyph(assistant: assistant, size: size * 0.6)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(tint, lineWidth: 1.5)
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
        case "claude":    name = "ClaudeMark"
        case "codex":     name = "CodexMark"
        case "gemini":    name = "GeminiMark"
        case "opencode":  name = "OpencodeMark"
        default:          return nil
        }
        return UIImage(named: name) != nil ? name : nil
    }

    /// Per-agent optical-size correction for the bundled brand-mark PNGs.
    /// The source art isn't uniformly cropped -- gemini's and opencode's
    /// marks carry more effective padding than claude's/codex's at the
    /// same `scaledToFit` frame, so they read visibly smaller even in an
    /// identical container (device feedback). Applied as an extra
    /// multiplier by both [AgentAvatar] and [AgentGlyph] so every agent's
    /// logo occupies roughly the same optical weight at any size. `1.0` is
    /// a no-op; only the two under-sized marks are scaled up.
    static func glyphRenderScale(forAgent assistant: String) -> CGFloat {
        switch assistant.lowercased() {
        case "gemini", "opencode": return 1.25
        default: return 1.0
        }
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

    /// Static form of the per-agent monogram, so other bare-glyph
    /// components (e.g. [AgentGlyph]) can reuse it without instantiating
    /// a full `AgentAvatar`.
    static func monogram(forAgent assistant: String) -> String {
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

/// Bare tinted per-agent glyph -- no background disc/tile, just the real
/// brand mark (Claude starburst / Codex knot / opencode mark), or an SF
/// Symbol / monogram letter fallback when no mark is bundled, tinted with
/// the agent's theme color. This is the ConduitUI list-row idiom ("rows
/// lead with a bare tinted symbol, not a filled tile" -- see
/// `ConduitListRow`). Use this instead of `AgentAvatar` in any row-leading
/// position; reserve `AgentAvatar`'s filled disc for picker / hero contexts
/// that want a heavier visual anchor.
struct AgentGlyph: View {
    let assistant: String
    var size: CGFloat = 20
    @Environment(\.neonTheme) private var neon

    var body: some View {
        let tint = neon.agentTint(forAgent: assistant)
        return Group {
            if let asset = AgentAvatar.logoAsset(forAgent: assistant) {
                // Real brand mark, rendered as a template (alpha-mask) image
                // so it tints exactly like the SF Symbol fallback below --
                // bare mark, no white tile/disc behind it. Scaled by the
                // same optical-size correction as `AgentAvatar` (see
                // `glyphRenderScale`) so gemini/opencode don't read smaller
                // than claude/codex; the resulting frame stays well inside
                // the outer `size` container, so this can't overflow/clip.
                let glyphSize = size * 0.62 * AgentAvatar.glyphRenderScale(forAgent: assistant)
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: glyphSize, height: glyphSize)
            } else if let symbol = AgentAvatar.symbol(forAgent: assistant) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.62, weight: .semibold))
            } else {
                Text(AgentAvatar.monogram(forAgent: assistant))
                    .font(.system(size: size * 0.58, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .accessibilityLabel(Text(assistant.capitalized))
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
