import SwiftUI

/// Shows the repository's LICENSE file, bundled with the app, with each paragraph reflowed to the screen width.
struct LicenseView: View {
    private let text: String = {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return contents
            .components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n").joined(separator: " ") }
            .joined(separator: "\n\n")
    }()

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: AppInfo.license))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
