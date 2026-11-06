import SwiftUI

/// Words the user wants written their way (names, acronyms, technical terms); they guide Whisper's spelling.
/// Whisper reads only a short prompt, so the list holds what fits there, measured by `fits`.
struct VocabularyView: View {
    @ObservedObject var settings: AppSettings
    let fits: ([String]) -> Bool
    @State private var newWord = ""
    @State private var isFull = false

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add a word", text: $newWord)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(trimmed.isEmpty)
                    .accessibilityLabel(Text("Add"))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Names and terms Whisper should write the way you type them here.")
                    if isFull {
                        Label("The list is full. Delete a word to add another.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if !settings.vocabulary.isEmpty {
                Section {
                    ForEach(settings.vocabulary, id: \.self) { word in
                        Text(verbatim: word)
                    }
                    .onDelete { offsets in
                        settings.vocabulary.remove(atOffsets: offsets)
                        isFull = false
                    }
                }
            }
        }
        .navigationTitle("Vocabulary")
        .toolbar(.visible, for: .navigationBar)
    }

    private var trimmed: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let word = trimmed
        guard !word.isEmpty,
              !settings.vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        let words = settings.vocabulary + [word]
        guard fits(words) else {
            isFull = true
            return
        }
        settings.vocabulary = words
        newWord = ""
        isFull = false
    }
}
