import SwiftUI

// MARK: - ConduitFlowBranchEditorSheet
//
// "Flow" (pipeline v2) redesign, PR B -- design_handoff_flow/README.md
// "Screens > C2. Branch edit". Edits an If/Else control-flow block: maps
// onto the EXISTING `PipelineStep.kind == "branch"` fields (condition +
// branchThen/branchElse) via `PipelineBuilderViewModel`'s sub-stack editing
// -- same semantics/wire shape as the old builder's control-flow editor,
// just a fresh layout (no Loop surfaced here, per PR scope -- the model
// still supports it).

extension ConduitUI {

    struct FlowBranchEditorSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let viewModel: PipelineBuilderViewModel
        let stepID: PipelineStep.ID
        let index: Int

        /// design_handoff_review_fixes R1: which sub-step's full editor is
        /// open, if any -- `.sheet(item:)` (not `isPresented:`) so a new
        /// selection always re-seeds sheet identity, matching the pattern
        /// `FlowWizardView` already uses for the top-level step/branch
        /// sheets.
        @State private var selectedSubStepTarget: SubStepEditTarget?

        private static let prevOutputPredicates = ["contains", "not_contains", "matches"]

        private var step: Binding<PipelineStep> {
            Binding(
                get: { index < viewModel.steps.count ? viewModel.steps[index] : PipelineStep(kind: "branch") },
                set: { if index < viewModel.steps.count { viewModel.steps[index] = $0 } }
            )
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            conditionCard
                            thenSection
                            elseSection
                        }
                        .padding(16)
                        .padding(.bottom, 90)
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle("New step \u{00B7} If / Else")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) { footer }
            }
            .tint(neon.accent)
            .sheet(item: $selectedSubStepTarget) { target in
                ConduitUI.FlowStepEditorSheet(viewModel: viewModel, subStepTarget: target)
                    .environment(store)
            }
        }

        // MARK: Condition

        private var conditionCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("If").font(neon.sans(14)).foregroundStyle(neon.textDim)
                    Menu {
                        Button("prev output") { step.wrappedValue.branchConditionSource = "prev_output" }
                        Button("exit status") { step.wrappedValue.branchConditionSource = "exit_status" }
                    } label: {
                        conditionChip(step.wrappedValue.branchConditionSource == "exit_status" ? "exit status" : "prev output")
                    }
                    if step.wrappedValue.branchConditionSource == "prev_output" {
                        Menu {
                            ForEach(Self.prevOutputPredicates, id: \.self) { p in
                                Button(p.replacingOccurrences(of: "_", with: " ")) {
                                    step.wrappedValue.branchConditionPredicate = p
                                }
                            }
                        } label: {
                            conditionChip(step.wrappedValue.branchConditionPredicate.replacingOccurrences(of: "_", with: " "))
                        }
                    } else {
                        Menu {
                            Button("succeeded") { step.wrappedValue.branchConditionPredicate = "succeeded" }
                            Button("failed") { step.wrappedValue.branchConditionPredicate = "failed" }
                        } label: {
                            conditionChip(step.wrappedValue.branchConditionPredicate)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if step.wrappedValue.branchConditionSource == "prev_output" {
                    TextField("value to match", text: step.branchConditionValue)
                        .font(neon.mono(13))
                        .foregroundStyle(neon.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(neon.lineSoft, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private func conditionChip(_ label: String) -> some View {
            Text(label)
                .font(neon.mono(11.5).weight(.semibold))
                .foregroundStyle(neon.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().stroke(neon.accent.opacity(0.4), lineWidth: 1))
        }

        // MARK: Then / Else

        private var thenSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(neon.green).frame(width: 7, height: 7)
                    Text("THEN").font(neon.mono(11).weight(.bold)).foregroundStyle(neon.green)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(step.wrappedValue.branchThen) { sub in
                        subStepRow(sub, arm: .then)
                    }
                    addStepGhostButton(tint: neon.green, arm: .then)
                }
                .padding(.leading, 12)
                .overlay(Rectangle().fill(neon.green.opacity(0.27)).frame(width: 2), alignment: .leading)
            }
        }

        private var elseSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(neon.textFaint).frame(width: 7, height: 7)
                    Text("ELSE \u{2014} CONTINUE DOWN").font(neon.mono(11).weight(.bold)).foregroundStyle(neon.textFaint)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if step.wrappedValue.branchElse.isEmpty {
                        Text("No else steps \u{2014} the flow just moves on.")
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                    } else {
                        ForEach(step.wrappedValue.branchElse) { sub in
                            subStepRow(sub, arm: .elseArm)
                        }
                    }
                    addStepGhostButton(tint: neon.textDim, arm: .elseArm)
                }
                .padding(.leading, 12)
                .overlay(Rectangle().fill(neon.lineSoft).frame(width: 2), alignment: .leading)
            }
        }

        /// design_handoff_flow audit §D.13: shared ghost-button styling
        /// (plus glyph + label, no fill) for the THEN/ELSE "+ Add step"
        /// rows -- THEN reads in green, ELSE stays faint.
        ///
        /// design_handoff_review_fixes R1: "Add step" no longer just appends
        /// a blank row -- it opens the full step editor immediately on the
        /// fresh sub-step (role "custom" per `addSubStep`), so the user
        /// lands straight in agent/role/prompt instead of an empty card.
        private func addStepGhostButton(tint: Color, arm: PipelineSubStepArm) -> some View {
            Button {
                viewModel.addSubStep(stepID: stepID, arm: arm)
                Telemetry.breadcrumb("flow_wizard", arm == .then ? "branch then add" : "branch else add", data: [:])
                if let newID = subSteps(for: arm).last?.id {
                    selectedSubStepTarget = SubStepEditTarget(stepID: stepID, arm: arm, subStepID: newID)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add step")
                }
                .font(neon.sans(12.5).weight(.semibold))
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
        }

        private func subSteps(for arm: PipelineSubStepArm) -> [PipelineSubStep] {
            switch arm {
            case .then: return step.wrappedValue.branchThen
            case .elseArm: return step.wrappedValue.branchElse
            case .body: return []
            }
        }

        /// design_handoff_review_fixes R1: a branch sub-step is the SAME
        /// step card as the main rail -- tapping it opens the full step
        /// editor (agent/role/prompt/gate/advanced) rather than the old
        /// add/remove-only row. Delete now lives inside that editor, so
        /// there is no minus badge here.
        @ViewBuilder
        private func subStepRow(_ sub: PipelineSubStep, arm: PipelineSubStepArm) -> some View {
            Button {
                selectedSubStepTarget = SubStepEditTarget(stepID: stepID, arm: arm, subStepID: sub.id)
            } label: {
                HStack(spacing: 10) {
                    ConduitUI.AgentDot(agent: sub.agentType, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sub.role.capitalized).font(neon.sans(13.5).weight(.semibold)).foregroundStyle(neon.text)
                        subStepPreview(sub)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                }
                .padding(10)
                .neonCardSurface(neon, fill: neon.surface2.opacity(0.5), cornerRadius: 12)
            }
            .buttonStyle(.plain)
        }

        /// "<agent> \u{00B7} \u{201C}<prompt, truncated>\u{201D}" in mono,
        /// accent-tinted quoted prompt -- falls back to "sees prev output"
        /// when the sub-step has no prompt yet (ds-review.jsx RvBranchFixed).
        private func subStepPreview(_ sub: PipelineSubStep) -> some View {
            Group {
                if sub.promptTemplate.isEmpty {
                    Text("\(sub.agentType) \u{00B7} sees prev output")
                        .foregroundStyle(neon.textFaint)
                } else {
                    Text("\(sub.agentType) \u{00B7} ").foregroundStyle(neon.textFaint)
                        + Text("\u{201C}\(truncatedPrompt(sub.promptTemplate))\u{201D}").foregroundStyle(neon.accent)
                }
            }
            .font(neon.mono(10.5))
            .lineLimit(1)
            .truncationMode(.tail)
        }

        private func truncatedPrompt(_ text: String, limit: Int = 46) -> String {
            guard text.count > limit else { return text }
            return String(text.prefix(limit)) + "\u{2026}"
        }

        // MARK: Footer

        private var footer: some View {
            VStack(spacing: 0) {
                Rectangle().fill(neon.border).frame(height: 1)
                // design_handoff_flow audit §D.12: Discard reads as a
                // secondary (red) button at 1:2 width against the primary
                // "Add to flow" -- HStack layoutPriority alone can't express
                // a ratio, so Discard is pinned to a third of the row.
                HStack(spacing: 10) {
                    ConduitUI.ActionButton("Discard", variant: .secondary, tint: neon.red) {
                        Telemetry.breadcrumb("flow_wizard", "branch discard", data: [:])
                        viewModel.removeStep(id: stepID)
                        dismiss()
                    }
                    .frame(width: discardWidth)

                    ConduitUI.ActionButton("Add to flow", variant: .primary, tint: neon.accent) {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { footerWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newValue in footerWidth = newValue }
                    }
                )
            }
            .background(neon.bg.ignoresSafeArea(edges: .bottom))
        }

        @State private var footerWidth: CGFloat = 0
        private var discardWidth: CGFloat {
            // 1:2 ratio vs "Add to flow" -- Discard is one third of the row
            // (footerWidth already includes the 10pt inter-button spacing),
            // falling back to a sane fixed width before the first layout
            // pass reports a real size.
            footerWidth > 0 ? max(80, (footerWidth - 10) / 3) : 100
        }
    }
}
