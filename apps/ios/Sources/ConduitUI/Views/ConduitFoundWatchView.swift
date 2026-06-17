import SwiftUI

// MARK: - FoundWatchView (screen 09 -- Watch live)
//
// Read-only live tail of a running found session.
// Capability gate: only reachable when features?.sessionWatch == true.
//
// Behaviour:
//   1. On appear: fetch full transcript (cursor = latest_ts from the full fetch).
//   2. Poll every ~2.5s: fetchDiscoveredTranscriptSince(sinceMs: cursor)
//      -- append new items, advance cursor to latest_ts.
//   3. Auto-scroll to newest item on append.
//   4. Persistent "Watching live -- read-only" banner + live pulse dot.
//      Pulse animation respects accessibilityReduceMotion.
//   5. Single CTA: "Branch a copy to take control" -- the FoundBranchSheet flow.
//      Gated on features?.sessionFork; if unavailable, shows the unavailable state.
//
// Failure handling:
//   - Poll fail / box drops -> "stream paused -- reconnecting" banner.
//     Last frames stay visible, Branch CTA still offered. Polling keeps retrying.
//   - Session ends (transcript stops growing for ~10s) -> "session ended" state.
//     Offers View full transcript + Branch from last point.
//
// Telemetry breadcrumbs:
//   found_watch / watch opened
//   found_watch / poll tick (sampled 1-in-5)
//   found_watch / stream paused
//   found_watch / session ended
//   found_watch / branch from watch

extension ConduitUI {

    struct FoundWatchView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let server: SavedServer
        let row: FoundSessionRow
        let features: SessionStore.BoxFeatures?
        let onBranch: (FoundSessionRow) -> Void

        // MARK: - State

        private enum WatchState: Equatable {
            case loading
            case watching
            case paused(String)    // last error message
            case ended
        }

        // Tri-state gate for the Branch-a-copy CTA (parity with FoundBranchSheet).
        //
        //   .checking  - capabilities probe in flight
        //   .failed    - probe returned nil (transient/unreachable/401) - offer Retry
        //   .ready(f)  - probe returned BoxFeatures (f.sessionFork may be true/false)
        //
        // Keeps "probe failed" distinct from "broker genuinely lacks session_fork".
        private enum ForkProbe {
            case checking
            case failed
            case ready(SessionStore.BoxFeatures)
        }

        @State private var watchState: WatchState = .loading
        @State private var forkProbe: ForkProbe = .checking
        @State private var items: [ConversationItem] = []
        @State private var latestTs: Int64 = 0
        /// Tracks how many consecutive ticks returned 0 new items.
        @State private var staleTickCount = 0
        /// Tracks consecutive poll failures.
        @State private var consecutiveFailures = 0
        /// Controls the live-pulse animation phase.
        @State private var pulseAnimating = false
        /// Poll task -- cancelled on disappear.
        @State private var pollTask: Task<Void, Never>?
        /// Held so startWatch() can drive a scroll cascade once items load.
        @State private var scrollProxy: ScrollViewProxy?

        /// Cap initial render of long transcripts (parity with ConduitChatView's
        /// visibleRowWindow). We only ever want the tail visible on open anyway.
        private let visibleRowWindow = 80

        private let pollInterval: TimeInterval = 2.5
        private let staleEndedThreshold = 4   // ~10s of no new items = ended
        private let maxConsecutiveFailures = 3 // after which we flip to paused

