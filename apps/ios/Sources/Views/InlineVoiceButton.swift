import SwiftUI

/// Glass-styled push-to-talk mic for the composer.
///
/// Tap-and-hold gesture: while held, transcription is live and the partial
/// transcript is shown to the user. Release flushes the transcript into the
/// `onTranscript` closure (the composer wires this into `SessionStore.sendChat`
/// or appends to the in-progress draft).
struct InlineVoiceButton: View {
    @StateObject private var transcriber = VoiceTranscriber()
    let onTranscript: (String) -> Void

    var body: some View {
        Button(action: {}) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: 42, height: 42)
                Image(systemName: iconName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(foreground)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.0001)
                .onEnded { _ in
                    transcriber.start { final in
                        onTranscript(final)
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    transcriber.stop()
                }
        )
        .accessibilityLabel("Dictate reply")
        .overlay(alignment: .bottom) {
            if !transcriber.partialTranscript.isEmpty
                && transcriber.state == .listening
            {
                Text(transcriber.partialTranscript)
                    .font(.caption2)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SweKittyTheme.surface.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .offset(y: 48)
                    .frame(maxWidth: 200, alignment: .leading)
            }
        }
    }

    private var iconName: String {
        switch transcriber.state {
        case .listening:
            return "waveform"
        case .finalizing:
            return "ellipsis"
        case .error:
            return "exclamationmark.triangle.fill"
        default:
            return "mic.fill"
        }
    }

    private var background: Color {
        switch transcriber.state {
        case .listening:
            return SweKittyTheme.accentStrong
        case .error:
            return SweKittyTheme.danger.opacity(0.85)
        default:
            return SweKittyTheme.surface.opacity(0.75)
        }
    }

    private var foreground: Color {
        switch transcriber.state {
        case .listening:
            return SweKittyTheme.textOnAccent
        case .error:
            return SweKittyTheme.textOnAccent
        default:
            return SweKittyTheme.accentStrong
        }
    }
}
