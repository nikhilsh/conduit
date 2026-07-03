import SwiftUI

// MARK: - ConduitPipelineMonitorView
//
// Monitor a live pipeline. Polls GET /api/pipeline/{id} every 5 seconds
// until the pipeline reaches a terminal state (complete / failed /
// cancelled). Supports gated pipelines (awaiting_gate) and cancellation.

extension ConduitUI {

    // MARK: - Pipeline poll models

    struct PipelineStepStatus: Identifiable, Decodable {
        var id: Int { index }
        let index: Int
        let agent_type: String
        let role: String
        let prompt_template: String
        let input_from_prev: String
        let gate_after: Bool
        let session_id: String?
        let phase: String?
        let started: String?
        let ended: String?

        var isRunning: Bool {
            guard let p = phase else { return false }
            return p == "running" || p == "ready"
        }

        var isDone: Bool {
            guard let p = phase else { return false }
            return p == "exited(0)" || p == "exited"
        }

        var isFailed: Bool {
            guard let p = phase else { return false }
            return p.hasPrefix("exited") && !isDone
        }
    }

    /// Gate metadata returned by the broker when a pipeline is in the
    /// `awaiting_gate` state. Present only when the broker supports the
    /// `pipeline_gate_preview` capability.
    struct PipelineGate: Decodable {
        /// Index of the completed gated step.
        let step: Int
        /// Computed `{{prev}}` handoff text for the next step. May be empty.
        let prev: String
        /// Final assistant text from the gated step. May be absent.
        let output: String?

        enum CodingKeys: String, CodingKey {
            case step
            case prev
            case output
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            step   = try c.decodeIfPresent(Int.self,    forKey: .step)   ?? 0
            prev   = try c.decodeIfPresent(String.self, forKey: .prev)   ?? ""
            output = try c.decodeIfPresent(String.self, forKey: .output)
        }
    }

    struct PipelineStatus: Decodable {
        let id: String
        let title: String
        let task: String
        let cwd: String
        let base: String
        let state: String
        let current_step: Int
        let steps: [PipelineStepStatus]
        /// Present only when state == "awaiting_gate" and broker supports
        /// `pipeline_gate_preview`.
        let gate: PipelineGate?

        var isTerminal: Bool {
            state == "complete" || state == "failed" || state == "cancelled"
        }

        var isAwaitingGate: Bool { state == "awaiting_gate" }
    }

    // MARK: - Monitor view

    struct PipelineMonitorView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let pipelineID: String
        let pipelineTitle: String

        @State private var pipeline: PipelineStatus? = nil
        @State private var pollTask: Task<Void, Never>? = nil
        @State private var lastState: String = ""
        @State private var isContinuing = false
        @State private var showCancelAlert = false
        @State private var errorBanner: String? = nil
        @State private var selectedSessionID: String? = nil
        // Gate handoff edit state
        @State private var isEditingHandoff = false
        @State private var handoffDraft: String = ""

