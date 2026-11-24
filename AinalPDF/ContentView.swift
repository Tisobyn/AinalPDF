import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = ConverterViewModel()
    @State private var showImporter = false
    @State private var photoItems: [PhotosPickerItem] = []

    private let formats = ["Word", "PowerPoint", "Excel", "Pages", "Keynote", "Numbers", "RTF", "TXT", "CSV", "Photos"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    actions
                    formatChips
                    if !model.history.isEmpty { recent }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Ainal PDF")
            .overlay { if case .converting(let label) = model.state { busyOverlay(label) } }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result { model.handle(importedURLs: urls) }
        }
        .onChange(of: photoItems) { items in
            model.handle(photos: items)
            photoItems = []
        }
        .sheet(item: $model.result) { ResultView(file: $0) }
        .alert("Could not convert", isPresented: failedBinding) {
            Button("OK", role: .cancel) { model.state = .idle }
        } message: {
            if case .failed(let text) = model.state { Text(text) }
        }
    }

    // MARK: - Pieces

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.arrow.up.fill")
                .font(.system(size: 54))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("Make any file a PDF")
                .font(.title2.bold())
            Text("Pick a document or photos. It is converted on your phone. Nothing is uploaded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button { showImporter = true } label: {
                bigButtonLabel("Choose a file", icon: "folder.fill")
            }
            .buttonStyle(.borderedProminent)

            PhotosPicker(selection: $photoItems, matching: .images) {
                bigButtonLabel("Choose photos", icon: "photo.on.rectangle.angled")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(model.isBusy)
    }

    private func bigButtonLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private var formatChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Works with").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(formats, id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(model.history) { file in
                    Button { model.result = file } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.richtext.fill").font(.title2).foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.body).lineLimit(1)
                                Text("\(file.pageCount) \(file.pageCount == 1 ? "page" : "pages") · \(file.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ShareLink(item: file.url)
                        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(file) }
                    }
                    if file != model.history.last { Divider().padding(.leading, 52) }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func busyOverlay(_ label: String) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Converting…").font(.headline)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var failedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = model.state { return true } else { return false } },
            set: { if !$0 { model.state = .idle } }
        )
    }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.pdf, .image, .rtf, .plainText, .commaSeparatedText, .svg]
        let ids = [
            "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
            "org.openxmlformats.presentationml.presentation", "org.openxmlformats.spreadsheetml.sheet",
            "com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages",
            "com.apple.iwork.keynote.key", "com.apple.iwork.keynote.sffkey",
            "com.apple.iwork.numbers.numbers", "com.apple.iwork.numbers.sffnumbers"
        ]
        types += ids.compactMap { UTType($0) }
        return types
    }()
}

/// Simple wrapping row layout for the format chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

#Preview { ContentView() }
