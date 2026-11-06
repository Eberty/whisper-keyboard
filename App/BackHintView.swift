import SwiftUI

/// Shown when the keyboard opened the app: the mic is on, so it shows how to go back.
struct BackHintView: View {
    @EnvironmentObject private var session: VoiceSession
    let onClose: () -> Void
    @State private var swiping = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.31, green: 0.17, blue: 0.85), Color(red: 0.12, green: 0.64, blue: 0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()
                Image(systemName: isReady ? "mic.circle.fill" : "hourglass.circle.fill")
                    .font(.system(size: 96))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                Text(isReady ? "Ready" : "Loading model")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Swipe right on the bottom bar to go back")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 32)
                // Home screen search is not an app, so there is nothing to swipe back to; the mic stays on meanwhile.
                Text("If it doesn't go back, swipe up")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 32)
                Spacer()
                Spacer()
            }

            // Drawn into the bottom safe area so the fingertip sits right above the system's bar.
            VStack {
                Spacer()
                swipeAnimation
                    .padding(.bottom, 13)
            }
            .ignoresSafeArea(edges: .bottom)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(Text("Close"))
                    .padding()
                }
                Spacer()
            }
        }
        .onAppear { swiping = true }
    }

    private var isReady: Bool { session.state.status == .ready }

    /// A finger pointing at the system's own bottom bar and sliding right, the gesture that returns to the previous app.
    private var swipeAnimation: some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.right")
                .font(.title3.bold())
                .foregroundStyle(.white.opacity(0.8))
            Image(systemName: "hand.point.down.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
        }
        .offset(x: swiping ? 70 : -70)
        .opacity(swiping ? 0.2 : 1)
        .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false), value: swiping)
        .frame(height: 80)
        .accessibilityHidden(true)
    }
}
