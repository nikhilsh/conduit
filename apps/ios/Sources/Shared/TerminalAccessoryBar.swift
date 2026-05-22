import UIKit

/// Custom keyboard accessory bar for the terminal view. Claude/Codex
/// TUIs are nearly unusable on touch without Esc/Tab/arrows; the iOS
/// soft keyboard provides none of those by default. This bar sits
/// above the keyboard via `WKWebView.inputAccessoryView` (see
/// `KeyableWKWebView` below).
///
/// Bytes emitted match the standard xterm sequences so the agent on
/// the other end of the PTY sees the same input it would from a real
/// terminal:
///   - Esc      0x1B
///   - Tab      0x09
///   - Return   0x0D (CR — TUI agents submit on this, not LF)
///   - Up       ESC [ A
///   - Down     ESC [ B
///   - Right    ESC [ C
///   - Left     ESC [ D
final class TerminalAccessoryBar: UIToolbar {
    /// Called when the user taps a button. Bytes are routed through
    /// the same coordinator callback as keyboard input — keeps the
    /// scraper / harness path identical for both sources.
    var onSend: ((Data) -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        autoresizingMask = .flexibleWidth
        barStyle = .black
        isTranslucent = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rebuild() {
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        items = [
            key("Esc", bytes: [0x1B]),
            flex,
            key("Tab", bytes: [0x09]),
            flex,
            symbolKey("arrow.up",    bytes: [0x1B, 0x5B, 0x41]),
            symbolKey("arrow.down",  bytes: [0x1B, 0x5B, 0x42]),
            symbolKey("arrow.left",  bytes: [0x1B, 0x5B, 0x44]),
            symbolKey("arrow.right", bytes: [0x1B, 0x5B, 0x43]),
            flex,
            key("⏎", bytes: [0x0D]),
        ]
    }

    private func key(_ title: String, bytes: [UInt8]) -> UIBarButtonItem {
        // UIAction captures the bytes safely; no need for selector
        // boilerplate or stored callback objects.
        let action = UIAction(title: title) { [weak self] _ in
            self?.onSend?(Data(bytes))
        }
        let item = UIBarButtonItem(title: title, primaryAction: action)
        item.style = .plain
        return item
    }

    private func symbolKey(_ systemName: String, bytes: [UInt8]) -> UIBarButtonItem {
        let action = UIAction(image: UIImage(systemName: systemName)) { [weak self] _ in
            self?.onSend?(Data(bytes))
        }
        let item = UIBarButtonItem(image: UIImage(systemName: systemName), primaryAction: action)
        item.style = .plain
        return item
    }
}
