import SwiftUI

/// Header affordance that flips the Browser tab between the live `preview`
/// and the session memory HTML at `<endpoint>/memory/sessions/<uuid>.html`.
/// Tapping switches into the Browser tab and toggles the mode; tapping
/// again with the tab already on memory flips back to preview.
struct MemoryButton: View {
    @Binding var tab: ProjectTab
    @Binding var mode: BrowserMode

    var body: some View {
        Button {
            tab = .browser
            mode = (mode == .memory) ? .preview : .memory
        } label: {
            Image(systemName: mode == .memory ? "doc.text.fill" : "doc.text")
        }
        .accessibilityLabel("Open session memory")
    }
}
