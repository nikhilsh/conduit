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
/// Five states (state.status + interruptKind + staleness):
///   running·fresh (agent tint) / running·stale (dimmed) /
///   **choice** ("pending" + `.choice`, cyan — an n-way question, CTA
///   "Open to choose" opens the app) / **permission** ("pending" +
///   `.permission`, amber — a binary tool gate, Approve/Reject run as a
///   non-opening App Intent in the background) / done ("exited", green).
///
/// Handoff Part B — the bug being fixed: the shipped card slapped a single
/// "Approve" on a multiple-CHOICE question (approve *what*? it hid the
/// options). We now model two honest interrupt kinds and only ever offer
/// background Approve/Reject on a real binary gate.
///
/// **Why no `ConduitTheme` import?** Widget extensions get a separate
/// bundle; this file stays self-contained (BRAND.md hex tokens inlined)
/// so the extension target depends only on the shared model + intent files.
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
            let card = TurnCardState(
                status: context.state.status,
                interruptKind: context.state.interruptKind,
                isStale: context.isStale
            )
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
                        if card.isNeedsYou {
                            NeedsBody(
                                state: context.state,
                                card: card,
                                agentName: context.attributes.agentName
                            )
                        } else {
                            HStack {
                                ActionLine(state: context.state, card: card)
                                Spacer(minLength: 8)
                                SyncStamp(syncedAt: context.state.syncedAt, isStale: context.isStale)
                            }
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
                case .choice, .permission:
                    Text(TurnPresentation.compactWord(for: card))
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(tint)
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

/// The five render states, folded from `status` + `interruptKind` +
/// ActivityKit staleness.
enum TurnCardState {
    case runningFresh
    case runningStale
    /// "pending" + `.choice` — an n-way question (cyan, opens the app).
    case choice
    /// "pending" + `.permission` — a binary tool gate (amber, Approve/Reject).
    case permission
    case done

    init(status: String, interruptKind: TurnInterruptKind?, isStale: Bool) {
        switch status {
        case "pending":
            // Default to choice — the safe option. A mis-classified
            // permission still resolves (choice opens the app to answer);
            // the inverse would offer a background Approve on a real
            // question, the exact bug Part B fixes.
            self = (interruptKind == .permission) ? .permission : .choice
        case "exited", "done":
            self = .done
        default:
            self = isStale ? .runningStale : .runningFresh
        }
    }

    /// Whether the card is a "needs you" interrupt (choice or permission).
    var isNeedsYou: Bool { self == .choice || self == .permission }
}

// MARK: - Brand tokens (self-contained — BRAND.md §3)

enum ConduitBrand {
    static let bg = Color(red: 0x04 / 255, green: 0x05 / 255, blue: 0x0A / 255)
    static let cyan = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)
    static let green = Color(red: 0x3E / 255, green: 0xF0 / 255, blue: 0xA0 / 255)
    static let amber = Color(red: 0xFF / 255, green: 0xB6 / 255, blue: 0x27 / 255)
    static let claude = Color(red: 0xFF / 255, green: 0x9D / 255, blue: 0x4D / 255)

    static func agentTint(_ agent: String) -> Color {
        agent.lowercased().contains("codex") ? cyan : claude
    }

    /// State tint: running keeps the agent tint, a choice goes cyan, a
    /// permission goes amber, done goes green.
    static func tint(for card: TurnCardState, agent: String) -> Color {
        switch card {
        case .runningFresh:  return agentTint(agent)
        case .runningStale:  return agentTint(agent).opacity(0.6)
        case .choice:        return cyan
        case .permission:    return amber
        case .done:          return green
        }
    }
}

enum TurnPresentation {
    static func title(for attributes: TurnActivityAttributes) -> String {
        attributes.sessionName.isEmpty ? attributes.agentName : attributes.sessionName
    }

    /// Status-line word under the title (lock banner + island expanded).
    static func statusWord(for card: TurnCardState) -> String {
        switch card {
        case .runningFresh, .runningStale: return "running"
        case .choice:                      return "needs your pick"
        case .permission:                  return "permission"
        case .done:                        return "done"
        }
    }

