import Foundation

extension URL {
    /// Keeps the file or folder out of iCloud and computer backups.
    mutating func excludeFromBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? setResourceValues(values)
    }

    /// Writes atomically, unreadable while the device is locked (a write that starts unlocked can still finish), and
    /// outside backups.
    mutating func writeProtected(_ data: Data) {
        try? data.write(to: self, options: [.atomic, .completeFileProtectionUnlessOpen])
        excludeFromBackup()
    }
}
