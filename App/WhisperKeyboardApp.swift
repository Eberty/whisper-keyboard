import SwiftUI

@main
struct WhisperKeyboardApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var session = VoiceSession()
    @State private var openedFromKeyboard = false
    /// Set when a link brought the app forward; a link from another app or page only opens it, without the mic.
    @State private var openedByLink = false
    /// The mic turns on only when the app comes back from the background (or launches), not after a brief
    /// interruption such as Face ID, Control Center or an alert, so it stays off if the user turned it off.
    @State private var cameFromBackground = true
    @Environment(\.scenePhase) private var scenePhase

    private static let linkWait: TimeInterval = 0.3

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                // Hides the screen in the app switcher's snapshot, which could show transcriptions.
                .overlay {
                    if scenePhase != .active { PrivacyCover() }
                }
                .fullScreenCover(isPresented: $openedFromKeyboard) {
                    BackHintView { openedFromKeyboard = false }
                        .environmentObject(session)
                }
                .onOpenURL { url in
                    openedByLink = true
                    // Only the keyboard's own wake request turns the mic on and shows how to go back.
                    guard url.host == "start", session.handleWakeURL() else { return }
                    openedFromKeyboard = true
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .background {
                        openedFromKeyboard = false
                        openedByLink = false
                        AppDelegate.launchedByLink = false
                        cameFromBackground = true
                        session.didEnterBackground()
                    }
                    if phase == .active { TemporaryCopy.clearIfDue() }
                    guard phase == .active, cameFromBackground else { return }
                    cameFromBackground = false
                    // The link, if any, arrives around activation; wait for it before deciding.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkWait) {
                        if !openedByLink && !AppDelegate.launchedByLink { session.startMicrophone() }
                        openedByLink = false
                        AppDelegate.launchedByLink = false
                    }
                }
        }
    }
}

/// Tells whether a link launched the app, which SwiftUI only reports later, in onOpenURL.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var launchedByLink = false

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if !options.urlContexts.isEmpty { Self.launchedByLink = true }
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Image("Logo")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .ignoresSafeArea()
    }
}