        var body: some View {
            ZStack {
                GlassAppBackground()
                if let p = pipeline {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            stateHeader(p)
                            stepsList(p)
                            if p.isAwaitingGate {
                                gateCard(p)
                            }
                            if p.state == "failed" {
                                failedCard(p)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .navigationDestination(item: $selectedSessionID) { id in
                        if let session = store.sessions.first(where: { $0.id == id }) {
                            ConduitUI.ProjectView(session: session)
                        } else {
                            Color.clear
                        }
                    }
                } else if errorBanner == nil {
                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(neon.accent)
                        Text("Loading pipeline...")
                            .font(neon.sans(14))
                            .foregroundStyle(neon.textDim)
                    }
                }

                if let err = errorBanner {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(neon.red)
                            Text(err)
                                .font(neon.sans(13))
                                .foregroundStyle(neon.text)
                                .lineLimit(2)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                    }
                }
            }
            .navigationTitle(pipelineTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if pipeline?.isTerminal == false {
                        Button {
                            showCancelAlert = true
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(neon.red)
                        }
                    }
                }
            }
            .alert("Cancel pipeline?", isPresented: $showCancelAlert) {
                Button("Cancel pipeline", role: .destructive) {
                    cancelPipeline()
                }
                Button("Keep running", role: .cancel) {}
            } message: {
                Text("This will stop all running steps.")
            }
            .tint(neon.accent)
            .onAppear {
                Telemetry.breadcrumb("pipeline", "monitor opened",
                    data: ["id": pipelineID])
                startPolling()
            }
            .onDisappear {
                pollTask?.cancel()
            }
        }

        // MARK: State header

        private func stateHeader(_ p: PipelineStatus) -> some View {
            HStack(spacing: 10) {
                stateChip(p.state)
                Spacer(minLength: 8)
                Text("Step \(p.current_step + 1) / \(p.steps.count)")
                    .font(neon.mono(12).weight(.semibold))
                    .foregroundStyle(neon.textDim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private func stateChip(_ state: String) -> some View {
            let (label, color): (String, Color) = {
                switch state {
                case "running":       return ("Running", neon.accent)
                case "complete":      return ("Complete", neon.green)
                case "failed":        return ("Failed", neon.red)
                case "cancelled":     return ("Cancelled", neon.textDim)
                case "awaiting_gate": return ("Gate", neon.yellow)
                default:              return (state, neon.textFaint)
                }
            }()
            return Text(label)
                .font(neon.mono(11).weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(color.opacity(0.14)))
                .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
        }

        // MARK: Steps list

        private func stepsList(_ p: PipelineStatus) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Steps")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)

                ForEach(p.steps) { step in
                    stepRow(step: step, pipeline: p)
                }
            }
        }

        private func stepRow(step: PipelineStepStatus, pipeline: PipelineStatus) -> some View {
            let stepState = stepDisplayState(step: step, pipeline: pipeline)
            let (stateLabel, stateColor) = stepStateDisplay(stepState)
            let isCurrentStep = step.index == pipeline.current_step && !pipeline.isTerminal

            return HStack(spacing: 12) {
                AgentAvatar(assistant: step.agent_type, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(step.role.capitalized)
                            .font(neon.sans(13).weight(.semibold))
                            .foregroundStyle(neon.text)
                        Text("#\(step.index + 1)")
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                    }
                    Text(step.agent_type)
                        .font(neon.mono(10))
                        .foregroundStyle(neon.textFaint)
                }

                Spacer(minLength: 6)

                // State chip
                Text(stateLabel)
                    .font(neon.mono(10).weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(stateColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(stateColor.opacity(0.14)))

                // Chevron if session is available
                if step.session_id != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(neon.textFaint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(
                neon,
                fill: isCurrentStep ? neon.accent.opacity(neon.dark ? 0.10 : 0.07) : neon.surface,
                cornerRadius: 12,
                glowTint: isCurrentStep && neon.glow ? neon.accent : nil
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                if let sid = step.session_id {
                    Telemetry.breadcrumb("pipeline", "monitor step open",
                        data: ["id": pipelineID, "step": "\(step.index)", "session": sid])
                    selectedSessionID = sid
                }
            }
        }

        private enum StepDisplayState {
            case queued, running, done, failed, awaitingGate
        }

        private func stepDisplayState(step: PipelineStepStatus, pipeline: PipelineStatus) -> StepDisplayState {
            if step.session_id == nil { return .queued }
            if step.isDone { return .done }
            if step.isFailed { return .failed }
            if step.isRunning {
                if pipeline.isAwaitingGate && step.index == pipeline.current_step {
                    return .awaitingGate
                }
                return .running
            }
            return .queued
        }

        private func stepStateDisplay(_ state: StepDisplayState) -> (String, Color) {
            switch state {
            case .queued:       return ("queued", neon.textFaint)
            case .running:      return ("running", neon.accent)
            case .done:         return ("done", neon.green)
            case .failed:       return ("failed", neon.red)
            case .awaitingGate: return ("gate", neon.yellow)
            }
        }

        // MARK: Gate card

        private func gateCard(_ p: PipelineStatus) -> some View {
            let gate = p.gate
            // Determine the preview text: prefer prev, then output, then nil (show generic text).
            let previewText: String? = {
                if let g = gate {
                    if !g.prev.isEmpty { return g.prev }
                    if let out = g.output, !out.isEmpty { return out }
                }
                return nil
            }()
            let showGatePreview = store.pipelineGatePreview && gate != nil

            return VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(neon.yellow)
                    Text("Waiting for approval")
                        .font(neon.sans(14).weight(.semibold))
                        .foregroundStyle(neon.text)
                }

                if showGatePreview, let preview = previewText {
                    // Handoff preview block
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Handoff preview")
                                .font(neon.mono(11).weight(.bold))
                                .foregroundStyle(neon.textDim)
                                .textCase(.uppercase)
                            Spacer(minLength: 4)
                            // Edit toggle button
                            Button {
                                if !isEditingHandoff {
                                    handoffDraft = gate?.prev ?? ""
                                    Telemetry.breadcrumb("pipeline", "gate handoff edited",
                                        data: ["id": pipelineID, "step": "\(p.current_step)"])
                                }
                                isEditingHandoff.toggle()
                            } label: {
                                Text(isEditingHandoff ? "Done" : "Edit handoff")
                                    .font(neon.mono(11).weight(.semibold))
                                    .foregroundStyle(neon.accent)
                            }
                            .buttonStyle(.plain)
                        }

                        if isEditingHandoff {
                            // Editable TextEditor, fixed 240pt height. No fixedSize:
                            // avoid greedy-height (iOS footgun: fixedSize overrides frame cap).
                            TextEditor(text: $handoffDraft)
                                .font(neon.mono(12))
                                .foregroundStyle(neon.text)
                                .scrollContentBackground(.hidden)
                                .background(neon.surface2)
                                .frame(height: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(neon.borderStrong, lineWidth: 1)
                                )
                        } else {
                            // Read-only scrollable preview, hard-capped at 240pt.
                            // Do NOT use .frame(maxHeight:.infinity) or fixedSize here;
                            // that makes the ScrollView greedy and eats VStack space.
                            ScrollView(.vertical) {
                                Text(preview)
                                    .font(neon.mono(12))
                                    .foregroundStyle(neon.textDim)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(height: 240)
                            .background(neon.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(neon.borderStrong, lineWidth: 1)
                            )
                        }
                    }
                    .onAppear {
                        Telemetry.breadcrumb("pipeline", "gate preview shown",
                            data: ["id": pipelineID, "step": "\(p.current_step)",
                                   "prev_len": "\(gate?.prev.count ?? 0)"])
                    }
                } else if !showGatePreview {
                    Text("Step \(p.current_step + 1) has finished and is gated. Review the output, then continue the pipeline.")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    let edited = isEditingHandoff && handoffDraft != (gate?.prev ?? "")
                    Telemetry.breadcrumb("pipeline", "gate continue tapped",
                        data: ["id": pipelineID, "step": "\(p.current_step)",
                               "edited": edited ? "true" : "false"])
                    let prevOverride = edited ? handoffDraft : nil
                    continuePipeline(prevOverride: prevOverride)
                } label: {
                    HStack(spacing: 6) {
                        if isContinuing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(neon.accentText)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                        }
                        Text(isContinuing ? "Continuing..." : "Continue")
                            .font(neon.sans(14).weight(.bold))
                    }
                    .foregroundStyle(neon.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(neon.yellow)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isContinuing)
                .opacity(isContinuing ? 0.7 : 1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(
                neon,
                fill: neon.yellow.opacity(neon.dark ? 0.07 : 0.05),
                cornerRadius: 14,
                border: neon.yellow.opacity(0.27),
                glowTint: neon.glow ? neon.yellow : nil
            )
        }

        // MARK: Failed card

        private func failedCard(_ p: PipelineStatus) -> some View {
            let failedStep = p.steps.first(where: { $0.isFailed }) ?? p.steps[safe: p.current_step]

            return VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(neon.red)
                    Text("Pipeline failed")
                        .font(neon.sans(14).weight(.semibold))
                        .foregroundStyle(neon.text)
                }

                if let step = failedStep, let sid = step.session_id {
                    Button {
                        Telemetry.breadcrumb("pipeline", "failed open session",
                            data: ["id": pipelineID, "step": "\(step.index)", "session": sid])
                        selectedSessionID = sid
                    } label: {
                        Text("Open session for step \(step.index + 1)")
                            .font(neon.sans(13).weight(.semibold))
                            .foregroundStyle(neon.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(neon.surface2))
                            .overlay(Capsule().stroke(neon.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(
                neon,
                fill: neon.red.opacity(neon.dark ? 0.07 : 0.05),
                cornerRadius: 14,
                border: neon.red.opacity(0.27)
            )
        }

        // MARK: - Polling

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    await fetchPipeline()
                    if let p = pipeline, p.isTerminal { break }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }

        private func fetchPipeline() async {
            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/pipeline/\(pipelineID)"
            guard let url = components?.url else { return }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { return }
                if http.statusCode >= 200 && http.statusCode < 300,
                   let parsed = try? JSONDecoder().decode(PipelineStatus.self, from: data) {
                    // Breadcrumb on state transitions
                    if parsed.state != lastState {
                        Telemetry.breadcrumb("pipeline", "state changed",
                            data: ["id": pipelineID, "from": lastState, "to": parsed.state])
                        lastState = parsed.state
                    }
                    pipeline = parsed
                    errorBanner = nil
                } else {
                    let msg = "Poll failed: HTTP \(http.statusCode)"
                    errorBanner = msg
                    Telemetry.capture(
                        error: NSError(domain: "ios.pipeline", code: 10,
                            userInfo: [NSLocalizedDescriptionKey: "pipeline poll failed"]),
                        message: "pipeline poll failed",
                        tags: ["surface": "ios", "phase": "pipeline"],
                        extras: ["id": pipelineID, "status": "\(http.statusCode)"]
                    )
                }
            } catch {
                if !Task.isCancelled {
                    errorBanner = error.localizedDescription
                    Telemetry.capture(
                        error: error,
                        message: "pipeline poll network error",
                        tags: ["surface": "ios", "phase": "pipeline"],
                        extras: ["id": pipelineID]
                    )
                }
            }
        }

        // MARK: - Continue (gate)

        private func continuePipeline(prevOverride: String? = nil) {
            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/pipeline/\(pipelineID)/continue"
            guard let url = components?.url else { return }

            isContinuing = true
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Only include {"prev": ...} when the user edited the handoff text.
            if let prev = prevOverride,
               let body = try? JSONSerialization.data(withJSONObject: ["prev": prev]) {
                req.httpBody = body
            } else {
                req.httpBody = Data("{}".utf8)
            }

            Task { @MainActor in
                defer { isContinuing = false }
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else { return }
                    if http.statusCode >= 200 && http.statusCode < 300 {
                        Telemetry.breadcrumb("pipeline", "gate continue ok",
                            data: ["id": pipelineID])
                        // Re-poll immediately
                        await fetchPipeline()
                        if pipeline?.isTerminal == false {
                            startPolling()
                        }
                    } else {
                        errorBanner = "Continue failed: HTTP \(http.statusCode)"
                        Telemetry.capture(
                            error: NSError(domain: "ios.pipeline", code: 11,
                                userInfo: [NSLocalizedDescriptionKey: "pipeline continue failed"]),
                            message: "pipeline continue failed",
                            tags: ["surface": "ios", "phase": "pipeline"],
                            extras: ["id": pipelineID, "status": "\(http.statusCode)"]
                        )
                    }
                } catch {
                    errorBanner = error.localizedDescription
                    Telemetry.capture(
                        error: error,
                        message: "pipeline continue network error",
                        tags: ["surface": "ios", "phase": "pipeline"],
                        extras: ["id": pipelineID]
                    )
                }
            }
        }

        // MARK: - Cancel

        private func cancelPipeline() {
            Telemetry.breadcrumb("pipeline", "cancel tapped", data: ["id": pipelineID])
            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/pipeline/\(pipelineID)"
            guard let url = components?.url else { return }

            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")

            Task { @MainActor in
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse,
                       http.statusCode >= 200 && http.statusCode < 300 {
                        Telemetry.breadcrumb("pipeline", "cancel ok", data: ["id": pipelineID])
                        pollTask?.cancel()
                        await fetchPipeline()
                    }
                } catch {
                    Telemetry.breadcrumb("pipeline", "cancel error",
                        data: ["id": pipelineID, "error": error.localizedDescription])
                }
            }
        }
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
