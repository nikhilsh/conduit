import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock-screen + Dynamic Island renderer for the active-turn Live Activity.
///
/// Round-3 §2 — the server-less update model:
///   - **Elapsed time is the heartbeat**: `Text(_, style: .timer)` ticks
///     on-device with zero updates and zero network — the always-honest
///     proof of life.
///   - **Content is a stamped snapshot**: the host pushes a fresh
///     `ContentState` (with `syncedAt`) whenever it gets execution time
///     and sets a `staleDate` ~9 min out.
///   - **Past `staleDate`** (`context.isStale`) the card dims, the
///     status dot stops claiming liveness, the timer keeps ticking, and
///     the CTA swaps to **Tap to refresh** (deep-links into the app,
///     which refreshes the activity).
///   - **No fake progress** — nothing animates that the app can't feed.
///
/// Four states (state.status + staleness):
///   running·fresh (claude tint) / running·stale (dimmed) /
///   needs-you ("pending", cyan, Approve + View diff) /
///   done ("exited", green, summary + Open session).
///
/// **Why no `ConduitTheme` import?** Widget extensions get a separate
/// bundle; this file stays self-contained (BRAND.md hex tokens inlined)
/// so the extension target depends only on the two shared model files.
struct TurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnActivityAttributes.self) { context in
            TurnLockScreenView(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            .padding(14)
            .activityBackgroundTint(ConduitBrand.bg.opacity(0.88))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let card = TurnCardState(status: context.state.status, isStale: context.isStale)
            let tint = ConduitBrand.tint(for: card, agent: context.attributes.agentName)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ConduitMarkGlyph(tint: tint, size: 30)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TurnPresentation.title(for: context.attributes))
                            .font(.system(.subheadline, design: .default).weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 5) {
                            StatusDot(card: card, tint: tint)
                            Text(TurnPresentation.statusWord(for: card))
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .foregroundStyle(tint)
                            Text("· \(context.attributes.agentName.lowercased())")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingClock(state: context.state, card: card, tint: tint)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ActionLine(state: context.state, card: card)
                            Spacer(minLength: 8)
                            SyncStamp(syncedAt: context.state.syncedAt, isStale: context.isStale)
                        }
                        ActionButtons(
                            sessionID: context.attributes.sessionID,
                            card: card
                        )
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                ConduitMarkGlyph(tint: tint, size: 22)
            } compactTrailing: {
                switch card {
                case .runningFresh:
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(.caption2, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .frame(maxWidth: 44)
                case .runningStale:
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(.caption2, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 44)
                case .needsYou:
                    Text("approve")
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(ConduitBrand.cyan)
                case .done:
                    Label("done", systemImage: "checkmark")
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(ConduitBrand.green)
                }
            } minimal: {
                // Shared island: just the glyph, agent/state-tinted.
                ConduitMarkGlyph(tint: tint, size: 20)
            }
        }
    }
}

// MARK: - Card state

/// The four round-3 §2 states, folded from `status` + ActivityKit
/// staleness.
enum TurnCardState {
    case runningFresh
    case runningStale
    case needsYou
    case done

    init(status: String, isStale: Bool) {
        switch status {
        case "pending":          self = .needsYou
        case "exited", "done":   self = .done
        default:                 self = isStale ? .runningStale : .runningFresh
        }
    }
}

// MARK: - Brand tokens (self-contained — BRAND.md §3)

enum ConduitBrand {
    static let bg = Color(red: 0x04 / 255, green: 0x05 / 255, blue: 0x0A / 255)
    static let cyan = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)
    static let green = Color(red: 0x3E / 255, green: 0xF0 / 255, blue: 0xA0 / 255)
    static let claude = Color(red: 0xFF / 255, green: 0x9D / 255, blue: 0x4D / 255)

    static func agentTint(_ agent: String) -> Color {
        agent.lowercased().contains("codex") ? cyan : claude
    }

    /// State tint: running keeps the agent tint, needs-you goes cyan,
    /// done goes green.
    static func tint(for card: TurnCardState, agent: String) -> Color {
        switch card {
        case .runningFresh:  return agentTint(agent)
        case .runningStale:  return agentTint(agent).opacity(0.6)
        case .needsYou:      return cyan
        case .done:          return green
        }
    }
}

