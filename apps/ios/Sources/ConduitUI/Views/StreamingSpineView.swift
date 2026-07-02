import SwiftUI
import UIKit

// MARK: - StreamingSpineView
//
// Direction C "Flowing conduit" streaming turn (design handoff streaming_turn/README.md).
// Replaces the legacy ConduitStreamingOverlay with a spine-based render:
//   - 24x24 mark head (radius 7, rgba(255,255,255,0.03) bg, 1px border)
//     containing ConduitMark at 15px. While streaming: mark breathes (glow
//     accent <-> green, ~2.1s). Done: no glow.
//   - 2px rail (radius 2), starts 6px below mark. While streaming: flowing
//     gradient (accent->green->accent->green sized 200% height, scrolling down,
//     ~1.4s). Done: static accent->green at opacity 0.5.
//   - Body column 13px to the right; vertical stack gap 12: live ToolLedger
//     then prose. Prose streams with a blinking caret (7x1em accent block, 1s).
//
// All animations stop under accessibilityReduceMotion.
//
// Telemetry breadcrumbs mark streaming start/finish.

extension ConduitUI {

    // MARK: StreamingSpineView

    /// The streaming-turn spine render (Direction C). Shown in place of
    /// ConduitStreamingOverlay while an assistant turn is in progress.
    struct StreamingSpineView: View {
        /// The partial prose content streamed so far.
        let content: String

        @Environment(\.neonTheme) private var neon
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        // MARK: Breathe animation (mark head glow, 2.1s half-cycle)
        @State private var glowPhase: Bool = false

        // MARK: Caret blink (1.0s step)
        @State private var caretVisible: Bool = true

        // Async loop tasks
        @State private var breatheTask: Task<Void, Never>? = nil
        @State private var caretTask: Task<Void, Never>? = nil
        @State private var flowTask: Task<Void, Never>? = nil

        // Rail flow: tile height unit for the flowing gradient stack.
        // railOffset animates -railTile -> 0, started once in .task(id: reduceMotion).
        private let railTile: CGFloat = 46
        // FIXED tile count (generous: 48 * 46 ≈ 2200pt covers any realistic
        // message). Kept constant — NOT derived from the rail height — so the
        // tile `ForEach` and the inner stack frame never change as the streamed
        // message grows. Only the outer clip (`.frame(height: h)`) tracks height,
        // which is cheap; deriving the count from `h` rebuilt the stack every
        // token and stuttered the flow.
        private let railTileCount: Int = 48
        @State private var railOffset: CGFloat = 0

        // Drawing growth animation: the visible clipped rail length eases toward the
        // content-driven height `h`. Starts at 0 so the rail draws downward on first
        // appear; each streamed token retargets the animation smoothly. Under
        // reduceMotion the length snaps directly to h (no draw animation).
        @State private var railDrawnHeight: CGFloat = 0

        var body: some View {
            HStack(alignment: .top, spacing: 13) {
                // MARK: Rail column (fixed 24pt)
                VStack(spacing: 0) {
                    markHead
                    railLine
                        .padding(.top, 6)
                }
                .frame(width: 24)

                // MARK: Body column
                VStack(alignment: .leading, spacing: 12) {
                    proseBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Height must track the prose column's intrinsic height, NOT grow
            // greedily: `railLine` uses `.frame(maxHeight: .infinity)` (there is
            // no SwiftUI equivalent of Android's Height(IntrinsicSize.Max)), which
            // makes the whole spine vertically greedy. Placed directly in the chat
            // transcript VStack, a greedy row eats all leftover viewport space and
            // the rail shoots far below the last line of prose. `fixedSize` pins
            // the spine to its ideal (prose) height so the rail matches the message
            // and stops there. horizontal:false keeps the width flexible.
            .fixedSize(horizontal: false, vertical: true)
            .task(id: reduceMotion) {
                breatheTask?.cancel()
                caretTask?.cancel()
                flowTask?.cancel()
                guard !reduceMotion else {
                    // Calm end-state: static, no glow, no caret blink, full prose.
                    glowPhase = false
                    railOffset = 0
                    caretVisible = true
                    return
                }
                // Rail flow runs as a Task-LOOP (not withAnimation.repeatForever):
                // CA repeat-forever animations play once then drop on re-render/
                // background. The loop resets to the top and sweeps down forever.
                startFlow()
                startBreathe()
                startCaret()
            }
            .onAppear {
                Telemetry.breadcrumb("streaming-spine", "streaming start", data: ["contentLen": "\(content.count)"])
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            ) { _ in
                // Re-kick the rail flow loop after foregrounding (its withAnimation
                // steps are paused in the background). The breathe/caret loops
                // survive independently.
                guard !reduceMotion else { return }
                startFlow()
                Telemetry.breadcrumb("streaming-spine", "foreground restart",
                    data: ["contentLen": "\(content.count)"])
            }
            .accessibilityLabel("Assistant is writing: \(content)")
        }

        // MARK: Mark head

        private var markHead: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(red: 1, green: 1, blue: 1, opacity: 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(neon.border, lineWidth: 1)
                    )
                ConduitUI.ConduitMark(size: 15, glow: true)
            }
            .frame(width: 24, height: 24)
            // Breathe: shadow pulses between accent and green while streaming.
            // Under reduceMotion: no shadow (calm end-state).
            .shadow(
                color: reduceMotion ? .clear : (glowPhase ? neon.accentBright.opacity(0.55) : neon.green.opacity(0.45)),
                radius: reduceMotion ? 0 : (glowPhase ? 8 : 5)
            )
        }

