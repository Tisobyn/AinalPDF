import SwiftUI

/// Shows the new PDF with Share (also Save to Files / Print) and Done.
struct ResultView: View {
    let file: ConvertedFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFPreview(url: file.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    ShareLink(item: file.url) {
                        Label("Share or save PDF", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(.bar)
                }
        }
    }
}
