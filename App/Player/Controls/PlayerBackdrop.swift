import SwiftUI

/// Non-interactive layer over the video: scrims behind the controls, the OSD pill,
/// the buffering indicator and the optional diagnostics panel.
struct PlayerBackdrop: View {
    let model: PlayerModel
    /// Extra diagnostic lines owned by the view controller (layer, screen, posture).
    let environmentLines: () -> [String]

    var body: some View {
        ZStack {
            // The scrims keep floating controls legible; controls with their own area
            // leave the picture untouched.
            scrims
                .opacity(showsScrims ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: showsScrims)

            if model.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            VStack(spacing: 12) {
                if let osd = model.osd {
                    OSDPill(message: osd)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
                if model.showsDiagnostics {
                    diagnostics
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 64)
            .padding(.horizontal, 16)
            .animation(.snappy(duration: 0.2), value: model.osd != nil)
        }
        .ignoresSafeArea()
    }

    private var showsScrims: Bool {
        model.controlsVisible && !model.hasDedicatedControlArea
    }

    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
        }
    }

    private var diagnostics: some View {
        let lines = PlayerModel.diagnosticProperties.map { "\($0): \(model.diagnostics[$0] ?? "-")" }
            + environmentLines()
        return Text(lines.joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Transient feedback for gestures and property changes.
private struct OSDPill: View {
    let message: OSDMessage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)
            if let level = message.level {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 96, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.white)
                            .frame(width: 96 * min(max(level, 0), 1), height: 4)
                    }
            }
            Text(message.text)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}
