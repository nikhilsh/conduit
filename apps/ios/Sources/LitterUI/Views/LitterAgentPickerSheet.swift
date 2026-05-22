import SwiftUI

// MARK: - LitterAgentPickerSheet
//
// Agent-picker sheet for LitterUI. Wraps the legacy AgentPickerSheet
// for now (it covers Claude/Codex/Hermes/Pi/opencode + initial-prompt
// seed, all behaviors we don't want to re-implement in this PR).
// Visual rebuild lands as a follow-up.

extension LitterUI {
    struct AgentPickerSheet: View {
        @Environment(SessionStore.self) private var store
        var headerNote: String? = nil
        var initialPrompt: String? = nil

        var body: some View {
            LegacyAgentPickerWrapper(headerNote: headerNote, initialPrompt: initialPrompt)
                .environment(store)
        }
    }
}

private struct LegacyAgentPickerWrapper: View {
    let headerNote: String?
    let initialPrompt: String?
    var body: some View {
        AgentPickerSheet(headerNote: headerNote, initialPrompt: initialPrompt)
    }
}
