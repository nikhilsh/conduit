import UIKit

/// Custom keyboard accessory bar for the terminal view. Claude/Codex
/// TUIs are nearly unusable on touch without Esc/Tab/Ctrl/arrows; the
/// iOS soft keyboard provides none of those by default. This bar sits
/// above the keyboard via `WKWebView.inputAccessoryView` (see
/// `KeyableWKWebView`) and is also returned as the native Ghostty
/// renderer's `inputAccessoryView` (see `GhosttyRenderView`), so both
/// terminal tracks share the exact same row.
///
/// Termius-style: a horizontally-scrolling row of rounded key caps,
/// hosted in a `UIInputView` so the backdrop matches the system
/// keyboard's blur. We can't implement a *sticky* Ctrl modifier
/// (the alphanumeric soft keys go straight to the WKWebView, not
/// through us), so the common Ctrl chords are exposed as direct keys
/// (^C/^D/^Z/^L/^R/^U/^W/^A/^E) alongside the symbols a shell needs
/// most.
///
/// Bytes emitted match the standard xterm sequences so the agent on the
/// other end of the PTY sees the same input it would from a real
/// terminal (Esc 0x1B, Tab 0x09, Return 0x0D, arrows ESC[A..D, the
/// document-navigation keys Home ESC[H / End ESC[F / PgUp ESC[5~ /
/// PgDn ESC[6~, and the C0 control codes for the Ctrl chords).
///
/// Navigation keys that a user wants to *hold* — backspace and the four
/// arrows — auto-repeat: an initial delay (~0.4s) then a steady cadence
/// (~0.1s) until touch-up, mirroring a hardware keyboard's key-repeat
/// and MobileTerminal's `RepeatableToolbarButton`.
final class TerminalAccessoryBar: UIInputView {
    /// Called when the user taps a key. Bytes are routed through the
    /// same coordinator callback as keyboard input — keeps the harness
    /// path identical for both sources.
    var onSend: ((Data) -> Void)?

    private let barHeight: CGFloat = 48

    /// Press-and-hold key-repeat timing. Matches a hardware keyboard's
    /// "delay until repeat" / "key repeat rate" feel and
    /// MobileTerminal's `RepeatableToolbarButton` (0.4s, then 0.1s).
    private static let repeatInitialDelay: TimeInterval = 0.4
    private static let repeatInterval: TimeInterval = 0.1

    /// A single key: what it shows and what it sends.
    private struct Key {
        let label: String
        let bytes: [UInt8]
        /// Slightly wider cap for the multi-glyph labels so they don't
        /// look cramped next to the single-character symbol keys.
        var wide: Bool = false
        /// Press-and-hold auto-repeats this key (backspace + arrows).
        var repeats: Bool = false
    }

    // Ordered the way a thumb reaches for them: navigation/control
    // first, then the shell symbols. The row scrolls, so the list can
    // be generous without crowding.
    private static let keys: [Key] = [
        Key(label: "esc", bytes: [0x1B], wide: true),
        Key(label: "tab", bytes: [0x09], wide: true),
        // Backspace: DEL (0x7F) — same byte `GhosttyRenderView.deleteBackward`
        // and xterm.js emit for the soft-keyboard delete key.
        Key(label: "⌫", bytes: [0x7F], repeats: true),
        Key(label: "↑", bytes: [0x1B, 0x5B, 0x41], repeats: true),
        Key(label: "↓", bytes: [0x1B, 0x5B, 0x42], repeats: true),
        Key(label: "←", bytes: [0x1B, 0x5B, 0x44], repeats: true),
        Key(label: "→", bytes: [0x1B, 0x5B, 0x43], repeats: true),
        // Document navigation — standard xterm sequences: Home ESC[H,
        // End ESC[F, PgUp ESC[5~, PgDn ESC[6~. Wide caps for the
        // multi-glyph labels.
        Key(label: "home", bytes: [0x1B, 0x5B, 0x48], wide: true),
        Key(label: "end", bytes: [0x1B, 0x5B, 0x46], wide: true),
        Key(label: "pgup", bytes: [0x1B, 0x5B, 0x35, 0x7E], wide: true),
        Key(label: "pgdn", bytes: [0x1B, 0x5B, 0x36, 0x7E], wide: true),
        Key(label: "^C", bytes: [0x03]),
        Key(label: "^D", bytes: [0x04]),
        Key(label: "^Z", bytes: [0x1A]),
        Key(label: "^L", bytes: [0x0C]),
        Key(label: "^R", bytes: [0x12]),
        Key(label: "^U", bytes: [0x15]),
        Key(label: "^W", bytes: [0x17]),
        Key(label: "^A", bytes: [0x01]),
        Key(label: "^E", bytes: [0x05]),
        Key(label: "|", bytes: [0x7C]),
        Key(label: "/", bytes: [0x2F]),
        Key(label: "\\", bytes: [0x5C]),
        Key(label: "~", bytes: [0x7E]),
        Key(label: "-", bytes: [0x2D]),
    ]

