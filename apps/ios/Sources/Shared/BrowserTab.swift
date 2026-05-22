import SwiftUI
import WebKit

enum BrowserMode: String, Hashable {
    case preview
    case memory
}

struct BrowserTab: View {
    @Environment(SessionStore.self) private var store
    let session: ProjectSession
    let mode: BrowserMode

    var body: some View {
        Group {
            if let url = resolvedURL {
                WebView(url: url)
            } else {
                ContentUnavailableView(
                    placeholderTitle,
                    systemImage: mode == .memory ? "doc.text" : "safari",
                    description: Text(placeholderBody)
                )
            }
        }
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
        case .memory:  return "The harness hasn't written a memory checkpoint for this session."
        }
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }
}
