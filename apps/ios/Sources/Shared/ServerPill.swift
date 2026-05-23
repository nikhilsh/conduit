import SwiftUI

/// Litter parity audit item A.3 (iOS half): a glass-capsule pill row that
/// represents one server — saved or discovered — uniformly across the
/// Home strip and the DiscoveryView. Lifted into a pure-data model
/// (`ServerPillModel`) so the rendering, label formatting, and saved-vs
/// -discovered prefix are unit-testable without standing up a SwiftUI
/// host. Same pattern as PR B's `ProjectHeaderModel` /
/// `InSessionBottomBarModel`.
///
/// Kind drives subtle visuals only:
///   - `.saved`  — solid status dot, name as the headline, host:port caption.
///   - `.discovered` — soft "discovered" caption + (optional) version tag.
///
/// Tap calls the supplied `onTap`; long-press opens a context menu with
/// forget/rename (saved entries) or "Add as saved server" (discovered).
struct ServerPill: View {
    let model: ServerPillModel
    var onTap: () -> Void
    var onForget: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onAdopt: (() -> Void)? = nil

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.statusColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(model.isActive ? SweKittyTheme.textPrimary : SweKittyTheme.textSecondary)
                        .lineLimit(1)
                    if let subtitle = model.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(SweKittyTheme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // PLAN-LITTER-VISUAL-PARITY PR 5, audit §A.5/A.4: drop the
            // glass-capsule fill in favour of a transparent
            // background + accent / muted stroke. The prior treatment
            // gave every pill a "saved chip" look and made it hard to
            // distinguish the active server at a glance; with the
            // stroke approach the active pill carries a 1.2pt accent
            // border (loud), inactive pills carry a 0.6pt textMuted
            // border at 25% opacity (quiet).
            .background(
                Capsule()
                    .fill(model.isActive
                          ? SweKittyTheme.accentStrong.opacity(0.12)
                          : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(
                        model.isActive
                            ? SweKittyTheme.accentStrong.opacity(ServerPillStroke.activeOpacity)
                            : SweKittyTheme.textMuted.opacity(ServerPillStroke.inactiveOpacity),
                        lineWidth: model.isActive ? ServerPillStroke.activeWidth : ServerPillStroke.inactiveWidth
                    )
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if model.kind == .saved {
                if let onRename {
                    Button("Rename", systemImage: "pencil") { onRename() }
                }
                if let onForget {
                    Button("Forget", systemImage: "trash", role: .destructive) { onForget() }
                }
            } else if model.kind == .discovered {
                if let onAdopt {
                    Button("Save server", systemImage: "tray.and.arrow.down") { onAdopt() }
                }
            }
        }
        .accessibilityLabel(model.accessibilityLabel)
    }
}

/// Stroke metrics for `ServerPill`'s active vs inactive treatment
/// (PLAN-LITTER-VISUAL-PARITY PR 5, audit §A.5/A.4). Extracted so
/// `ServerPillStrokeTests` can pin the values — the prior glass-
/// capsule fill couldn't distinguish active vs idle at a glance, and
/// the next pass at "tightening" the pill could quietly drop these
/// to invisible without the test failing.
enum ServerPillStroke {
    /// 1.2pt accent border on the active pill — visible at a glance.
    static let activeWidth: CGFloat = 1.2
    /// 0.6pt muted border on the inactive pill — present but quiet.
    static let inactiveWidth: CGFloat = 0.6
    /// 0.75 opacity for the active accent stroke.
    static let activeOpacity: Double = 0.75
    /// 0.25 opacity for the inactive muted stroke.
    static let inactiveOpacity: Double = 0.25
}

/// Pure-data model for `ServerPill`. Lifts the colour mapping, caption
/// formatting, and "saved" vs "discovered" affordances out of the view
/// body so the visual contract can be pinned in unit tests. See
/// `ServerPillModelTests` for the wired-in assertions.
struct ServerPillModel: Equatable, Identifiable {
    /// Where this pill came from. Saved entries are user-curated and
    /// persist in the keychain; discovered entries flow in from the
    /// mDNS browser and disappear when the browser pauses.
    enum Kind: String, Equatable {
        case saved
        case discovered
    }

    /// Reachability hint. Drives the status dot — green = live, yellow
    /// = connecting/reconnecting, gray = unknown/idle, red = failed.
    /// Saved entries that aren't the active endpoint resolve to `.idle`.
    enum Status: String, Equatable {
        case live
        case connecting
        case idle
        case failed
    }

    /// Stable identifier:
    ///   - saved → `SavedServer.id`
    ///   - discovered → mDNS service-instance name
    /// Both are unique within their kind. We prefix with the kind so a
    /// saved+discovered pair (same advertiser) can coexist on screen.
    let id: String
    let kind: Kind
    let name: String
    let host: String
    let port: Int
    let status: Status
    /// True for the pill matching the currently-selected endpoint.
    let isActive: Bool
    /// Optional version string (`txt["v"]`) surfaced only when present.
    let version: String?