        // MARK: Rail line

        // The rail is a 2px wide view that fills the full remaining height offered by the
        // parent VStack (which is intrinsic-height-matched to the prose column).
        //
        // GeometryReader is used ONLY for sizing: it gives us `h` = the true rail height
        // so the tile stack always covers the full column. Height changes during streaming
        // re-clip the stack cheaply and do NOT restart the animation because railOffset is
        // started ONCE in .task(id: reduceMotion) in body, not here.
        //
        // Drawing growth: the VISIBLE clip uses railDrawnHeight (the animated length), not h
        // directly. `h` is the full content-driven target; railDrawnHeight eases toward it
        // so the rail appears to draw downward as the message grows. The column/GeometryReader
        // height is still `h` so layout is unaffected (the column simply clips shorter while
        // animating). Under reduceMotion: railDrawnHeight snaps to h (no draw animation).
        //
        // While streaming: the FIXED-size tile stack (railTileCount tiles) sits at railOffset
        // (animated -railTile -> 0, looping), seamlessly flowing down.
        // Under reduceMotion: static accent->green gradient spanning h, opacity 0.5.
        private var railLine: some View {
            GeometryReader { geo in
                let h = max(geo.size.height, railTile)
                // Use railDrawnHeight (the animated length) for the visible clip.
                // Clamp to h so we never show more than the actual content height.
                let drawn = min(railDrawnHeight, h)
                Group {
                    if reduceMotion {
                        // Calm end-state: static full-height accent->green at opacity 0.5.
                        // railDrawnHeight is snapped to h immediately (no draw animation).
                        LinearGradient(
                            colors: [neon.accentBright, neon.green],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: 2, height: h)
                        .opacity(0.5)
                    } else {
                        // FIXED-size tile stack (railTileCount tiles) — constant across
                        // streamed-message growth so it never rebuilds. It's taller than
                        // any realistic rail; the outer `.frame(height: drawn)` + `.clipped()`
                        // trims it to the animated drawn length. Animation is driven by railOffset
                        // (started once in body/.task), untouched by height changes.
                        VStack(spacing: 0) {
                            ForEach(0..<railTileCount, id: \.self) { _ in
                                LinearGradient(
                                    colors: [neon.accentBright, neon.green],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(width: 2, height: railTile)
                            }
                        }
                        .frame(width: 2, height: railTile * CGFloat(railTileCount), alignment: .top)
                        .offset(y: railOffset)
                        .opacity(0.95)
                    }
                }
                // Clip to the animated drawn length (not h) so the rail visually grows.
                // The outer GeometryReader still occupies h, keeping layout stable.
                .frame(width: 2, height: drawn, alignment: .top)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                // Drive the growth animation whenever the content height changes.
                // On first appear railDrawnHeight is 0 and this fires immediately to
                // kick the draw-down. Each streamed token retargets the ease smoothly.
                .onChange(of: h) { _, newH in
                    if reduceMotion {
                        railDrawnHeight = newH
                    } else {
                        withAnimation(.easeOut(duration: 0.35)) {
                            railDrawnHeight = newH
                        }
                    }
                }
                .onAppear {
                    // First appear: start at 0 (or snap if reduceMotion) then animate to h.
                    if reduceMotion {
                        railDrawnHeight = h
                    } else {
                        railDrawnHeight = 0
                        withAnimation(.easeOut(duration: 0.35)) {
                            railDrawnHeight = h
                        }
                    }
                }
            }
            .frame(width: 2)
            .frame(maxHeight: .infinity)
        }

        // MARK: Prose block with caret

        // caretSuffix: always present in the layout while streaming (no width jiggle).
        // Blinks by toggling color accent <-> .clear, NOT by swapping glyph/space.
        // \u{2009} = THIN SPACE (gap after last char); \u{258C} = LEFT HALF BLOCK (caret).
        // Under reduceMotion: empty string so no caret is rendered at all.
        private var caretSuffix: String {
            reduceMotion ? "" : "\u{2009}\u{258C}"
        }

        private var proseBlock: some View {
            Group {
                if content.isEmpty {
                    // Pre-first-token: invisible placeholder keeps layout stable.
                    Text("\u{200B}")
                        .font(neon.sans(15.5))
                        .foregroundStyle(neon.text)
                } else {
                    // Inline caret: thin-space + block glyph always present while streaming.
                    // Blinks via color toggle (accentBright <-> .clear) so text width is stable.
                    // Under reduceMotion: caretSuffix is empty, no caret rendered.
                    //
                    // Inline markdown: same AttributedString parse used by the settled path
                    // (conduitInlineAttributed / .inlineOnlyPreservingWhitespace). Unclosed
                    // markers (partial stream) are left as literal text by the parser, so
                    // partial content never mangles. Cache hit on every streaming tick after
                    // the first parse for that content chunk.
                    let markdownAttr = conduitInlineAttributed(content)
                    (
                        Text(markdownAttr).foregroundStyle(neon.text)
                        + Text(caretSuffix).foregroundStyle(caretVisible ? neon.accentBright : .clear)
                    )
                    .font(neon.sans(15.5))
                    .lineSpacing(15.5 * (1.62 - 1.0))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        // MARK: Animation loops

        private func startFlow() {
            flowTask?.cancel()
            flowTask = Task {
                // Continuous downward flow: reset to the top (instant — seamless
                // because the tiles repeat every railTile), sweep down over 1.4s,
                // then loop. Runs as a Task so it keeps going across re-renders and
                // foregrounding, unlike a one-shot repeatForever CAAnimation.
                while !Task.isCancelled {
                    railOffset = -railTile
                    withAnimation(.linear(duration: 1.4)) {
                        railOffset = 0
                    }
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                }
            }
        }

        private func startBreathe() {
            breatheTask?.cancel()
            breatheTask = Task {
                // 2.1s full cycle = 1.05s per half
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 1.05)) {
                        glowPhase.toggle()
                    }
                    try? await Task.sleep(nanoseconds: 1_050_000_000)
                }
            }
        }

        private func startCaret() {
            caretTask?.cancel()
            caretTask = Task {
                // 1.0s step blink: visible 0.5s, hidden 0.5s.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    caretVisible.toggle()
                }
            }
        }
    }
}

