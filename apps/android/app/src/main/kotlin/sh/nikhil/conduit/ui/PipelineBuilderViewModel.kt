package sh.nikhil.conduit.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import sh.nikhil.conduit.ui.components.PipelineTopologyItem

/**
 * PLAN-HARNESS-BUILDER Phase 2 (docs/PLAN-HARNESS-BUILDER.md §3). Pure-data
 * state holder for the visual pipeline Builder -- extracted so BOTH the
 * phone (stacked list + config sheet) and tablet (two-pane rail + inspector)
 * layouts read the SAME steps list rather than each keeping its own copy.
 * Mirror of iOS `ConduitUI.PipelineBuilderViewModel`.
 *
 * Deliberately holds ONLY the ordered steps + selection -- title/task/cwd/
 * base and networking (template load/save/delete, submit) stay in
 * `FlowWizardScreen` (they need `SessionStore`/`Telemetry` access a
 * pure model shouldn't own). The wire encoder (`stepDraftToJson`) is
 * UNCHANGED from Phase 1 -- this view model only reshapes how steps are
 * edited, never how they're encoded, so create-request JSON stays
 * byte-identical to the Phase-1 form for an equivalent config.
 *
 * Built on `androidx.compose.runtime` state (pure Kotlin, no Android
 * framework dependency) so it is directly JUnit-testable without
 * Robolectric.
 */
class PipelineBuilderViewModel(initialSteps: List<PipelineStepDraft> = listOf(PipelineStepDraft.starter())) {

    var steps: List<PipelineStepDraft> by mutableStateOf(initialSteps)
        private set

    /** The step shown in the config sheet (phone) / inspector (tablet). */
    var selectedStepId: String? by mutableStateOf(initialSteps.firstOrNull()?.id)

    val canDeleteStep: Boolean get() = steps.size > 1

    fun addStep() {
        // First top-level step defaults to "researcher" (kick off with
        // investigation); every step after that defaults to "engineer"
        // (build on prior work) -- device feedback: a fresh step showed
        // role "Engineer" with an empty prompt, so seed both role AND its
        // canned prompt template together. Mirror of iOS
        // `PipelineBuilderViewModel.addStep`.
        val role = if (steps.isEmpty()) "researcher" else "engineer"
        // Task-2a fix (config-sheet redesign): a step after the first
        // defaults to "output" so the previous step's reply actually
        // reaches it -- the plain "none" default was a silent no-handoff
        // bug the owner hit directly. Step 0 keeps "none" (there is no
        // previous step).
        val s = PipelineStepDraft(
            role = role,
            promptTemplate = PipelineStepDraft.defaultPromptTemplate(role),
            inputFromPrev = if (steps.isEmpty()) "none" else "output",
        )
        steps = steps + s
        selectedStepId = s.id
    }

    /**
     * Adds a control-flow block (PLAN-HARNESS-BUILDER Phase 3). `kind` is
     * `"branch"` or `"loop"` -- `PipelineStepDraft` defaults their
     * sub-stacks with one starter `PipelineSubStepDraft`, so a fresh block
     * is immediately submittable (a loop body must have >= 1 step; a
     * branch's arms are optional but starting with one is a friendlier
     * default than an empty Then).
     */
    fun addControlFlowStep(kind: String) {
        val s = PipelineStepDraft(kind = kind, inputFromPrev = if (steps.isEmpty()) "none" else "output")
        steps = steps + s
        selectedStepId = s.id
    }

    fun removeStep(id: String) {
        if (steps.size <= 1) return
        val wasSelected = selectedStepId == id
        steps = steps.filterNot { it.id == id }
        if (wasSelected) selectedStepId = steps.firstOrNull()?.id
    }

    fun updateStep(id: String, updated: PipelineStepDraft) {
        steps = steps.map { if (it.id == id) updated.copy(id = id) else it }
    }

    // ---- Sub-stack editing (Then / Else / Loop body) -----------------

    private fun subStepArray(arm: PipelineSubStepArm, step: PipelineStepDraft): List<PipelineSubStepDraft> =
        when (arm) {
            PipelineSubStepArm.THEN -> step.branchThen
            PipelineSubStepArm.ELSE_ARM -> step.branchElse
            PipelineSubStepArm.BODY -> step.loopBody
        }

    private fun withSubStepArray(
        arm: PipelineSubStepArm,
        step: PipelineStepDraft,
        value: List<PipelineSubStepDraft>,
    ): PipelineStepDraft = when (arm) {
        PipelineSubStepArm.THEN -> step.copy(branchThen = value)
        PipelineSubStepArm.ELSE_ARM -> step.copy(branchElse = value)
        PipelineSubStepArm.BODY -> step.copy(loopBody = value)
    }

    fun addSubStep(stepId: String, arm: PipelineSubStepArm) {
        steps = steps.map { s ->
            if (s.id != stepId) return@map s
            val arr = subStepArray(arm, s)
            // Branch/loop "Add step" adds a Custom step (design), not a
            // Research/Design/Build one -- prompt stays blank for the user
            // to fill in. Task-2a fix: same "output after the first" default
            // within a Then/Else/body sub-stack -- the arm's own first step
            // keeps "none".
            val sub = PipelineSubStepDraft(role = "custom", inputFromPrev = if (arr.isEmpty()) "none" else "output")
            withSubStepArray(arm, s, arr + sub)
        }
    }