    /// Compact-island trailing word for a needs-you state.
    static func compactWord(for card: TurnCardState) -> String {
        switch card {
        case .choice:     return "answer"
        case .permission: return "approve?"
        default:          return ""
        }
    }

    /// Uppercase section label above a needs-you question.
    static func needsSectionLabel(for card: TurnCardState, agentName: String) -> String {
        switch card {
        case .choice:     return "\(agentName) is asking".uppercased()
        case .permission: return "Permission requested".uppercased()
        default:          return ""
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

/// Mark tile · title + status line · trailing clock, then either the
/// running/done action line + freshness, or the needs-you question, then
/// the state's CTA row.
private struct TurnLockScreenView: View {
    let attributes: TurnActivityAttributes
    let state: TurnActivityAttributes.ContentState
    let isStale: Bool

    private var card: TurnCardState {
        TurnCardState(status: state.status, interruptKind: state.interruptKind, isStale: isStale)
    }
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

            if card.isNeedsYou {
                NeedsBody(state: state, card: card, agentName: attributes.agentName)
            } else {
                HStack(spacing: 8) {
                    ActionLine(state: state, card: card)
                    Spacer(minLength: 8)
                    SyncStamp(syncedAt: state.syncedAt, isStale: isStale)
                }
            }

            ActionButtons(sessionID: attributes.sessionID, card: card)
        }
        // Honest degradation: past staleDate the whole card dims; the
        // timer keeps ticking (it's on-device truth).
        .opacity(card == .runningStale ? 0.72 : 1.0)
    }
}

// MARK: - Needs-you body (choice / permission)

/// The actual question (handoff Part B). For a **choice**: the prompt + a
/// small "N options" pill (the count — we do NOT list the options; the
/// answer UI lives in the app). For a **permission**: the binary prompt
/// ("Run … to origin?"). NO fake "Approve" on a choice.
private struct NeedsBody: View {
    let state: TurnActivityAttributes.ContentState
    let card: TurnCardState
    let agentName: String

    private var tint: Color { ConduitBrand.tint(for: card, agent: agentName) }
    private var prompt: String {
        if let p = state.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return p
        }
        return "Needs your input"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(TurnPresentation.needsSectionLabel(for: card, agentName: agentName))
                .font(.system(size: 10, design: .monospaced).weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(tint)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(prompt)
                    .font(.system(.subheadline, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if card == .choice, state.optionCount > 0 {
                    Text("\(state.optionCount) options")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                        .fixedSize()
                }
            }
        }
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

/// "⚡ current action" (running) or "✓ summary" (done).
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

/// Per-state CTA row (handoff Part B).
///   - running·fresh: no CTA (the live timer is the signal).
///   - running·stale: "Tap to refresh" → opens the app (which refreshes).
///   - **choice**: "Open to choose" → opens the app's picker (a question
///     needs real UI; we never answer it from the lock screen).
///   - **permission**: Approve / Reject → non-opening `LiveActivityIntent`s
///     that post the decision to the broker in the BACKGROUND, no launch.
///   - done: "Open session" → opens the app.
private struct ActionButtons: View {
    let sessionID: String
    let card: TurnCardState

    var body: some View {
        switch card {
        case .runningFresh:
            EmptyView()
        case .runningStale:
            ctaLink(
                "Tap to refresh", icon: "arrow.clockwise",
                fill: ConduitBrand.claude, foreground: .black,
                action: "refresh"
            )
        case .choice:
            VStack(spacing: 4) {
                ctaLink(
                    "Open to choose", icon: "eye",
                    fill: ConduitBrand.cyan, foreground: .black,
                    action: "choose"
                )
                Text("opens Conduit to the picker")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case .permission:
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Button(intent: ApproveSessionIntent(sessionID: sessionID)) {
                        ctaLabel("Approve", icon: "checkmark",
                                 fill: ConduitBrand.amber, foreground: .black)
                    }
                    .buttonStyle(.plain)
                    Button(intent: RejectSessionIntent(sessionID: sessionID)) {
                        ctaLabel("Reject", icon: "xmark",
                                 fill: Color.white.opacity(0.12), foreground: .white)
                    }
                    .buttonStyle(.plain)
                }
                Text("answers in background · no app launch")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
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