    private let scroll = UIScrollView()
    private let row = UIStackView()

    /// Drives press-and-hold auto-repeat for the currently-held key.
    /// One timer at a time — UIKit delivers touch events serially per
    /// button, and only one accessory key can be held under a finger.
    private var repeatTimer: Timer?

    init() {
        super.init(
            frame: CGRect(x: 0, y: 0, width: 320, height: 48),
            inputViewStyle: .keyboard
        )
        autoresizingMask = .flexibleWidth
        allowsSelfSizing = true
        buildKeys()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { cancelRepeat() }

    // Pin the bar height so UIKit lays the inputAccessoryView out at a
    // comfortable touch size regardless of the keys' intrinsic sizes.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: barHeight)
    }

    private func buildKeys() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.contentInset = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        addSubview(scroll)

        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 7
        scroll.addSubview(row)

        for key in Self.keys {
            row.addArrangedSubview(makeButton(for: key))
        }

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func makeButton(for key: Key) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = key.label
        config.cornerStyle = .medium
        config.baseForegroundColor = .label
        config.background.backgroundColor = UIColor.label.withAlphaComponent(0.10)
        // Uniform horizontal padding for every cap. The wide keys earn
        // their extra room from a larger minimum width below, not from
        // fatter insets — over-padding multi-glyph labels (esc/tab) was
        // what squeezed their titles and clipped the leading/trailing
        // characters of the first two caps.
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: 12, bottom: 6, trailing: 12
        )
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.monospacedSystemFont(ofSize: 16, weight: .medium)
            return out
        }

        let bytes = key.bytes
        let button = UIButton(configuration: config)
        button.accessibilityLabel = key.label
        // Never let the scroll view's stack squeeze a cap below its
        // intrinsic title+inset width — that truncation was clipping the
        // first two (wide) keys to a stray mid-glyph. Hug the content and
        // resist compression on both axes so every cap is fully legible.
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.titleLabel?.lineBreakMode = .byClipping
        button.titleLabel?.adjustsFontSizeToFitWidth = false

        if key.repeats {
            // Press-and-hold auto-repeat. `.touchDown` fires the first
            // byte immediately and arms the repeat timer; the lift /
            // drag-out / cancel events tear it down. We deliberately do
            // *not* use the `.touchUpInside` primaryAction here — the
            // first emit already happened on touchDown, and re-emitting
            // on lift would double the keystroke.
            button.addAction(UIAction { [weak self] _ in
                self?.beginRepeat(bytes: bytes)
            }, for: .touchDown)
            let stop = UIAction { [weak self] _ in self?.cancelRepeat() }
            button.addAction(stop, for: .touchUpInside)
            button.addAction(stop, for: .touchUpOutside)
            button.addAction(stop, for: .touchDragExit)
            button.addAction(stop, for: .touchCancel)
        } else {
            // Single-shot keys emit once on lift, same as before.
            button.addAction(UIAction { [weak self] _ in
                self?.emit(bytes: bytes)
            }, for: .touchUpInside)
        }
        // Minimum cap width — single-glyph keys get a square-ish 40pt,
        // multi-glyph (esc/tab/home/end/pgup/pgdn) get room for a 4-char
        // monospace label plus insets. The content-hugging above means a
        // longer title still grows the cap past this floor.
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: key.wide ? 56 : 40).isActive = true
        return button
    }

    /// Emit one key's bytes plus the standard light haptic tick.
    private func emit(bytes: [UInt8]) {
        onSend?(Data(bytes))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Fire the first byte now, then schedule the repeat cadence after
    /// the initial delay. Any prior repeat is cancelled first so a fast
    /// re-press can't leave two timers running.
    private func beginRepeat(bytes: [UInt8]) {
        cancelRepeat()
        emit(bytes: bytes)
        // After the initial delay, start the steady-cadence timer. We
        // nest a delayed scheduling so the gap between the first emit
        // and the second matches `repeatInitialDelay`, then subsequent
        // emits land every `repeatInterval`.
        let initial = Timer.scheduledTimer(
            withTimeInterval: Self.repeatInitialDelay,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(
                withTimeInterval: Self.repeatInterval,
                repeats: true
            ) { [weak self] _ in
                self?.onSend?(Data(bytes))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            // Keep the cadence ticking while the user scrolls the bar
            // (the row is in a UIScrollView; default mode would pause
            // the timer during tracking).
            if let t = self.repeatTimer {
                RunLoop.main.add(t, forMode: .common)
            }
        }
        RunLoop.main.add(initial, forMode: .common)
        repeatTimer = initial
    }

    /// Tear down any in-flight repeat. Safe to call when nothing is
    /// running. Note the `repeatTimer` slot holds *either* the
    /// initial-delay one-shot or the steady-cadence repeater — both are
    /// invalidated through the same handle, and the initial one-shot
    /// overwrites the slot with the repeater when it fires, so a single
    /// invalidate here always targets the live timer.
    private func cancelRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
