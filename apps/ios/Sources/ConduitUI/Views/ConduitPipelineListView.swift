import SwiftUI

// MARK: - ConduitPipelineListView
//
// Lists pipelines from `GET /api/pipelines` and opens
// `ConduitUI.PipelineMonitorView` for the tapped one. This closes the gap
// where a pipeline kept running server-side but became unreachable in the
// app the moment its creation sheet was dismissed -- the Builder's own
// post-create navigation (`ConduitPipelineBuilderView.swift`) was
// previously the ONLY path to the monitor.
//
// HOW TO PRESENT:
//   .sheet(isPresented: $showPipelines) {
//       ConduitUI.PipelineListView()
//           .environment(store)
//   }

extension ConduitUI {

    /// One row of `GET /api/pipelines`. Mirrors
    /// `broker/internal/ws/pipeline.go`'s `pipelineListItem` JSON shape.
    /// `state` is decoded as a raw string (not an enum) so an unrecognized
    /// future state from a newer broker never fails decode -- it just
    /// falls into the "active" default sort bucket (see
    /// `PipelineListViewModel.group(for:)`), staying visible instead of
    /// vanishing or crashing the list.
    struct PipelineSummary: Identifiable, Decodable, Hashable {
        let id: String
        let title: String
        let state: String
        let current_step: Int
        let step_count: Int
        let created: String?
        /// Per-step topology summary carried on each list item since broker
        /// #922 -- absent (nil) on an older broker. `FlowCard` uses this for
        /// a real `TopoMini` strip (agent dots + gate glyphs + per-step
        /// status) instead of the step_count-only degraded rendering. Must
        /// be `var`, not `let`: a `let` optional-with-default is silently
        /// EXCLUDED from the compiler-synthesized `init(from:)` (Swift never
        /// reads the JSON key at all -- see `PipelineStatus.result`).
        var steps: [PipelineSummaryStep]? = nil
        /// Diffstat-only recap, populated once the pipeline completes
        /// (broker #922). Absent on an older broker or a pre-#906 pipeline.
        var result: PipelineSummaryResult? = nil
    }

    /// One step's mini-topology entry on a `GET /api/pipelines` list item
    /// (broker #922 `pipelineStepSummary`). Mirrors the same
    /// phase+pipeline-context mapping `PipelineStepDisplayViewModel.state`
    /// computes from the full detail payload, precomputed broker-side.
    struct PipelineSummaryStep: Decodable, Hashable {
        let agent: String
        let role: String
        /// "queued" | "running" | "done" | "failed" | "awaiting_gate" | "awaiting_pick"
        let status: String
        let gate_after: Bool
    }

    /// Diffstat-only slice of `PipelineResult` carried on a completed list
    /// item (broker #922) -- output is deliberately omitted from the list
    /// endpoint (see `PipelineResult` for the full detail-view shape).
    struct PipelineSummaryResult: Decodable, Hashable {
        let files_changed: Int
        let insertions: Int
        let deletions: Int
        /// Absent when the broker predates #922 (`omitempty`).
        var finished: String? = nil
    }

    /// Pure sort/group helpers for the pipeline list -- lives off SwiftUI so
    /// they're unit-testable without a view tree (mirrors
    /// `ApprovalsViewModel` / `HomeViewModel`).
    enum PipelineListViewModel {
        enum Group: Int, Comparable {
            case needsYou = 0
            case active = 1
            case terminal = 2
            static func < (lhs: Group, rhs: Group) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        /// `awaiting_gate` / `awaiting_pick` need the user; `complete` /
        /// `failed` / `cancelled` are terminal; everything else (`pending`,
        /// `running`, `step_done`, and any unrecognized future state) is
        /// treated as active so new broker states stay visible rather than
        /// vanishing or misfiling as "needs you".
        static func group(for state: String) -> Group {
            switch state {
            case "awaiting_gate", "awaiting_pick": return .needsYou
            case "complete", "failed", "cancelled": return .terminal
            default: return .active
            }
        }

        /// Sort order: needs-you first, then active/running, then terminal
        /// pipelines most-recently-created first. Stable within the
        /// needs-you/active groups (preserves broker list order); terminal
        /// pipelines sort by `created` descending (ISO8601 strings sort
        /// lexicographically).
        static func sorted(_ items: [PipelineSummary]) -> [PipelineSummary] {
            items.enumerated().sorted { a, b in
                let ga = group(for: a.element.state)
                let gb = group(for: b.element.state)
                if ga != gb { return ga < gb }
                if ga == .terminal {
                    let ca = a.element.created ?? ""
                    let cb = b.element.created ?? ""
                    if ca != cb { return ca > cb }
                }
                return a.offset < b.offset
            }.map { $0.element }
        }

