import DesignSystem
import SwiftUI

/// A Form section for Settings: download or remove the picture-search model, and see how many
/// visits it has looked at.
public struct SemanticSearchSettings: View {
    @ObservedObject private var model: SemanticModel
    @State private var indexed = 0
    @State private var confirmRemove = false

    public init(model: SemanticModel = .shared) {
        self.model = model
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public var body: some View {
        Section {
            Text("Search by what's in the picture: \"red van\", \"man in a hat\". Uses Apple's MobileCLIP on this Mac; a one-off download of about \(Self.size(SemanticModel.downloadBytes)) from Hugging Face.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.state {
            case .notInstalled:
                Button("Download") { model.download() }
            case .downloading(let fraction):
                HStack {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Downloading picture search")
                    Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel") { model.cancel() }
                }
            case .compiling:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Getting it ready…").foregroundStyle(.secondary)
                }
            case .ready:
                LabeledContent("Model") {
                    HStack {
                        Text("On this Mac, \(Self.size(model.installedBytes))").foregroundStyle(.secondary)
                        Button("Remove") { confirmRemove = true }
                    }
                }
                LabeledContent("Visits looked at") {
                    Text(indexed == 1 ? "1 visit" : "\(indexed) visits").monospacedDigit().foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).foregroundStyle(DS.ember)
                Button("Try again") { model.download() }
            }
        } header: {
            Text("Picture search")
        } footer: {
            Text("Pictures never leave this Mac. Removing the model keeps what it has already learnt about your visits.")
        }
        .confirmationDialog("Remove the picture search model?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove() }
        } message: {
            Text("You can download it again at any time.")
        }
        .task {
            while !Task.isCancelled {
                indexed = await SemanticIndex.shared.count
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
