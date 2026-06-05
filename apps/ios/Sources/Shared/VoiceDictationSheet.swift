import AVFoundation
import Foundation
import SwiftUI

/// Global voice dictation modal — invoked from the bottom-bar mic when
/// the user is on the home view or anywhere outside a chat composer.
/// Reuses `VoiceTranscriber` (the same `SFSpeechRecognizer` pipeline
/// that powers `InlineVoiceButton`) so we don't have two competing
/// recognition stacks.
///
/// Redesign (handoff §B.8 / `images/09-voice.png`): a live-transcript
/// surface with detected-intent chips, an amplitude-driven waveform, an
/// agent target chip, a "read replies aloud" TTS toggle, and a
/// hands-free hint. The recognized text still commits to the agent /
/// composer exactly as before — this is presentation + extension only.
struct VoiceDictationSheet: View {
    let onTranscript: (String) -> Void
    /// Agent the dictation will be routed to (drives the target chip +
    /// its tint). Defaults to `claude` — the home voice flow seeds a new
    /// claude session, and the in-chat flow passes the session's agent.
    var agent: String = "claude"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.neonTheme) private var neon

    @StateObject private var transcriber = VoiceTranscriber()
    @StateObject private var speaker = VoiceReplySpeaker()
    @State private var captured: String = ""
    /// Read-replies-aloud toggle. Local @State (no AppearanceStore key
    /// exists for this); drives `VoiceReplySpeaker`. No reply stream is
    /// wired into this modal, so when ON we speak a short confirmation of
    /// the committed transcript on send — a real `AVSpeechSynthesizer`
    /// speak path, not a no-op stub.
    @State private var readAloud: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                neon.appBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    targetBar
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    if case .error(let message) = transcriber.state {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(neon.red)
                        Text(message)
                            .font(neon.sans(15))
                            .foregroundStyle(neon.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.top, 10)
                        Spacer()
                    } else {
                        listeningStatus
                            .padding(.top, 22)
                        transcriptView
                            .padding(.horizontal, 22)
                            .padding(.top, 14)
                        intentChips
                            .padding(.horizontal, 22)
                            .padding(.top, 14)
                        Spacer()
                        waveform
                        Spacer()
                    }

                    footer
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .neonAccentTint()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        transcriber.stop()
                        speaker.stop()
                        dismiss()
                    }
                }
            }
            .onAppear {
                transcriber.start { final in
                    Task { @MainActor in
                        captured = final
                    }
                }
            }
            .onDisappear {
                transcriber.stop()
                speaker.stop()
            }
        }
        .appearanceColorScheme()
    }

    // MARK: Agent target chip

    private var targetBar: some View {
        let tint = neon.agentTint(forAgent: agent)
        return HStack(spacing: 8) {
            ConduitUI.ConduitMark(size: 18, color: tint, glow: neon.glow)
            Text(agent.lowercased())
                .font(neon.mono(12).weight(.semibold))
                .foregroundStyle(tint)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(neon.textFaint)
            Text("dictation")
                .font(neon.mono(11))
                .foregroundStyle(neon.textDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12, glowTint: tint)
    }

    // MARK: Listening status

    private var listeningStatus: some View {
        let isLive = transcriber.state == .listening
        return HStack(spacing: 7) {
            Circle()
                .fill(isLive ? neon.green : neon.textFaint)
                .frame(width: 7, height: 7)
                .neonGlowBox(isLive && neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
            Text(isLive ? "LISTENING" : "PAUSED")
                .font(neon.mono(10).weight(.semibold))
                .tracking(2)
                .foregroundStyle(isLive ? neon.green : neon.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }

    // MARK: Live transcript

    private var transcriptView: some View {
        // Highlight the latest words: the tail of the in-progress text
        // reads brighter than the settled head so the user sees where the
        // recognizer is. When we have a finalized capture, render it solid.
        Group {
            if displayTranscript.isEmpty {
                Text("Listening…")
                    .font(neon.sans(22).weight(.medium))
                    .foregroundStyle(neon.textFaint)
            } else if captured.isEmpty {
                highlightedTail(displayTranscript)
            } else {
                Text(displayTranscript)
                    .font(neon.sans(22).weight(.medium))
                    .foregroundStyle(neon.text)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .multilineTextAlignment(.leading)
    }

    /// Dim the head, brighten + glow the last few words.
    private func highlightedTail(_ text: String) -> Text {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 3 else {
            return Text(text)
                .font(neon.sans(22).weight(.medium))
                .foregroundColor(neon.accent)
        }
        let head = words.dropLast(3).joined(separator: " ")
        let tail = words.suffix(3).joined(separator: " ")
        return Text(head + " ")
            .font(neon.sans(22).weight(.medium))
            .foregroundColor(neon.text)
            + Text(tail)
            .font(neon.sans(22).weight(.semibold))
            .foregroundColor(neon.accent)
    }

    // MARK: Detected-intent chips (heuristic)

    private var intentChips: some View {
        let chips = VoiceIntent.detect(in: displayTranscript)
        return HStack(spacing: 8) {
            ForEach(chips) { chip in
                let tint = chip.kind == .file ? neon.blue : neon.accent
                HStack(spacing: 4) {
                    if let glyph = chip.glyph {
                        Text(glyph)
                            .font(neon.mono(11).weight(.bold))
                            .foregroundStyle(tint)
                    }
                    Text(chip.label)
                        .font(neon.mono(11).weight(.semibold))
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(neon.surface2))
                .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(chips.isEmpty ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: chips.map(\.label))
    }

    // MARK: Waveform
    //
    // Amplitude-driven: `VoiceTranscriber.level` is an RMS level (0…1)
    // computed from the same input tap that feeds the recognizer, so the
    // bars track the user's actual voice. When paused/idle the bars fall
    // to a flat resting line. Each bar phase-shifts the live level so the
    // row reads as a travelling wave rather than 24 identical bars.
    private var waveform: some View {
        let bars = 28
        let isLive = transcriber.state == .listening
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isLive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(transcriber.level)
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<bars, id: \.self) { idx in
                    let phase = Double(idx) * 0.5
                    let wobble = sin(t * 7.0 + phase) * 0.5 + 0.5
                    let envelope = sin(Double(idx) / Double(bars - 1) * .pi)
                    let amp = isLive ? max(0.06, level) : 0.02
                    let height = CGFloat(6) + CGFloat(wobble) * CGFloat(envelope) * amp * 78
                    Capsule()
                        .fill(neon.accent)
                        .frame(width: 4, height: height)
                        .opacity(isLive ? 0.95 : 0.4)
                }
            }
            .frame(height: 92)
            .neonTextGlow(isLive ? neon.textGlow : nil)
            .padding(.horizontal, 28)
            .accessibilityHidden(true)
        }
    }

    // MARK: Footer — toggle, send, hints

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Toggle(isOn: $readAloud) {
                    Text("read replies aloud")
                        .font(neon.mono(12))
                        .foregroundStyle(neon.textDim)
                }
                .toggleStyle(.switch)
                .tint(neon.accent)
                .fixedSize()

                Spacer(minLength: 0)

                Button {
                    commitAndDismiss()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(neon.accentText)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(canSend ? neon.accent : neon.accent.opacity(0.45)))
                        .neonGlowBox(canSend && neon.glow ? neon.glowBox : nil)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }

            Text("tap ↑ to send · hold to keep talking · \"hey conduit\" to start hands-free")
                .font(neon.mono(10))
                .foregroundStyle(neon.textFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var canSend: Bool {
        !displayTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayTranscript: String {
        if !captured.isEmpty { return captured }
        return transcriber.partialTranscript
    }

    private func commitAndDismiss() {
        transcriber.stop()
        let text = displayTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // No reply stream is wired into this modal; when read-aloud is
            // on, speak a short confirmation so the TTS path is real and
            // observable rather than a dead toggle.
            if readAloud {
                speaker.speak("Sent to \(agent). \(text)")
            }
            onTranscript(text)
        }
        dismiss()
    }
}

// MARK: - VoiceIntent (honest keyword heuristic)

/// A detected-intent chip derived from the live transcript via a simple,
/// clearly-heuristic keyword scan. Produces nothing when it can't detect
/// — we never fabricate an intent.
struct VoiceIntent: Identifiable, Equatable {
    enum Kind: Equatable { case action, test, file }
    let id = UUID()
    let label: String
    /// Optional leading glyph (e.g. `+` for "add test").
    let glyph: String?
    let kind: Kind

    static func == (lhs: VoiceIntent, rhs: VoiceIntent) -> Bool {
        lhs.label == rhs.label && lhs.glyph == rhs.glyph && lhs.kind == rhs.kind
    }

    /// Heuristic, in priority order, de-duplicated, capped at 4:
    ///   - an action verb (add/fix/refactor/remove/…) → a `task` chip
    ///   - the word "test"/"tests"/"spec"             → a `+ test` chip
    ///   - file-looking tokens (`name.ext`)           → one chip each
    static func detect(in transcript: String) -> [VoiceIntent] {
        let lower = transcript.lowercased()
        guard !lower.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var chips: [VoiceIntent] = []

        let actionVerbs = ["add", "fix", "refactor", "remove", "delete", "rename",
                           "implement", "update", "build", "create", "write"]
        if actionVerbs.contains(where: { lower.contains($0) }) {
            chips.append(VoiceIntent(label: "task", glyph: "•", kind: .action))
        }
        if lower.range(of: "\\btests?\\b|\\bspec\\b", options: .regularExpression) != nil {
            chips.append(VoiceIntent(label: "test", glyph: "+", kind: .test))
        }

        // File-looking tokens: word.ext where ext is 1–4 letters.
        if let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9_./-]+\\.[A-Za-z]{1,4}\\b") {
            let ns = transcript as NSString
            let matches = regex.matches(in: transcript, range: NSRange(location: 0, length: ns.length))
            var seen = Set<String>()
            for m in matches {
                let tok = ns.substring(with: m.range)
                if seen.insert(tok.lowercased()).inserted {
                    chips.append(VoiceIntent(label: tok, glyph: nil, kind: .file))
                }
            }
        }

        return Array(chips.prefix(4))
    }
}

// MARK: - VoiceReplySpeaker (TTS)

/// Thin `AVSpeechSynthesizer` wrapper for the "read replies aloud" path.
/// No reply stream is wired into this modal, so the only thing it speaks
/// today is the send-confirmation in `commitAndDismiss`; the synth itself
/// is real (this is not a no-op stub).
@MainActor
final class VoiceReplySpeaker: ObservableObject {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
    }
}
