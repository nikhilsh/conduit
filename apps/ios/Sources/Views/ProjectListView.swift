import SwiftUI

struct ProjectListView: View {
    @Environment(SessionStore.self) private var store
    @Binding var showSettings: Bool
    @Namespace private var glassNS

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            HarnessHeader()
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

            if let err = store.sessionCreationError {
                InlineErrorBanner(message: err, onDismiss: { store.sessionCreationError = nil })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            sessionList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .scrollContentBackground(.hidden)
        .navigationTitle("SweKitty")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        store.createSession(assistant: "claude")
                    } label: {
                        Label("Claude", systemImage: "sparkles")
                    }
                    Button {
                        store.createSession(assistant: "codex")
                    } label: {
                        Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!store.harness.canIssueCommands)
                .accessibilityLabel("New session")
            }
        }
        .tint(SweKittyTheme.accentStrong)
    }

    @ViewBuilder
    private var sessionList: some View {
        @Bindable var store = store
        let visible = store.visibleSessions
        if visible.isEmpty {
            EmptySessionsHint(
                isReachable: store.harness.canIssueCommands,
                onCreate: { assistant in store.createSession(assistant: assistant) }
            )
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            List(selection: $store.selectedSessionID) {
                ForEach(visible) { entry in
                    SessionRow(
                        entry: entry,
                        status: status(for: entry),
                        lifecycle: lifecycle(for: entry),
                        isSelected: isSelected(entry)
                    )
                    .glassMorphID("session-\(entry.id)", in: glassNS)
                    .tag(selectableTag(for: entry) as String?)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func selectableTag(for entry: VisibleSession) -> String? {
        if case .real(let s) = entry { return s.id }
        return nil
    }

    private func status(for entry: VisibleSession) -> SessionStatus? {
        switch entry {
        case .real(let s): return store.statusBySession[s.id]
        case .creating:    return nil
        }
    }

    private func lifecycle(for entry: VisibleSession) -> SessionLifecycle? {
        store.sessionLifecycle[entry.id]
    }

    private func isSelected(_ entry: VisibleSession) -> Bool {
        switch entry {
        case .real(let s): return store.selectedSessionID == s.id
        case .creating:    return false
        }
    }
}

/// Compact header showing endpoint and harness state, with a single
/// retry action when something's wrong.
private struct HarnessHeader: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.endpoint.displayHost)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let reason = store.harness.failureReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(SweKittyTheme.danger.opacity(0.9))
                            .lineLimit(2)
                    } else {
                        Text("swe-kitty harness")
                            .font(.caption2)
                            .foregroundStyle(SweKittyTheme.textMuted)
                    }
                }
                Spacer()
                HarnessBadge(state: store.harness)
            }

            if shouldShowReconnect {
                Button {
                    store.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassRoundedRect()
    }

    private var shouldShowReconnect: Bool {
        switch store.harness {
        case .failed, .disconnected: return store.endpoint.isComplete
        default: return false
        }
    }
}

/// Empty-state used when there are no sessions. Has primary actions for
/// starting a new session so the user isn't hunting for a + icon.
private struct EmptySessionsHint: View {
    let isReachable: Bool
    let onCreate: (String) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isReachable ? "sparkles" : "cloud.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(SweKittyTheme.textSecondary)
            Text(isReachable ? "Start a session" : "Waiting for harness")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text(isReachable
                ? "Pick an agent and we'll spin up a new conversation against the harness."
                : "Once we can reach the harness this is where your sessions will appear.")
                .font(.footnote)
                .foregroundStyle(SweKittyTheme.textMuted)
                .multilineTextAlignment(.center)

            if isReachable {
                HStack(spacing: 10) {
                    Button {
                        onCreate("claude")
                    } label: {
                        Label("Claude", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        onCreate("codex")
                    } label: {
                        Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .glassRoundedRect()
    }
}

private struct SessionRow: View {
    let entry: VisibleSession
    let status: SessionStatus?
    let lifecycle: SessionLifecycle?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.headline)
                    .foregroundStyle(SweKittyTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SweKittyTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassRect(cornerRadius: SweKittyTheme.cardCornerRadius, tint: tint)
    }

    @ViewBuilder
    private var leading: some View {
        switch lifecycle {
        case .creating:
            ProgressView().controlSize(.small).tint(SweKittyTheme.accentStrong)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SweKittyTheme.danger)
        default:
            HealthDot(health: status?.health ?? "unknown", size: 10)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if case .real = entry {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textMuted)
        }
    }

    private var displayName: String {
        switch entry {
        case .real(let s):  return s.name
        case .creating:     return "Starting session…"
        }
    }

    private var subtitle: String {
        switch entry {
        case .real(let s):
            let phase = status?.phase ?? "ready"
            let branch = s.branch ?? "—"
            return "\(s.assistant) · \(branch) · \(phase)"
        case .creating:
            if case .failed(let msg) = lifecycle { return msg }
            return "asking harness for a session…"
        }
    }

    private var tint: Color? {
        if isSelected { return SweKittyTheme.accentStrong.opacity(0.45) }
        if case .failed = lifecycle { return SweKittyTheme.danger.opacity(0.40) }
        return nil
    }
}
