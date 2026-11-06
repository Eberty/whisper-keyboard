import SwiftUI
import UIKit

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    weak var controller: KeyboardViewController?
    /// Landscape on the iPhone leaves little height, so the keys go in one row there.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private static let punctuation = [".", ",", "?", "!", "'"]

    var body: some View {
        VStack(spacing: 6) {
            // Fixed size and a fixed-height row, so the hint sits in the same place whatever the text or text size.
            Text(model.hint)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 16)
                .padding(.top, 11)
                .padding(.horizontal, 12)

            GeometryReader { geometry in
                MicButton(touchSize: touchSize(in: geometry.size), status: model.status,
                          onPress: model.micPressed, onRelease: model.micReleased)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }

            Group {
                if verticalSizeClass == .compact {
                    KeyRow(spacing: Self.keySpacing) {
                        globeKey
                        punctuationKeys
                        spaceKey.keyWeight(3)
                        returnKey.keyWeight(1.5)
                        deleteKey
                    }
                    .frame(height: Self.keyHeight)
                } else {
                    VStack(spacing: Self.rowSpacing) {
                        KeyRow(spacing: Self.keySpacing) {
                            punctuationKeys
                            deleteKey
                        }
                        .frame(height: Self.keyHeight)
                        KeyRow(spacing: Self.keySpacing) {
                            globeKey
                            spaceKey.keyWeight(4)
                            returnKey.keyWeight(2)
                        }
                        .frame(height: Self.keyHeight)
                    }
                }
            }
            .padding(.horizontal, Self.sideMargin)
            .padding(.bottom, Self.bottomMargin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var globeKey: some View {
        if model.showsGlobe, let controller {
            GlobeKey(controller: controller)
                .keyWeight(1.5)
        }
    }

    @ViewBuilder private var punctuationKeys: some View {
        ForEach(Self.punctuation, id: \.self) { mark in
            TextKey(label: Text(verbatim: mark), size: 22) { model.insertText(mark) }
        }
    }

    private var spaceKey: some View {
        TextKey(label: Text("Space"), size: 16) { model.insertText(" ") }
    }

    private var returnKey: some View {
        KeyButton(systemImage: "return.left") { model.insertText("\n") }
            .accessibilityLabel("Return")
    }

    @ViewBuilder private var deleteKey: some View {
        if model.status == .recording {
            // While recording, delete becomes cancel: stops without transcribing.
            KeyButton(systemImage: "xmark", action: model.cancelRecording)
                .accessibilityLabel("Cancel recording")
        } else {
            RepeatingKey(systemImage: "delete.left", action: model.deleteBackward,
                         fastAction: model.deleteWordBackward)
        }
    }

    /// Key size and margins match Apple's keyboard, which is larger on the iPad.
    private static let keyHeight: CGFloat = isPad ? 61 : 43
    private static let keySpacing: CGFloat = isPad ? 7.5 : 6
    private static let rowSpacing: CGFloat = isPad ? 7.5 : 11
    private static let sideMargin: CGFloat = isPad ? 3.5 : 6.5
    private static let bottomMargin: CGFloat = isPad ? 0 : 3
    private static let maxTouchSize: CGFloat = 116

    /// The mic's touch area fills the height left for it.
    private func touchSize(in size: CGSize) -> CGFloat {
        min(Self.maxTouchSize, size.height)
    }
}

/// The touch area keeps its full size; only the drawn circle is smaller, so the pulse fits inside the keyboard.
private struct MicButton: View {
    private static let drawingScale: CGFloat = 0.74

    let touchSize: CGFloat
    let status: VoiceStatus
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isPressed = false

    private var size: CGFloat { touchSize * Self.drawingScale }

    var body: some View {
        ZStack {
            if status == .recording {
                PulseRing(color: .red)
            }
            Circle()
                .fill(fill)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            if status == .transcribing || status == .loading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else {
                // Drawn as a font glyph, so the system centers it optically, slash variants included.
                Image(systemName: micSymbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(isPressed || status == .recording ? 1.06 : 1)
        .animation(.easeOut(duration: 0.15), value: isPressed)
        .animation(.easeOut(duration: 0.15), value: status)
        .frame(width: touchSize, height: touchSize)
        .contentShape(Circle())
        .pressGesture(onPress: press, onRelease: release)
        .accessibilityLabel("Microphone")
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        onPress()
    }

    /// Runs once per press, whether the touch ended normally or was cancelled.
    private func release() {
        guard isPressed else { return }
        isPressed = false
        onRelease()
    }

    private var fill: Color {
        switch status {
        case .recording: return .red
        case .ready: return .accentColor
        case .off, .loading, .transcribing, .unavailable: return .gray
        }
    }

    private var micSymbol: String {
        switch status {
        case .off: return "mic.slash.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .recording: return "waveform"
        default: return "mic.fill"
        }
    }
}

/// Expanding ring shown around the mic while it listens.
private struct PulseRing: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(expanded ? 0 : 0.5), lineWidth: 6)
            .scaleEffect(expanded ? 1.2 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1).repeatForever(autoreverses: false)) { expanded = true }
            }
    }
}