    /// Convenience: the caption that appears under the monospaced name.
    /// `discovered` entries surface "discovered · host:port" so a glance
    /// at the row distinguishes them from saved ones. Saved entries
    /// just show `host:port` — the surrounding context already implies
    /// "saved".
    var caption: String {
        let hostPort = "\(host):\(port)"
        switch kind {
        case .saved:      return hostPort
        case .discovered: return "discovered · \(hostPort)"
        }
    }

    /// User-facing headline for line 1 of the pill. When the saved
    /// server has no user-chosen label, `name` is seeded from
    /// `endpoint.displayHost` ("host:port") in `SessionStore` — which,
    /// combined with the `caption` underneath, made the pill render the
    /// same string twice. Collapse to host-only here so line 1 reads
    /// `10.0.0.4` and `subtitle` falls away below.
    var displayName: String {
        let hostPort = "\(host):\(port)"
        if name.isEmpty || name == hostPort || name == caption {
            return host
        }
        return name
    }

    /// Optional second line. `nil` when the pill should collapse to a
    /// single row because the user never picked a custom name — that's
    /// the polish bug PR #47 introduced (host:port duplicated on both
    /// lines). The view drops the second `Text` when this is `nil`.
    var subtitle: String? {
        let hostPort = "\(host):\(port)"
        if name.isEmpty || name == hostPort || name == caption {
            return nil
        }
        return caption
    }

    /// SwiftUI colour for the status dot. Computed off `status` only;
    /// `kind` doesn't affect the colour, only the caption.
    var statusColor: Color {
        switch status {
        case .live:       return SweKittyTheme.success
        case .connecting: return SweKittyTheme.warning
        case .idle:       return SweKittyTheme.textMuted.opacity(0.4)
        case .failed:     return SweKittyTheme.danger
        }
    }

    /// Compact VoiceOver string. Keep this stable — tests assert the
    /// "saved server", "nearby server" prefix so screen readers don't
    /// regress with a future caption rewrite.
    var accessibilityLabel: String {
        let prefix: String = {
            switch kind {
            case .saved:      return "Saved server"
            case .discovered: return "Nearby server"
            }
        }()
        return "\(prefix) \(name), \(host):\(port), status \(status.rawValue)"
    }

    // MARK: - Convenience constructors

    /// Lift from a `SavedServer` + current store state. The active flag
    /// is computed externally so the model stays pure (no SessionStore
    /// dependency) — that's what makes the test path easy.
    static func fromSaved(
        _ server: SavedServer,
        currentEndpoint: StoredEndpoint,
        harness: HarnessState
    ) -> ServerPillModel {
        // Identity = endpoint URL only. The auth token is a per-device
        // secret — two clients with different tokens against the same
        // broker URL are still pointing at the same server. Comparing
        // the full StoredEndpoint (including token) gives false negatives
        // when the test harness or a re-pair handed out a fresh token.
        let isActive = currentEndpoint.url == server.endpoint.url
        let status: Status = {
            guard isActive else { return .idle }
            switch harness {
            case .live, .linked: return .live
            case .connecting, .reconnecting: return .connecting
            case .failed: return .failed
            case .disconnected: return .idle
            }
        }()
        let (host, port) = Self.splitHostPort(server.endpoint.url) ?? (server.endpoint.displayHost, 0)
        return ServerPillModel(
            id: "saved:\(server.id)",
            kind: .saved,
            name: server.name,
            host: host,
            port: port,
            status: status,
            isActive: isActive,
            version: nil
        )
    }

    /// Lift from a discovery row. `isActive` flips true when the user
    /// has connected via that advertiser since the browser started.
    static func fromDiscovered(
        id: String,
        name: String,
        host: String,
        port: Int,
        version: String?,
        isActive: Bool
    ) -> ServerPillModel {
        ServerPillModel(
            id: "discovered:\(id)",
            kind: .discovered,
            name: name,
            host: host,
            port: port,
            // Discovered rows haven't been paired yet — treat them as idle
            // until the user taps and we transition through .connecting.
            status: isActive ? .live : .idle,
            isActive: isActive,
            version: version
        )
    }

    /// Pull `host` / `port` out of a `ws://host:port` URL. The store
    /// already has `displayHost` for the combined form, but the pill
    /// caption needs them split so the port doesn't smush against the
    /// glyph when the host name is long. Returns nil for malformed URLs.
    static func splitHostPort(_ url: String) -> (host: String, port: Int)? {
        guard let components = URLComponents(string: url),
              let host = components.host,
              let port = components.port
        else { return nil }
        return (host, port)
    }
}
