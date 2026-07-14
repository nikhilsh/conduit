import SwiftUI

// MARK: - ConduitUI.DiffHunkView
//
// One `@@ -a,b +c,d @@` hunk of a structured git diff: the header row +
// its `DiffLineRow`s. Library component -- Android mirror is
// `ui/components/DiffHunk.kt`, kept value-for-value in sync.
//
// Named `DiffHunkView` (not `DiffHunk`, matching the `DiffLineRow` /
// `DiffLine` naming note) to read unambiguously alongside the model type
// `ConduitUI.GitDiffHunk` it renders.

extension ConduitUI {

    struct DiffHunkView: View {
        let filePath: String
        let hunk: GitDiffHunk
        /// Line indices (within `hunk.lines`) that carry a pinned
        /// annotation -- drives the gutter chip.
        var annotatedLineIndices: Set<Int> = []
        /// Tapping a line opens the annotate sheet for that (hunk, index).
        var onTapLine: ((GitDiffHunk, Int) -> Void)? = nil
        @Environment(\.neonTheme) private var neon

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(hunk.header)
                    .font(neon.mono(10.5).weight(.semibold))
                    .foregroundStyle(neon.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(neon.surface2)

                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                    DiffLineRow(
                        line: line,
                        isAnnotated: annotatedLineIndices.contains(index),
                        onTap: onTapLine.map { callback in { callback(hunk, index) } }
                    )
                }
            }
            .conduitGlassRoundedRect(cornerRadius: 10)
        }
    }
}