        /// Home's "any pipeline active" affordance gate -- explicitly the
        /// three live states (running / awaiting_gate / awaiting_pick), not
        /// every non-terminal state, per spec.
        static func isActiveForHomeAffordance(_ state: String) -> Bool {
            state == "running" || state == "awaiting_gate" || state == "awaiting_pick"
        }

        /// Home's "recently finished" affordance gate: a pipeline that
        /// reached `complete` or `failed` within the last 24h. Keeps a
        /// just-finished pipeline visible on Home instead of vanishing the
        /// instant its last step settles (only reachable via the full
        /// Pipelines list before this) -- but doesn't resurrect arbitrarily
        /// old history.
        ///
        /// `GET /api/pipelines` carries only `created` (no top-level
        /// "ended" timestamp), so this uses `created` as the recency
        /// signal -- a reasonable proxy since pipelines are short-lived
        /// (minutes to low hours), not a precise completion time.
        /// `cancelled` is deliberately excluded (an explicit user action,
        /// not a completion the user needs surfaced back to them).
        static func isRecentTerminal(_ summary: PipelineSummary, now: Date = Date()) -> Bool {
            guard summary.state == "complete" || summary.state == "failed" else { return false }
            guard let created = summary.created,
                  let createdDate = ISO8601DateFormatter().date(from: created) else { return false }
            return now.timeIntervalSince(createdDate) <= 24 * 3600
        }
    }

    struct PipelineListView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        @State private var pipelines: [PipelineSummary] = []
        @State private var isLoading = true
        @State private var selectedPipeline: PipelineSummary?

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    if pipelines.isEmpty {
                        emptyState
                    } else {
                        List {
                            ForEach(PipelineListViewModel.sorted(pipelines)) { p in
                                pipelineRow(p)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        Telemetry.breadcrumb("pipeline", "reentered monitor",
                                            data: ["id_prefix": String(p.id.prefix(8))])
                                        selectedPipeline = p
                                    }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .refreshable { await load() }
                    }
                }
                .navigationTitle("Flows")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                            .foregroundStyle(neon.textDim)
                    }
                }
                .navigationDestination(item: $selectedPipeline) { p in
                    ConduitUI.PipelineMonitorView(
                        pipelineID: p.id,
                        pipelineTitle: p.title.isEmpty ? "Flow" : p.title
                    )
                    .environment(store)
                }
            }
            .appearanceColorScheme()
            .tint(neon.accent)
            .task { await load() }
        }

        private var emptyState: some View {
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView().tint(neon.accent)
                    Text("Loading flows...")
                        .font(neon.sans(14))
                        .foregroundStyle(neon.textDim)
                } else {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(neon.textFaint)
                    Text("No flows yet")
                        .font(neon.sans(15).weight(.semibold))
                        .foregroundStyle(neon.text)
                    Text("Flows you create keep running here even after you close the sheet.")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func pipelineRow(_ p: PipelineSummary) -> some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.title.isEmpty ? "Flow" : p.title)
                        .font(neon.sans(14).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    Text("Step \(min(p.current_step + 1, max(p.step_count, 1))) / \(max(p.step_count, 1))")
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textDim)
                }
                Spacer(minLength: 8)
                stateChip(p.state)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(neon.textFaint)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private func stateChip(_ state: String) -> some View {
            let (label, color): (String, Color) = {
                switch state {
                case "running":       return ("Running", neon.accent)
                case "awaiting_gate": return ("Needs you", neon.yellow)
                case "awaiting_pick": return ("Needs you", neon.yellow)
                case "complete":      return ("Complete", neon.textDim)
                case "failed":        return ("Failed", neon.red)
                case "cancelled":     return ("Cancelled", neon.textFaint)
                default:              return (state, neon.textFaint)
                }
            }()
            return ConduitUI.Chip(label: label, tint: color)
        }

        private func load() async {
            isLoading = true
            defer { isLoading = false }
            let fetched = await store.refreshPipelines()
            pipelines = fetched
            Telemetry.breadcrumb("pipeline", "list opened", data: ["count": "\(fetched.count)"])
        }
    }
}
