import SwiftUI

/// Global voice dictation modal — invoked from the bottom-bar mic when
/// the user is on the home view or anywhere outside a chat composer.
/// Reuses `VoiceTranscriber` (the same `SFSpeechRecognizer` pipeline
/// that powers `InlineVoiceButton`) so we don't have two competing
/// recognition stacks.
struct VoiceDictationSheet: View {
    let onTranscript: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var transcriber = VoiceTranscriber()
    @State private var captured: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                VStack(spacing: 26) {
                    Spacer()
                    if case .error(let message) = transcriber.state {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(SweKittyTheme.danger)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(SweKittyTheme.danger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    } else {
                        waveform
                        Text(displayTranscript.isEmpty ? "Listening…" : displayTranscript)
                            .font(.title3)
                            .foregroundStyle(SweKittyTheme.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .frame(minHeight: 80, alignment: .top)
                    }
                    Spacer()
                    HStack(spacing: 18) {
                        Button(role: .cancel) {
                            transcriber.stop()
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .font(.headline)
                                .foregroundStyle(SweKittyTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .glassRoundedRect(cornerRadius: 24)
                        }
                        .buttonStyle(.plain)

                        Button {
                            commitAndDismiss()
                        } label: {
                            Text("Send")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(SweKittyTheme.textOnAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(SweKittyTheme.accentStrong)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(displayTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(displayTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .tint(SweKittyTheme.accentStrong)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        transcriber.stop()
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
            .onDisappear { transcriber.stop() }
        }
        .appearanceColorScheme()
    }

    private var displayTranscript: String {
        if !captured.isEmpty { return captured }
        return transcriber.partialTranscript
    }

    /// Big waveform — 24 vertical bars with sine-driven heights, each
    /// bar phase-shifted so the row reads as a travelling wave. The
    /// values don't reflect actual audio levels (that would need a
    /// second tap on the audio buffer; redundant with the recognizer
    /// pipeline). The point is to look alive while the user dictates.
    private var waveform: some View {
        let bars = 24
        let isLive = transcriber.state == .listening
        return TimelineView(.animation(minimumInterval: 1.0/30.0, paused: !isLive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<bars, id: \.self) { idx in
                    let phase = Double(idx) * 0.45
                    let base = sin(t * 4.0 + phase) * 0.5 + 0.5
                    let envelope = sin(Double(idx) / Double(bars - 1) * .pi)
                    let height = isLive
                        ? CGFloat(8 + base * envelope * 70)
                        : CGFloat(8)
                    Capsule()
                        .fill(SweKittyTheme.accentStrong)
                        .frame(width: 5, height: height)
                        .opacity(isLive ? 0.95 : 0.45)
                }
            }
            .frame(height: 90)
            .padding(.horizontal, 32)
            .accessibilityHidden(true)
        }
    }

    private func commitAndDismiss() {
        transcriber.stop()
        let text = displayTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            onTranscript(text)
        }
        dismiss()
    }
}