    /**
     * Removes a sub-step. A loop body must keep at least one step (broker
     * validation: `len(s.Loop.Body) == 0` is rejected); Then/Else may go to
     * zero (both are optional arrays on the wire).
     */
    fun removeSubStep(stepId: String, arm: PipelineSubStepArm, subStepId: String) {
        steps = steps.map { s ->
            if (s.id != stepId) return@map s
            val arr = subStepArray(arm, s)
            if (arm == PipelineSubStepArm.BODY && arr.size <= 1) return@map s
            withSubStepArray(arm, s, arr.filterNot { it.id == subStepId })
        }
    }

    /**
     * Swaps `subStepId` with its neighbor `direction` positions away
     * (-1 = up, +1 = down). A no-op past either end.
     */
    fun moveSubStep(stepId: String, arm: PipelineSubStepArm, subStepId: String, direction: Int) {
        steps = steps.map { s ->
            if (s.id != stepId) return@map s
            val arr = subStepArray(arm, s).toMutableList()
            val i = arr.indexOfFirst { it.id == subStepId }
            val j = i + direction
            if (i < 0 || j !in arr.indices) return@map s
            val tmp = arr[i]
            arr[i] = arr[j]
            arr[j] = tmp
            withSubStepArray(arm, s, arr)
        }
    }

    fun updateSubStep(stepId: String, arm: PipelineSubStepArm, subStep: PipelineSubStepDraft) {
        steps = steps.map { s ->
            if (s.id != stepId) return@map s
            withSubStepArray(arm, s, subStepArray(arm, s).map { if (it.id == subStep.id) subStep else it })
        }
    }

    /**
     * Reads one sub-step by identity -- the dual-mode `FlowStepEditorSheet`
     * (design_handoff_review_fixes R1) uses this to back its fields when
     * editing a branch Then/Else row instead of a top-level step. `null`
     * means the sub-step (or its parent step) no longer exists, e.g. it was
     * deleted from under an open sheet.
     */
    fun subStep(stepId: String, arm: PipelineSubStepArm, subStepId: String): PipelineSubStepDraft? {
        val step = steps.firstOrNull { it.id == stepId } ?: return null
        return subStepArray(arm, step).firstOrNull { it.id == subStepId }
    }

    /**
     * Drag-reorder. A step carries no client-side index field -- the broker
     * assigns the index from ARRAY POSITION at create time
     * (`ws/pipeline.go:serveCreatePipeline`), so reordering the list is the
     * entire reindex; there is nothing else to renumber.
     */
    fun moveStep(from: Int, to: Int) {
        if (from == to || from !in steps.indices || to !in steps.indices) return
        val mutable = steps.toMutableList()
        val item = mutable.removeAt(from)
        mutable.add(to, item)
        steps = mutable
    }

    fun applyTemplate(tmpl: PipelineTemplateDraft) {
        steps = tmpl.steps.ifEmpty { listOf(PipelineStepDraft()) }
        selectedStepId = steps.firstOrNull()?.id
    }

    // ---- Chain guardrail ---------------------------------------------
    //
    // Start-button last-line-of-defense (owner hit this twice: a saved
    // template/draft carries "none" forever even though #911 defaults
    // brand-NEW steps to "output"). Top-level steps only -- sub-steps
    // (branch/loop Then/Else/body) inherit context differently and are
    // excluded from this check entirely. Mirror of iOS
    // `PipelineBuilderViewModel.unchainedStepIndices`/`chainUnchainedSteps`.

    /**
     * Indices (0-based, into `steps`) of top-level steps after the first
     * whose `inputFromPrev` is still `"none"` -- these silently drop the
     * previous step's reply from their prompt. Step 0 is always excluded
     * (there is no previous step to chain from).
     */
    fun unchainedStepIndices(): List<Int> =
        steps.indices.filter { it > 0 && steps[it].inputFromPrev == "none" }

    /**
     * "Chain steps" resolution offered by the guardrail dialog: flips every
     * currently-unchained top-level step to `"output"`. Never touches step 0
     * or sub-steps.
     */
    fun chainUnchainedSteps() {
        val unchained = unchainedStepIndices().toSet()
        if (unchained.isEmpty()) return
        steps = steps.mapIndexed { i, s -> if (i in unchained) s.copy(inputFromPrev = "output") else s }
    }

    /** `/api/pipeline` create-request body -- same shape/encoder as Phase 1. */
    fun createRequestJson(title: String, task: String, cwd: String, base: String): JSONObject =
        JSONObject().apply {
            put("title", title)
            put("task", task)
            put("cwd", cwd)
            put("base", base)
            put("steps", JSONArray().apply { steps.forEach { put(stepDraftToJson(it)) } })
        }

    /** `/api/pipeline-templates` save-request body -- same shape as Phase 1. */
    fun templateSaveRequestJson(title: String, task: String): JSONObject =
        JSONObject().apply {
            put("title", title)
            put("task", task)
            put("steps", JSONArray().apply { steps.forEach { put(stepDraftToJson(it)) } })
        }

    /** Topology-preview items for `PipelineTopologyRail`. */
    fun topologyItems(): List<PipelineTopologyItem> = steps.map { s ->
        PipelineTopologyItem(
            id = s.id,
            agentType = s.agentType,
            role = s.role,
            gateAfter = s.gateAfter,
            fanoutCount = if (s.fanoutEnabled) s.fanoutCount else 0,
            kind = s.kind,
            thenCount = s.branchThen.size,
            elseCount = s.branchElse.size,
            bodyCount = s.loopBody.size,
            maxIterations = s.loopMaxIterations,
        )
    }
}