        var body: some View {
            NavigationStack {
                ZStack(alignment: .bottom) {
                    GlassAppBackground()
                    VStack(spacing: 0) {
                        watchingBanner
                        contentArea
                    }
                    bottomCTA
                }
                .navigationTitle(row.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            stopPolling()
                            dismiss()
                        }
                    }
                }
                .tint(neon.accent)
            }
            .appearanceColorScheme()
            .task { await startWatch() }
            .onDisappear { stopPolling() }
        }

        // MARK: - Watching banner

        private var watchingBanner: some View {
            HStack(spacing: 10) {
                liveDot
                VStack(alignment: .leading, spacing: 1) {
                    switch watchState {
                    case .loading:
                        Text("Loading session...")
                            .font(neon.sans(12).weight(.semibold))
                            .foregroundStyle(neon.textDim)
                    case .watching:
                        Text("Watching live -- read-only")
                            .font(neon.sans(12).weight(.semibold))
                            .foregroundStyle(neon.yellow)
                        Text("mirroring your terminal -- you're not driving")
                            .font(neon.mono(10))
                            .foregroundStyle(neon.textFaint)
                    case .paused:
                        Text("Stream paused -- reconnecting")
                            .font(neon.sans(12).weight(.semibold))
                            .foregroundStyle(neon.yellow)
                        Text("showing last known state -- retrying")
                            .font(neon.mono(10))
                            .foregroundStyle(neon.textFaint)
                    case .ended:
                        Text("Session ended")
                            .font(neon.sans(12).weight(.semibold))
                            .foregroundStyle(neon.textDim)
                        Text("the terminal session has finished")
                            .font(neon.mono(10))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(neon.surface.opacity(0.9))
            .overlay(
                Divider().background(neon.border),
                alignment: .bottom
            )
        }

        // MARK: - Live pulse dot
        //
        // The ONE looping animation in the Found Sessions feature.
        // accessibilityReduceMotion -> static amber dot, no animation.

        private var liveDot: some View {
            ZStack {
                if watchState == .watching && !reduceMotion {
                    Circle()
                        .fill(neon.yellow.opacity(pulseAnimating ? 0.0 : 0.35))
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulseAnimating ? 1.6 : 1.0)
                        .animation(
                            .easeOut(duration: 1.1).repeatForever(autoreverses: false),
                            value: pulseAnimating
                        )
                }
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 16, height: 16)
            .onAppear {
                if watchState == .watching && !reduceMotion {
                    pulseAnimating = true
                }
            }
            .onChange(of: watchState) { _, state in
                pulseAnimating = (state == .watching && !reduceMotion)
            }
        }

        private var dotColor: Color {
            switch watchState {
            case .loading: return neon.textFaint
            case .watching: return neon.yellow
            case .paused: return neon.yellow.opacity(0.5)
            case .ended: return neon.textFaint
            }
        }

        // MARK: - Content area

        @ViewBuilder
        private var contentArea: some View {
            switch watchState {
            case .loading:
                loadingState
            case .watching, .paused:
                transcriptContent
            case .ended:
                endedState
            }
        }

        private var loadingState: some View {
            VStack(spacing: 16) {
                Spacer()
                ProgressView()
                    .tint(neon.accent)
                    .controlSize(.large)
                Text("Loading session...")
                    .font(neon.sans(14))
                    .foregroundStyle(neon.textFaint)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private var transcriptContent: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    if items.isEmpty {
                        VStack(spacing: 12) {
                            Spacer(minLength: 40)
                            Image(systemName: "clock")
                                .font(.system(size: 28))
                                .foregroundStyle(neon.textFaint)
                            Text("Waiting for new messages...")
                                .font(neon.sans(13))
                                .foregroundStyle(neon.textFaint)
                            Spacer(minLength: 40)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(spacing: 0) {
                            // Window to the tail so long transcripts don't lay
                            // out every item on open (parity with ConduitChatView).
                            // The bottom anchor + autoscroll are unaffected -- we
                            // always keep the most recent rows.
                            let windowed = items.count > visibleRowWindow
                                ? Array(items.suffix(visibleRowWindow))
                                : items
                            ForEach(windowed, id: \.id) { item in
                                WatchTranscriptRow(item: item, neon: neon)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .padding(.bottom, 100) // room for pinned CTA
                    }

                    // Anchor for auto-scroll to bottom
                    Color.clear
                        .frame(height: 1)
                        .id("watch-bottom")
                }
                .onChange(of: items.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("watch-bottom", anchor: .bottom)
                    }
                }
                // Hold the proxy so startWatch() can fire the open cascade once
                // items load (a single .onAppear here is a no-op -- items are
                // empty at appear).
                .onAppear {
                    scrollProxy = proxy
                    proxy.scrollTo("watch-bottom", anchor: .bottom)
                }
            }
        }

        private var endedState: some View {
            VStack(spacing: 20) {
                Spacer()
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(neon.surface)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 26))
                            .foregroundStyle(neon.textFaint)
                    )
                VStack(spacing: 8) {
                    Text("Session ended")
                        .font(neon.sans(18).weight(.bold))
                        .foregroundStyle(neon.text)
                    Text("The terminal session finished. You can view the full transcript or branch a copy from the last saved point.")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                // Show transcript if we have items
                if !items.isEmpty {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 13, weight: .semibold))
                            Text("View full transcript")
                                .font(neon.sans(13).weight(.semibold))
                        }
                        .foregroundStyle(neon.accent)
                        .frame(maxWidth: 240)
                        .padding(.vertical, 12)
                        .neonCardSurface(neon, fill: neon.surface, cornerRadius: 10, border: neon.borderStrong)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }

        // MARK: - Bottom CTA

        private var bottomCTA: some View {
            VStack(spacing: 0) {
                Divider().background(neon.border)

                switch forkProbe {
                case .checking:
                    // State 1: probe in flight -- spinner, never "not available" copy
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(neon.textFaint)
                            .controlSize(.small)
                        Text("Checking this box...")
                            .font(neon.sans(14).weight(.semibold))
                            .foregroundStyle(neon.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(neon.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(neon.border, lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)

                case .failed:
                    // State 2: transient failure -- offer Retry, not "not available yet"
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.branch")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Branch a copy to take control")
                                .font(neon.sans(14).weight(.semibold))
                        }
                        .foregroundStyle(neon.textFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(neon.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(neon.border, lineWidth: 1)
                        )
                        .padding(.horizontal, 16)

                        HStack(spacing: 6) {
                            Text("Couldn't check this box \u{2014}")
                                .font(neon.mono(10))
                                .foregroundStyle(neon.textFaint)
                            Button {
                                Task { await probeFork() }
                            } label: {
                                Text("Retry")
                                    .font(neon.mono(10).weight(.bold))
                                    .foregroundStyle(neon.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)

                case .ready(let f) where f.sessionFork:
                    // State 4: broker supports fork -- enabled button
                    VStack(spacing: 0) {
                        Button {
                            Telemetry.breadcrumb("found_watch", "branch from watch",
                                data: ["id": row.externalID])
                            stopPolling()
                            dismiss()
                            onBranch(row)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.branch")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Branch a copy to take control")
                                    .font(neon.sans(14).weight(.semibold))
                            }
                            .foregroundStyle(neon.bg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(neon.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)

                        Text("watching never changes the session -- branch to drive your own copy")
                            .font(neon.mono(10))
                            .foregroundStyle(neon.textFaint)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                            .background(.ultraThinMaterial)
                    }

                default:
                    // State 3: probe succeeded but session_fork == false -- honest old-broker copy
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.branch")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Branch a copy to take control")
                                .font(neon.sans(14).weight(.semibold))
                        }
                        .foregroundStyle(neon.textFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(neon.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(neon.border, lineWidth: 1)
                        )
                        .padding(.horizontal, 16)

                        Text("Branching needs a newer broker on this box. Update it to enable.")
                            .font(neon.mono(10))
                            .foregroundStyle(neon.textFaint)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                }
            }
        }

        // MARK: - Watch lifecycle

        @MainActor
        private func probeFork() async {
            forkProbe = .checking
            Telemetry.breadcrumb("found_watch", "branch gate probe",
                data: ["host": server.endpoint.displayHost])
            if let f = await store.fetchBoxFeatures(endpoint: server.endpoint) {
                forkProbe = .ready(f)
                Telemetry.breadcrumb("found_watch", "branch gate ready",
                    data: ["host": server.endpoint.displayHost,
                           "fork": f.sessionFork ? "true" : "false"])
            } else {
                forkProbe = .failed
                Telemetry.breadcrumb("found_watch", "branch gate probe failed",
                    data: ["host": server.endpoint.displayHost])
            }
        }

        @MainActor
        private func startWatch() async {
            Telemetry.breadcrumb("found_watch", "watch opened",
                data: ["id": row.externalID, "agent": row.agent])

            // Run the fork-gate probe concurrently with the transcript fetch so
            // the CTA is ready by the time content appears.
            Task { await probeFork() }

            // Load full transcript first to get the initial cursor
            let fullItems = await store.fetchDiscoveredTranscript(
                endpoint: server.endpoint,
                agent: row.agent,
                externalID: row.externalID
            )
            guard let fullItems else {
                Telemetry.breadcrumb("found_watch", "initial load failed",
                    data: ["id": row.externalID])
                watchState = .paused("Could not load transcript")
                return
            }
            items = fullItems

            // The full transcript endpoint doesn't return latest_ts, so derive it
            // from the highest epoch-parsed ts in the fetched items. If none, use
            // current epoch ms so we only fetch truly new items from now on.
            // conduitConversationTsEpoch handles both plain and fractional ISO8601.
            let maxEpoch = fullItems.map { conduitConversationTsEpoch($0.ts) }
                .filter { $0 != .greatestFiniteMagnitude }
                .max()
            if let e = maxEpoch {
                latestTs = Int64(e * 1000)
            } else {
                latestTs = Int64(Date().timeIntervalSince1970 * 1000)
            }

            withAnimation { watchState = .watching }
            pulseAnimating = !reduceMotion

            // Anchor to the latest message on open. The transcript only just
            // became non-empty, and the LazyVStack resolves row heights lazily,
            // so a single jump lands short -- re-pin across the first few layout
            // passes (same trick as ConduitChatView.scrollToBottomOnOpen).
            Task { @MainActor in
                for delayMs: UInt64 in [16, 60, 200, 500] {
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    scrollProxy?.scrollTo("watch-bottom", anchor: .bottom)
                }
            }

            // Start polling
            // Capture self by value (View is a struct -- no reference cycle).
            let task = Task<Void, Never> {
                var tickIndex = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    await self.pollTick(tickIndex: tickIndex)
                    tickIndex += 1
                }
            }
            pollTask = task
        }

        @MainActor
        private func pollTick(tickIndex: Int) async {
            // Sample breadcrumb 1-in-5 to avoid spam
            if tickIndex % 5 == 0 {
                Telemetry.breadcrumb("found_watch", "poll tick",
                    data: ["id": row.externalID, "cursor": "\(latestTs)",
                           "tick": "\(tickIndex)"])
            }

            let result = await store.fetchDiscoveredTranscriptSince(
                endpoint: server.endpoint,
                agent: row.agent,
                externalID: row.externalID,
                sinceMs: latestTs
            )

            guard let (newItems, newTs) = result else {
                consecutiveFailures += 1
                if consecutiveFailures >= maxConsecutiveFailures && watchState == .watching {
                    Telemetry.breadcrumb("found_watch", "stream paused",
                        data: ["id": row.externalID, "failures": "\(consecutiveFailures)"])
                    withAnimation { watchState = .paused("Connection lost") }
                }
                return
            }

            // Successful poll -- reset failure counter and recover from paused
            consecutiveFailures = 0
            if case .paused = watchState {
                withAnimation { watchState = .watching }
                pulseAnimating = !reduceMotion
            }

            if !newItems.isEmpty {
                staleTickCount = 0
                withAnimation(.easeIn(duration: 0.2)) {
                    items.append(contentsOf: newItems)
                }
                if newTs > latestTs { latestTs = newTs }
            } else {
                // No new items -- check if session has ended
                staleTickCount += 1
                if staleTickCount >= staleEndedThreshold && watchState == .watching {
                    Telemetry.breadcrumb("found_watch", "session ended",
                        data: ["id": row.externalID, "stale_ticks": "\(staleTickCount)"])
                    withAnimation { watchState = .ended }
                    stopPolling()
                }
            }
        }

        private func stopPolling() {
            pollTask?.cancel()
            pollTask = nil
        }
    }
}

// MARK: - WatchTranscriptRow

/// A minimal read-only row for a single ConversationItem in the watch view.
/// Avoids the full ChatView machinery -- we only need role + content display.
private struct WatchTranscriptRow: View {
    let item: ConversationItem
    let neon: NeonTheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Role label
            Text(roleLabel)
                .font(neon.mono(9).weight(.bold))
                .foregroundStyle(roleTint)
                .frame(width: 40, alignment: .trailing)
                .padding(.top, 3)

            // Content
            Text(item.content)
                .font(neon.mono(12))
                .foregroundStyle(neon.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private var roleLabel: String {
        switch item.role.lowercased() {
        case "user": return "YOU"
        case "assistant": return item.kind == "tool" ? "TOOL" : "AGENT"
        default: return item.role.uppercased().prefix(5).description
        }
    }

    private var roleTint: Color {
        switch item.role.lowercased() {
        case "user": return neon.textDim
        case "assistant": return neon.accent
        default: return neon.yellow
        }
    }
}
