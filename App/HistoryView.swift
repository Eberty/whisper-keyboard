import SwiftUI
import UIKit
import LocalAuthentication

struct HistoryView: View {
    @ObservedObject var history: TranscriptHistory
    let onClear: () -> Void
    @State private var copiedID: UUID?
    @State private var confirmingClear = false

    var body: some View {
        List {
            Section {
                ForEach(history.entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: entry.text)
                                .textSelection(.enabled)
                            Text(entry.date, format: .dateTime.day().month().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            TemporaryCopy.copy(entry.text)
                            copiedID = entry.id
                        } label: {
                            Image(systemName: copiedID == entry.id ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.title3)
                                .foregroundStyle(copiedID == entry.id ? Color.green : Color.accentColor)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(copiedID == entry.id ? Text("Copied") : Text("Copy"))
                    }
                }
                .onDelete(perform: history.remove(atOffsets:))
            } footer: {
                if !history.entries.isEmpty {
                    Label("Only the last \(TranscriptHistory.limit) are kept, on this device only. Audio is never saved.",
                          systemImage: "lock.fill")
                }
            }
        }
        .overlay {
            if history.entries.isEmpty {
                ContentUnavailableView("No transcriptions", systemImage: "text.bubble")
            }
        }
        .navigationTitle("History")
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !history.entries.isEmpty {
                Button("Delete all", systemImage: "trash", role: .destructive) { confirmingClear = true }
            }
        }
        .alert("Delete all history?", isPresented: $confirmingClear) {
            Button("Delete all", role: .destructive, action: onClear)
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Asks for Face ID, or the device passcode, before showing History; it stays unlocked until the app goes to the background.
struct LockedHistoryView: View {
    @ObservedObject var history: TranscriptHistory
    let onClear: () -> Void
    @Binding var isUnlocked: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// Asks again on return from the background, not after the Face ID prompt itself, so a cancel does not loop.
    @State private var cameFromBackground = false

    var body: some View {
        if isUnlocked {
            HistoryView(history: history, onClear: onClear)
        } else {
            ContentUnavailableView {
                Label("History is locked", systemImage: "lock.fill")
            } actions: {
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("History")
            .toolbar(.visible, for: .navigationBar)
            // Only while on screen: Face ID cannot run with the app in the background.
            .task { if scenePhase == .active { unlock() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cameFromBackground = true }
                if phase == .active && cameFromBackground {
                    cameFromBackground = false
                    unlock()
                }
            }
        }
    }

    private func unlock() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Without a device passcode there is nothing to check against.
            if error?.code == LAError.passcodeNotSet.rawValue { isUnlocked = true }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock History")) { success, _ in
            DispatchQueue.main.async { if success { isUnlocked = true } }
        }
    }
}