// MARK: - ToolLedger
//
// Typed-step expandable ledger. Replaces the §10 mono block (MonoRunningTicker /
// MonoInlineBlock / MonoCollapseBlock) and the old signatureBody for arm B.
//
// Three states driven by mode + anyRunning:
//   live (anyRunning=true):  header with spinner + "N/total steps", rows tick in.
//   done-expanded:           header with terminal + "total steps" + checkmark/failed,
//                            chevron-up to collapse.
//   collapsed-footnote:      one-line pill, tap to expand.
//
// Step classification:
//   run/read (shell): $ + command mono, status dot.
//   edit:             pencil + filename mono, diff chip (omitted — no data today).
//   Consecutive identical navigational commands are coalesced to one row.

/// One typed step entry in the ledger.
struct LedgerStep: Equatable {
    enum Kind: Equatable { case run, read, edit }
    let kind: Kind
    let id: String
    /// For run/read: the command string. For edit: the filename (last path component).
    let label: String
    /// For edit: optional diff counts (nil today — ViewEventFile has no add/del counts).
    let addCount: Int?
    let delCount: Int?
    let state: NeonCardState
    let exitCode: Int32?

    init(from item: ConversationItem) {
        id = item.id
        let role = NeonToolClassifier.tintRole(forToolName: item.toolName)
        let s = NeonCardState(status: item.status, exitCode: item.exitCode)
        state = s
        exitCode = item.exitCode
        // Classify edit vs read vs run.
        if role == .claude {
            kind = .edit
            // Use first file path basename, or fall back to humanLabel.
            if let f = item.files.first {
                let url = f.path.split(separator: "/").last.map(String.init) ?? f.path
                label = url.isEmpty ? "file" : url
            } else {
                label = NeonToolClassifier.humanLabel(toolName: item.toolName, fileCount: item.files.count)
            }
            // Diff counts are not available today (ViewEventFile has no add/del).
            addCount = nil
            delCount = nil
        } else if role == .blue {
            kind = .read
            label = ConversationRenderer.extractCommand(from: item)
                ?? NeonToolClassifier.humanLabel(toolName: item.toolName, fileCount: item.files.count)
            addCount = nil
            delCount = nil
        } else {
            kind = .run
            label = ConversationRenderer.extractCommand(from: item)
                ?? NeonToolClassifier.humanLabel(toolName: item.toolName, fileCount: item.files.count)
            addCount = nil
            delCount = nil
        }
    }
}

