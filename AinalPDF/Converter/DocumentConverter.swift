import PDFKit
import UIKit
import WebKit

/// File types the app can turn into a PDF.
enum SourceKind {
    case pdf, image, docx, web

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    static let webExtensions: Set<String> = ["doc", "pptx", "xlsx", "pages", "numbers", "key", "rtf", "csv", "txt", "svg", "html", "htm"]

    init?(extension ext: String) {
        let ext = ext.lowercased()
        if ext == "pdf" { self = .pdf }
        else if ext == "docx" { self = .docx }
        else if Self.imageExtensions.contains(ext) { self = .image }
        else if Self.webExtensions.contains(ext) { self = .web }
        else { return nil }
    }
}

enum ConversionFailure: LocalizedError {
    case unsupported(String)
    case unreadable
    case failed

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "Files of type .\(ext) are not supported yet."
        case .unreadable: return "The file could not be opened."
        case .failed: return "The file could not be converted. Try another file."
        }
    }
}

/// One entry point: give it any supported file, get a PDF back. Everything runs on the device.
@MainActor
enum DocumentConverter {

    static func convert(fileURL: URL) async throws -> PDFDocument {
        let ext = fileURL.pathExtension
        guard let kind = SourceKind(extension: ext) else { throw ConversionFailure.unsupported(ext) }

        switch kind {
        case .pdf:
            guard let pdf = PDFDocument(url: fileURL) else { throw ConversionFailure.unreadable }
            return pdf

        case .image:
            guard let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data),
                  let pdf = ImagePDFBuilder.makePDF(from: [image]) else { throw ConversionFailure.unreadable }
            return pdf

        case .docx:
            do {
                return try await DocxPDFConverter().convert(fileURL: fileURL)
            } catch {
                log("docx renderer failed (\(error)), trying WebKit")
                return try await convertWithWebKit(fileURL: fileURL, ext: ext)
            }

        case .web:
            return try await convertWithWebKit(fileURL: fileURL, ext: ext)
        }
    }

    static func convert(images: [UIImage]) throws -> PDFDocument {
        guard let pdf = ImagePDFBuilder.makePDF(from: images) else { throw ConversionFailure.failed }
        return pdf
    }

    private static func convertWithWebKit(fileURL: URL, ext: String) async throws -> PDFDocument {
        guard let pdf = await WebFileConverter().convert(fileURL: fileURL, ext: ext) else { throw ConversionFailure.failed }
        return pdf
    }
}

/// Opens a file in a hidden WebKit view and exports the result as a PDF.
@MainActor
final class WebFileConverter: NSObject, WKNavigationDelegate {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Bool, Never>?

    func convert(fileURL: URL, ext: String) async -> PDFDocument? {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        // WebKit only prints views that sit in a window, so keep it there but invisible.
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        Self.keyWindow?.insertSubview(view, at: 0)
        view.navigationDelegate = self
        webView = view
        defer {
            view.removeFromSuperview()
            webView = nil
        }

        let loaded = await load(fileURL, in: view)
        guard loaded else { return nil }
        return await WebDocumentPDFExporter.export(from: view, fileExtension: FileNameExtensions(from: ext))
    }

    private func load(_ url: URL, in view: WKWebView) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            continuation = cont
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            // Give up after 45 seconds.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                self?.finish(false)
            }
        }
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

/// Only the cases the exporter looks at.
enum FileNameExtensions {
    case xlsx, csv, txt, rtf, other

    init(from ext: String) {
        switch ext.lowercased() {
        case "xlsx": self = .xlsx
        case "csv": self = .csv
        case "txt": self = .txt
        case "rtf": self = .rtf
        default: self = .other
        }
    }
}
