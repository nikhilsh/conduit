import SwiftUI

/// Horizontal scrollable pill strip listing saved servers. Last pill is
/// a `+ server` CTA. Tapping a pill switches the active endpoint (and
/// triggers reconnect). Lives at the top of the litter-style home view.
struct ServerTabsStrip: View {
    @Environment(SessionStore.self) private var store
    @Binding var showAddServer: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.savedServers) { server in
                    serverPill(server)
                }
                addPill
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }

    private func serverPill(_ server: SavedServer) -> some View {
        let isActive = store.endpoint == server.endpoint
        return Button {
            store.selectSavedServer(server.id, autoConnect: true)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? SweKittyTheme.accentStrong : SweKittyTheme.textMuted.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(server.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isActive ? SweKittyTheme.textPrimary : SweKittyTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassCapsule(
                interactive: true,
                tint: isActive ? SweKittyTheme.accentStrong.opacity(0.32) : SweKittyTheme.surface.opacity(0.65)
            )
        }
        .buttonStyle(.plain)
    }

    private var addPill: some View {
        Button {
            showAddServer = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                Text("server")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(SweKittyTheme.accentStrong)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .stroke(SweKittyTheme.accentStrong, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
