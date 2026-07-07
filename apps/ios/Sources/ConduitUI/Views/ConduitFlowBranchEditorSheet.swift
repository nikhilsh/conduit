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
                .navigationTitle("If / Else")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) { footer }
            }
            .tint(neon.accent)
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
                    Button {
                        viewModel.addSubStep(stepID: stepID, arm: .then)
                        Telemetry.breadcrumb("flow_wizard", "branch then add", data: [:])
                    } label: {
                        Text("+ Add step").font(neon.sans(12.5).weight(.semibold)).foregroundStyle(neon.green)
                    }
                    .buttonStyle(.plain)
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
                    Button {
                        viewModel.addSubStep(stepID: stepID, arm: .elseArm)
                        Telemetry.breadcrumb("flow_wizard", "branch else add", data: [:])
                    } label: {
                        Text("+ Add step").font(neon.sans(12.5).weight(.semibold)).foregroundStyle(neon.textDim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
                .overlay(Rectangle().fill(neon.lineSoft).frame(width: 2), alignment: .leading)
            }
        }

        @ViewBuilder
        private func subStepRow(_ sub: PipelineSubStep, arm: PipelineSubStepArm) -> some View {
            HStack(spacing: 10) {
                ConduitUI.AgentDot(agent: sub.agentType, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.role.capitalized).font(neon.sans(13.5).weight(.semibold)).foregroundStyle(neon.text)
                    Text("\(sub.agentType) \u{00B7} sees prev output")
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textFaint)
                }
                Spacer(minLength: 8)
                Button {
                    viewModel.removeSubStep(stepID: stepID, arm: arm, subStepID: sub.id)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(neon.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .neonCardSurface(neon, fill: neon.surface2.opacity(0.5), cornerRadius: 12)
        }

        // MARK: Footer

        private var footer: some View {
            VStack(spacing: 0) {
                Rectangle().fill(neon.border).frame(height: 1)
                HStack(spacing: 10) {
                    Button {
                        Telemetry.breadcrumb("flow_wizard", "branch discard", data: [:])
                        viewModel.removeStep(id: stepID)
                        dismiss()
                    } label: {
                        Text("Discard")
                            .font(neon.sans(14).weight(.semibold))
                            .foregroundStyle(neon.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    ConduitUI.ActionButton("Add to flow", variant: .primary, tint: neon.accent) {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(neon.bg.ignoresSafeArea(edges: .bottom))
        }
    }
}
