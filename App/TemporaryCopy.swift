import UIKit
import UniformTypeIdentifiers

/// Copies text to the clipboard for a short while. The app clears it itself instead of using an expiration date:
/// an expired item still tells keyboards there is text, but pasting it fails.
enum TemporaryCopy {
    /// How long a copied transcription stays in the clipboard.
    static let lifetime: TimeInterval = 300
    private static let deadlineKey = "copyDeadline"
    private static let changeCountKey = "copyChangeCount"

    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]])
        // The change count is read a moment later, once the system has saved the copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let defaults = UserDefaults.standard
            defaults.set(Date().addingTimeInterval(lifetime), forKey: deadlineKey)
            defaults.set(UIPasteboard.general.changeCount, forKey: changeCountKey)
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + lifetime) { clearIfDue() }
        }
    }

    /// Clears the copy once its time is up, unless something else was copied since. Also runs when the app comes
    /// to the front, since the timer cannot fire while the app is suspended or closed.
    static func clearIfDue() {
        let defaults = UserDefaults.standard
        guard let deadline = defaults.object(forKey: deadlineKey) as? Date, deadline <= Date() else { return }
        if UIPasteboard.general.changeCount == defaults.integer(forKey: changeCountKey) {
            UIPasteboard.general.items = []
        }
        defaults.removeObject(forKey: deadlineKey)
        defaults.removeObject(forKey: changeCountKey)
    }
}