/// A key that types text, such as a punctuation mark or the space bar.
private struct TextKey: View {
    let label: Text
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: size))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyStyle())
    }
}

private struct KeyButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            KeyLabel(systemImage: systemImage)
        }
        .buttonStyle(KeyStyle())
    }
}

/// Deletes on touch down and repeats while held, moving to whole words like Apple's keyboard; a cancel stops it.
private struct RepeatingKey: View {
    private static let repeatsBeforeWords = 12

    let systemImage: String
    let action: () -> Void
    let fastAction: () -> Void
    @State private var isPressed = false
    @State private var timer: Timer?

    var body: some View {
        KeyLabel(systemImage: systemImage)
            .background(KeyBackground(isPressed: isPressed))
            .pressGesture(onPress: startRepeating, onRelease: stopRepeating)
            .onDisappear(perform: stopRepeating)
            .accessibilityLabel("Delete")
    }

    private func startRepeating() {
        guard !isPressed else { return }
        isPressed = true
        action()
        var repeats = 0
        timer = .onCommonModes(after: 0.45, repeats: false) { _ in
            timer = .onCommonModes(after: 0.09, repeats: true) { _ in
                repeats += 1
                guard repeats > Self.repeatsBeforeWords else { return action() }
                // Words go slower than letters, so the user can still stop in time.
                if repeats % 3 == 0 { fastAction() }
            }
        }
    }

    private func stopRepeating() {
        isPressed = false
        timer?.invalidate()
        timer = nil
    }
}

private struct KeyLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(KeyBackground(isPressed: configuration.isPressed))
    }
}

private struct KeyBackground: View {
    let isPressed: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color(uiColor: isPressed ? Self.pressedColor : Self.color))
    }

    static let cornerRadius: CGFloat = isPad ? 12 : 8
    /// Apple's key colors, in sRGB.
    static let color = UIColor { traits in
        // iOS lightens the keyboard's content a little in dark mode; this ends up as Apple's gray on screen.
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.25, green: 0.25, blue: 0.255, alpha: 1) : .white
    }
    private static let pressedColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.38, green: 0.38, blue: 0.39, alpha: 1)
            : UIColor(red: 0.8, green: 0.81, blue: 0.83, alpha: 1)
    }
}

private struct GlobeKey: UIViewRepresentable {
    weak var controller: KeyboardViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.backgroundColor = KeyBackground.color
        button.layer.cornerRadius = KeyBackground.cornerRadius
        button.layer.cornerCurve = .continuous
        button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                         for: .allTouchEvents)
        button.accessibilityLabel = String(localized: "Next keyboard")
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}

/// Key size and corners follow Apple's keyboard, which is larger on the iPad.
private let isPad = UIDevice.current.userInterfaceIdiom == .pad

private extension View {
    /// Calls `onPress` when a finger lands (again as it moves) and `onRelease` when it lifts or the system cancels the
    /// touch, which never ends the drag.
    func pressGesture(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressGesture(onPress: onPress, onRelease: onRelease))
    }
}

private struct PressGesture: ViewModifier {
    let onPress: () -> Void
    let onRelease: () -> Void
    @GestureState private var isTouching = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouching) { _, touching, _ in touching = true }
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
            .onChange(of: isTouching) { _, touching in
                if !touching { onRelease() }
            }
    }
}

/// Keys side by side, each as wide as its weight, like the wider space bar on Apple's keyboard.
private struct KeyRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let weights = subviews.map { $0[KeyWeight.self] }
        let unit = (bounds.width - spacing * CGFloat(max(subviews.count - 1, 0))) / max(weights.reduce(0, +), 1)
        var x = bounds.minX
        for (subview, weight) in zip(subviews, weights) {
            let width = unit * weight
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

private struct KeyWeight: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

private extension View {
    func keyWeight(_ weight: CGFloat) -> some View {
        layoutValue(key: KeyWeight.self, value: weight)
    }
}