enum TurnPresentation {
    static func title(for attributes: TurnActivityAttributes) -> String {
        attributes.sessionName.isEmpty ? attributes.agentName : attributes.sessionName
    }

    static func statusWord(for card: TurnCardState) -> String {
        switch card {
        case .runningFresh, .runningStale: return "running"
        case .needsYou:                    return "needs you"
        case .done:                        return "done"
        }
    }

    static func actionLine(for state: TurnActivityAttributes.ContentState) -> String {
        if let command = state.currentCommand, !command.isEmpty { return command }
        if let tool = state.currentTool, !tool.isEmpty { return tool }
        return "working…"
    }

    /// Total run duration for the done state ("4m 12s") — a finished
    /// fact, so a static string, not a ticking timer.
    static func doneDuration(startedAt: Date, endedAt: Date) -> String {
        let seconds = max(0, Int(endedAt.timeIntervalSince(startedAt)))
        let m = seconds / 60
        let s = seconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    static func deepLink(sessionID: String, action: String? = nil) -> URL {
        var raw = "conduit://session/\(sessionID)"
        if let action { raw += "?action=\(action)" }
        return URL(string: raw) ?? URL(string: "conduit://")!
    }
}

// MARK: - Lock-screen card

/// Designs 06–09: mark tile · title + status line · trailing clock,
/// then the action/freshness line, then the state's CTA row.
private struct TurnLockScreenView: View {
    let attributes: TurnActivityAttributes
    let state: TurnActivityAttributes.ContentState
    let isStale: Bool

    private var card: TurnCardState { TurnCardState(status: state.status, isStale: isStale) }
    private var tint: Color { ConduitBrand.tint(for: card, agent: attributes.agentName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ConduitMarkTile(tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(TurnPresentation.title(for: attributes))
                        .font(.system(.subheadline, design: .default).weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        StatusDot(card: card, tint: tint)
                        Text(TurnPresentation.statusWord(for: card))
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(tint)
                        Text("· \(attributes.agentName.lowercased())")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                TrailingClock(state: state, card: card, tint: tint)
            }

            HStack(spacing: 8) {
                ActionLine(state: state, card: card)
                Spacer(minLength: 8)
                SyncStamp(syncedAt: state.syncedAt, isStale: isStale)
            }

            ActionButtons(sessionID: attributes.sessionID, card: card)
        }
        // Honest degradation: past staleDate the whole card dims; the
        // timer keeps ticking (it's on-device truth).
        .opacity(card == .runningStale ? 0.72 : 1.0)
    }
}

// MARK: - Shared subviews

/// `>_`-flavored daemon mark, drawn inline (the host's `ConduitMark`
/// lives in the app target). Rounded-square outline + squint eyes +
/// smile, flat-tinted.
private struct ConduitMarkGlyph: View {
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 32.0
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

            let body = Path(
                roundedRect: CGRect(x: 5.4 * s, y: 5.4 * s, width: 21.2 * s, height: 21.2 * s),
                cornerRadius: 6.4 * s
            )
            ctx.stroke(body, with: .color(tint), lineWidth: 2.4 * s)

            var face = Path()
            face.move(to: pt(11, 13.4)); face.addLine(to: pt(13.6, 15.4)); face.addLine(to: pt(11, 17.4))
            face.move(to: pt(21, 13.4)); face.addLine(to: pt(18.4, 15.4)); face.addLine(to: pt(21, 17.4))
            face.move(to: pt(13, 20)); face.addQuadCurve(to: pt(19, 20), control: pt(16, 22.4))
            ctx.stroke(face, with: .color(tint),
                       style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Lock-screen leading tile: the mark on a soft tinted rounded square.
private struct ConduitMarkTile: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: 38, height: 38)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint.opacity(0.4), lineWidth: 1)
            )
            .overlay(ConduitMarkGlyph(tint: tint, size: 24))
    }
}

