import SwiftUI
import SwiftTerm
import UIKit

struct TerminalTab: View {
    @Environment(SessionStore.self) private var store
    let session: ProjectSession

    var body: some View {
        TerminalRepresentable(
            sessionID: session.id,
            bufferProvider: { store.terminalBuffer[session.id] ?? Data() },
            bufferRevision: store.terminalBuffer[session.id]?.count ?? 0,
            onInput: { bytes in
                store.sendInput(sessionID: session.id, bytes: bytes)
            },
            onResize: { rows, cols in
                store.resize(sessionID: session.id, rows: UInt16(rows), cols: UInt16(cols))
            }
        )
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct TerminalRepresentable: UIViewRepresentable {
    let sessionID: String
    let bufferProvider: () -> Data
    let bufferRevision: Int
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.terminal = view
        // Initial backfill from any snapshot already buffered before the view existed.
        let initial = bufferProvider()
        if !initial.isEmpty {
            view.feed(byteArray: ArraySlice(initial))
            context.coordinator.lastFedByteCount = initial.count
        }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        let buf = bufferProvider()
        let last = context.coordinator.lastFedByteCount
        if buf.count > last {
            let slice = buf[last..<buf.count]
            view.feed(byteArray: ArraySlice(slice))
            context.coordinator.lastFedByteCount = buf.count
        } else if buf.count < last {
            // Snapshot replaced the buffer entirely. Reset SwiftTerm's
            // internal state BEFORE replaying the new bytes — otherwise
            // the snapshot's ANSI piles on top of whatever was already
            // rendered and the screen comes out as garbled vertical
            // stripes (this is the bug from the codex-session screenshot
            // on 2026-05-20). ESC c (RIS) is the full terminal reset.
            view.feed(byteArray: ArraySlice([0x1b, 0x63]))
            view.feed(byteArray: ArraySlice(buf))
            context.coordinator.lastFedByteCount = buf.count
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let onInput: (Data) -> Void
        let onResize: (Int, Int) -> Void
        weak var terminal: TerminalView?
        var lastFedByteCount: Int = 0

        init(onInput: @escaping (Data) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newRows, newCols)
        }

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = s
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