/// Coalesce consecutive items that are effectively duplicates (same kind + label, or
/// repeated navigational cd commands).
private func coalesceSteps(_ items: [ConversationItem]) -> [LedgerStep] {
    var result: [LedgerStep] = []
    for item in items {
        let step = LedgerStep(from: item)
        // Coalesce: drop if the last entry has the same kind + label (e.g. repeated cd).
        if let last = result.last,
           last.kind == step.kind,
           last.label == step.label,
           step.kind == .run {
            // Replace with the newer state (so running > done).
            if case .running = step.state {
                result[result.count - 1] = step
            }
            continue
        }
        result.append(step)
    }
    return result
}

// MARK: ToolLedger

/// The redesigned tool ledger. arm-B command-block render for live and done states.
/// `isExpanded` is persisted by the parent (ConduitToolBundleCard) via @State.
struct ToolLedger: View {
    let items: [ConversationItem]
    let anyRunning: Bool
    let failCount: Int
    @Binding var isExpanded: Bool

    @Environment(\.neonTheme) private var neon
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [LedgerStep] { coalesceSteps(items) }
    private var doneCount: Int { steps.filter { $0.state == .ok || $0.state == .fail }.count }
    private var totalCount: Int { steps.count }

    var body: some View {
        if isExpanded || anyRunning {
            expandedLedger
        } else {
            footnote
        }
    }

    // MARK: Footnote (collapsed)