/// State-coloured dot. The design pulses it while fresh — Live
/// Activities can't run continuous animations, so "fresh" is a bright
/// solid dot and "stale/done" a muted one; the ticking elapsed timer is
/// the real liveness signal.
private struct StatusDot: View {
    let card: TurnCardState
    let tint: Color

    var body: some View {
        Circle()
            .fill(card == .runningStale ? Color.secondary : tint)
            .frame(width: 6, height: 6)
    }
}

/// Trailing clock: ticking elapsed timer while live (zero-update,
/// on-device), static total duration once done.
private struct TrailingClock: View {
    let state: TurnActivityAttributes.ContentState
    let card: TurnCardState
    let tint: Color

    var body: some View {
        if card == .done {
            Text(TurnPresentation.doneDuration(startedAt: state.startedAt, endedAt: state.syncedAt))
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(tint)
        } else {
            Text(state.startedAt, style: .timer)
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(card == .runningStale ? Color.secondary : tint)
                .frame(maxWidth: 60, alignment: .trailing)
        }
    }
}

/// "⚡ current action" (running/pending) or "✓ summary" (done).
private struct ActionLine: View {
    let state: TurnActivityAttributes.ContentState
    let card: TurnCardState

    var body: some View {
        HStack(spacing: 5) {
            if card == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ConduitBrand.green)
                Text(state.summary ?? "done")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(TurnPresentation.actionLine(for: state))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

/// "↻ synced just now / Nm ago" — the honesty stamp. `.relative` keeps
/// aging on-device without pushes.
private struct SyncStamp: View {
    let syncedAt: Date
    let isStale: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8))
            Text("synced")
            Text(syncedAt, style: .relative)
                .monospacedDigit()
            Text("ago")
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(isStale ? Color.orange.opacity(0.9) : Color.secondary)
        .lineLimit(1)
    }
}

/// Per-state CTA row. All actions deep-link into the app (no backend —
/// the app is the only thing that can act).
private struct ActionButtons: View {
    let sessionID: String
    let card: TurnCardState

    var body: some View {
        switch card {
        case .runningFresh:
            EmptyView()  // live card needs no CTA; tapping it opens the app
        case .runningStale:
            ctaLink(
                "Tap to refresh", icon: "arrow.clockwise",
                fill: ConduitBrand.claude, foreground: .black,
                action: "refresh"
            )
        case .needsYou:
            HStack(spacing: 8) {
                // In-place approval: a LiveActivityIntent performs in the
                // app process WITHOUT opening the UI (round-3 §2
                // follow-up) — the host answers the pending card with its
                // affirmative option.
                Button(intent: ApproveSessionIntent(sessionID: sessionID)) {
                    ctaLabel(
                        "Approve", icon: "checkmark",
                        fill: ConduitBrand.cyan, foreground: .black
                    )
                }
                .buttonStyle(.plain)
                ctaLink(
                    "View diff", icon: "eye",
                    fill: Color.white.opacity(0.12), foreground: .white,
                    action: "diff"
                )
            }
        case .done:
            ctaLink(
                "Open session", icon: "eye",
                fill: ConduitBrand.green, foreground: .black,
                action: nil
            )
        }
    }

    private func ctaLink(
        _ title: String, icon: String, fill: Color, foreground: Color, action: String?
    ) -> some View {
        Link(destination: TurnPresentation.deepLink(sessionID: sessionID, action: action)) {
            ctaLabel(title, icon: icon, fill: fill, foreground: foreground)
        }
    }

    private func ctaLabel(
        _ title: String, icon: String, fill: Color, foreground: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(title).font(.system(.footnote, design: .default).weight(.bold))
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(Capsule().fill(fill))
    }
}
