import SwiftUI
import Combine
import PDFKit
import PhotosUI

struct ConvertedFile: Identifiable, Hashable {
    let url: URL
    let date: Date
    let pageCount: Int
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum ConvertState: Equatable {
    case idle
    case converting(String)
    case failed(String)
}

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published var state: ConvertState = .idle
    @Published var result: ConvertedFile?
    @Published var history: [ConvertedFile] = []

    private let folder: URL = {
        let url = URL.documentsDirectory.appendingPathComponent("Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() { reloadHistory() }

    var isBusy: Bool {
        if case .converting = state { return true }
        return false
    }

    // MARK: - Input

    func handle(importedURLs urls: [URL]) {
        guard let url = urls.first else { return }
        // Copy first: the picked file is only readable for a short time.
        let access = url.startAccessingSecurityScopedResource()
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            if access { url.stopAccessingSecurityScopedResource() }
            state = .failed(ConversionFailure.unreadable.localizedDescription)
            return
        }
        if access { url.stopAccessingSecurityScopedResource() }

        run(name: url.deletingPathExtension().lastPathComponent, label: url.lastPathComponent) {
            try await DocumentConverter.convert(fileURL: copy)
        }
    }

    func handle(photos items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        run(name: "Photos", label: items.count == 1 ? "1 photo" : "\(items.count) photos") {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            guard !images.isEmpty else { throw ConversionFailure.unreadable }
            return try DocumentConverter.convert(images: images)
        }
    }

    // MARK: - Work

    private func run(name: String, label: String, work: @escaping () async throws -> PDFDocument) {
        guard !isBusy else { return }
        state = .converting(label)
        Task {
            do {
                let pdf = try await work()
                let saved = try save(pdf, name: name)
                result = saved
                state = .idle
                reloadHistory()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func save(_ pdf: PDFDocument, name: String) throws -> ConvertedFile {
        var url = folder.appendingPathComponent("\(name).pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).pdf")
            n += 1
        }
        guard pdf.write(to: url) else { throw ConversionFailure.failed }
        return ConvertedFile(url: url, date: Date(), pageCount: pdf.pageCount)
    }

    // MARK: - History

    func reloadHistory() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        history = urls.filter { $0.pathExtension == "pdf" }.compactMap { url in
            guard let pdf = PDFDocument(url: url) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return ConvertedFile(url: url, date: date, pageCount: pdf.pageCount)
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ file: ConvertedFile) {
        try? FileManager.default.removeItem(at: file.url)
        reloadHistory()
    }
}