    private var footnote: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded = true
                Telemetry.breadcrumb("tool-ledger", "expand", data: [
                    "steps": "\(totalCount)", "failed": "\(failCount)",
                ])
            }
        } label: {
            HStack(spacing: 9) {
                Text("\(totalCount) step\(totalCount == 1 ? "" : "s")")
                    .font(neon.mono(12.5))
                    .foregroundStyle(neon.textFaint)
                Text("\u{00B7}")
                    .foregroundStyle(neon.ghost)
                if failCount > 0 {
                    Text("\(failCount) failed")
                        .font(neon.mono(12.5))
                        .foregroundStyle(neon.red)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(neon.green)
                        Text("passed")
                            .font(neon.mono(12.5))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(neon.ghost)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 1, green: 1, blue: 1, opacity: 0.018))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(neon.lineSoft, lineWidth: 1)
                )
        )
        .accessibilityLabel("\(totalCount) steps\(failCount > 0 ? ", \(failCount) failed" : ", passed")")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Expanded ledger

    private var expandedLedger: some View {
        VStack(spacing: 0) {
            ledgerHeader
            // Hairline divider = grid token (accent at ~5.5% opacity).
            Rectangle()
                .fill(neon.grid)
                .frame(height: 1)
            ledgerRows
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(neon.codeBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(neon.lineSoft, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Header

    private var ledgerHeader: some View {
        HStack(spacing: 9) {
            if anyRunning {
                SpinnerRing(size: 12, color: neon.accentBright, reduceMotion: reduceMotion)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 14))
                    .foregroundStyle(neon.textFaint)
            }
            Text(anyRunning ? "\(doneCount)/\(totalCount) steps" : "\(totalCount) step\(totalCount == 1 ? "" : "s")")
                .font(neon.mono(12))
                .foregroundStyle(neon.textDim)
            Spacer(minLength: 4)
            if !anyRunning {
                if failCount > 0 {
                    Text("\(failCount) failed")
                        .font(neon.mono(11.5))
                        .foregroundStyle(neon.red)
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(neon.green)
                        Text("passed")
                            .font(neon.mono(11.5))
                            .foregroundStyle(neon.textFaint)
                        // Collapse chevron — only shown in done state.
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded = false
                                Telemetry.breadcrumb("tool-ledger", "collapse", data: [
                                    "steps": "\(totalCount)",
                                ])
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(neon.ghost)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    // MARK: Rows

    @ViewBuilder
    private var ledgerRows: some View {
        ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
            ToolLedgerRow(
                step: step,
                isFirst: idx == 0,
                animate: anyRunning && !reduceMotion
            )
        }
    }
}

// MARK: - ToolLedgerRow

private struct ToolLedgerRow: View {
    let step: LedgerStep
    let isFirst: Bool
    let animate: Bool

    @Environment(\.neonTheme) private var neon
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Row-in animation state (fires once when the row appears in live mode).
    @State private var appeared: Bool = false

    // Pulse animation for running dot.
    @State private var pulseLarge: Bool = false
    @State private var pulseTask: Task<Void, Never>? = nil

    private var isRunning: Bool { step.state == .running }
    private var isFailed: Bool { step.state == .fail }
    private var isDone: Bool { step.state == .ok }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Status dot (16pt column).
            statusDot
                .frame(width: 16, alignment: .center)

            // Middle: label (1fr).
            middleLabel
                .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing: diff chip / running / failed.
            trailingLabel
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(isRunning ? neon.accentBright.opacity(0.04) : Color.clear)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(neon.grid)
                    .frame(height: 1)
            }
        }
        // Row-in slide + fade (once, in live mode only).
        .opacity(animate ? (appeared ? 1 : 0) : 1)
        .offset(y: animate ? (appeared ? 0 : 4) : 0)
        .onAppear {
            if animate && !appeared {
                withAnimation(.easeOut(duration: 0.28)) { appeared = true }
            } else {
                appeared = true
            }
            if isRunning && !reduceMotion { startPulse() }
        }
        .onDisappear {
            pulseTask?.cancel()
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if isRunning {
            Circle()
                .fill(neon.yellow)
                .frame(width: 6, height: 6)
                .shadow(color: neon.yellow.opacity(0.7), radius: pulseLarge ? 5 : 3)
                .scaleEffect(pulseLarge ? 1.2 : 1.0)
        } else if isFailed {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(neon.red)
                .frame(width: 12, height: 12)
        } else {
            Circle()
                .fill(neon.green)
                .frame(width: 6, height: 6)
                .shadow(color: neon.green.opacity(0.65), radius: 4)
        }
    }

    @ViewBuilder
    private var middleLabel: some View {
        switch step.kind {
        case .edit:
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(neon.accentBright)
                Text(step.label)
                    .font(neon.mono(12.5))
                    .foregroundStyle(isRunning ? neon.text : neon.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .run, .read:
            HStack(spacing: 0) {
                Text("$")
                    .font(neon.mono(12.5))
                    .foregroundStyle(neon.textFaint)
                    .padding(.trailing, 7)
                Text(step.label)
                    .font(neon.mono(12.5))
                    .foregroundStyle(isRunning ? neon.text : neon.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private var trailingLabel: some View {
        if step.kind == .edit, let add = step.addCount, let del = step.delCount {
            // Diff chip: only shown when data is available (none today).
            HStack(spacing: 4) {
                Text("+\(add)")
                    .font(neon.mono(11))
                    .foregroundStyle(neon.green)
                Text("-\(del)")
                    .font(neon.mono(11))
                    .foregroundStyle(neon.red)
            }
        } else if isRunning && step.kind != .edit {
            Text("running")
                .font(neon.mono(10.5))
                .foregroundStyle(neon.yellow)
        } else if isFailed {
            Text("exit \(step.exitCode.map(String.init) ?? "?")")
                .font(neon.mono(11))
                .foregroundStyle(neon.red)
        } else {
            EmptyView()
        }
    }

    private func startPulse() {
        pulseTask?.cancel()
        pulseTask = Task {
            // 1.25s ease-in-out infinite (pulse spec).
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.625)) {
                    pulseLarge = true
                }
                try? await Task.sleep(nanoseconds: 625_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.625)) {
                    pulseLarge = false
                }
                try? await Task.sleep(nanoseconds: 625_000_000)
            }
        }
    }
}

// MARK: - SpinnerRing

/// 12px accent ring that spins ~0.9s per revolution. Stops under reduceMotion.
private struct SpinnerRing: View {
    let size: CGFloat
    let color: Color
    let reduceMotion: Bool

    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(
                AngularGradient(
                    colors: [color.opacity(0.2), color],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                guard !reduceMotion else { return }
                // Continuous rotation: 0.9s per revolution.
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
