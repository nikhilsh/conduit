import SwiftUI

// MARK: - Tablet activity bar
//
// The design bundle's far-left iPad activity bar (tablet-sections.jsx →
// TabletActivityBar): brand mark on top, a vertical stack of section
// items (Home / Sessions / History / Boxes / Settings), and an account
// glyph pinned to the bottom. 84pt wide, hairline right border, the
// active item carries an accent-tinted pill + (when glow is on) a halo.
//
// This is the iPad chrome only — `ConduitUI.RootView` owns the section
// state + routes each pick to inline content (Home / Sessions) or a
// presented sheet (History / Boxes / Settings) until those sections get
// dedicated tablet layouts.

extension ConduitUI {

    enum TabletSection: String, CaseIterable, Identifiable {
        case home, sessions, history, boxes, settings

        var id: String { rawValue }

        var label: String {
            switch self {
            case .home:     return "Home"
            case .sessions: return "Sessions"
            case .history:  return "History"
            case .boxes:    return "Boxes"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .home:     return "house"
            case .sessions: return "bubble.left.and.bubble.right"
            case .history:  return "clock.arrow.circlepath"
            case .boxes:    return "server.rack"
            case .settings: return "gearshape"
            }
        }
    }

    struct TabletActivityBar: View {
        /// The currently-highlighted inline section (Home / Sessions).
        let section: TabletSection
        let onPick: (TabletSection) -> Void
        @Environment(\.neonTheme) private var neon

        var body: some View {
            VStack(spacing: 7) {
                ConduitUI.ConduitMark(size: 30)
                    .padding(.bottom, 10)

                ForEach(TabletSection.allCases) { item in
                    itemButton(item)
                }

                Spacer(minLength: 8)

                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(neon.agentTint(forAgent: "claude"))
                    .frame(width: 36, height: 36)
            }
            .padding(.vertical, 16)
            .frame(width: 84)
            .frame(maxHeight: .infinity)
            .background(
                (neon.dark ? Color(red: 4 / 255, green: 7 / 255, blue: 14 / 255).opacity(0.7)
                           : Color.white.opacity(0.72))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(neon.border).frame(width: 1)
                    }
            )
        }

        private func itemButton(_ item: TabletSection) -> some View {
            let on = item == section
            let tint = on ? neon.accent : neon.textDim
            return Button {
                onPick(item)
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: item.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(item.label)
                        .font(neon.sans(10.5).weight(on ? .bold : .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 66)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(on ? neon.accent.opacity(neon.dark ? 0.12 : 0.08) : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(on ? neon.accent.opacity(0.4) : .clear, lineWidth: 1)
                        )
                )
                .neonGlowBox(on && neon.glow ? neon.glowBox : nil)
            }
            .buttonStyle(.plain)
        }
    }
}
