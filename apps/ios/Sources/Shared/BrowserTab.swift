import SwiftUI
import WebKit

enum BrowserMode: String, Hashable {
    case preview
    case memory
}

struct BrowserTab: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.neonTheme) private var neon
    let session: ProjectSession
    let mode: BrowserMode

    /// Bumped to force the `WebView` to reload the current URL (the
    /// reload control in the neon chrome bar changes this).
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            if let url = resolvedURL {
                chromeBar(url: url)
                Divider().background(neon.border)
                WebView(url: url, reloadToken: reloadToken)
            } else {
                placeholder
            }
        }
        .background(neon.surfaceSolid)
    }

    // MARK: Neon chrome bar (URL + reload)

    private func chromeBar(url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .memory ? "doc.text" : "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(neon.accent)
            // URL "bar" — read-only display of the resolved address on a
            // neon code surface, mono so it reads as terminal chrome.
            Text(url.absoluteString)
                .font(neon.mono(12))
                .foregroundStyle(neon.codeText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 99, style: .continuous).fill(neon.codeBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 99, style: .continuous).stroke(neon.border, lineWidth: 1)
                )
            Button {
                reloadToken &+= 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(neon.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(neon.surface))
                    .overlay(Circle().stroke(neon.borderStrong, lineWidth: 1))
                    .neonGlowBox(neon.glow ? neon.glowBox : nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reload")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: mode == .memory ? "doc.text" : "safari")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(neon.accent)
                .neonTextGlow(neon.textGlow)
            Text(placeholderTitle)
                .font(neon.sans(17).weight(.semibold))
                .foregroundStyle(neon.text)
            Text(placeholderBody)
                .font(neon.sans(13))
                .foregroundStyle(neon.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resolvedURL: URL? {
        switch mode {
        case .preview:
            guard let p = store.preview[session.id] else { return nil }
            return resolve(p.url)
        case .memory:
            return resolve("/memory/sessions/\(session.id).html")
        }
    }

    /// Resolve a server-emitted path (which is typically relative, e.g.
    /// "/preview/<uuid>/") against the connection endpoint, swapping
    /// ws→http / wss→https. Absolute http(s) URLs pass through.
    private func resolve(_ pathOrURL: String) -> URL? {
        if let u = URL(string: pathOrURL), let scheme = u.scheme,
           ["http", "https"].contains(scheme.lowercased()) {
            return u
        }
        guard let base = store.endpoint.httpBaseURL else { return nil }
        return URL(string: pathOrURL, relativeTo: base)?.absoluteURL
    }

    private var placeholderTitle: String {
        switch mode {
        case .preview: return "No preview yet"
        case .memory:  return "No memory yet"
        }
    }

    private var placeholderBody: String {
        switch mode {
        case .preview: return "The agent hasn't reported a preview URL for this session."
        case .memory:  return "The server hasn't written a memory checkpoint for this session."
        }
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL
    /// Reload trigger — when this changes, the current URL is re-loaded.
    var reloadToken: Int = 0

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        context.coordinator.lastToken = reloadToken
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url != url {
            view.load(URLRequest(url: url))
        } else if reloadToken != context.coordinator.lastToken {
            view.reload()
        }
        context.coordinator.lastToken = reloadToken
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastToken = 0
    }
}
