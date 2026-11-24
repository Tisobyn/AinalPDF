//
//  DocxPDFConverter.swift
//  airprinter
//

import PDFKit
import WebKit

/// Converts a .docx to a PDF fully on device.
///
/// The file is rendered with the bundled docx-preview library inside an offscreen `WKWebView`
/// (see `docx_render.html`). Every Word page becomes one PDF page: each page's rect is exported
/// with `createPDF` and the results are merged with PDFKit.
@MainActor
final class DocxPDFConverter: NSObject, WKNavigationDelegate {

    enum ConversionError: Error {
        case resourceMissing
        case unreadableFile
        case renderFailed
        case exportFailed
    }

    /// Wide enough for any Word page size; the real page rects are measured in JS.
    private static let viewportWidth: CGFloat = 1400

    static var renderPageURL: URL? {
        Bundle.main.url(forResource: "docx_render", withExtension: "html")
    }

    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: Self.viewportWidth, height: 1600),
            configuration: configuration
        )
        super.init()
        webView.navigationDelegate = self
    }

    func convert(fileURL: URL) async throws -> PDFDocument {
        guard let pageURL = Self.renderPageURL else { throw ConversionError.resourceMissing }
        guard let data = try? Data(contentsOf: fileURL) else { throw ConversionError.unreadableFile }

        try await load(pageURL)

        let rects = try await renderPages(data)
        guard !rects.isEmpty else { throw ConversionError.renderFailed }

        // createPDF only captures what the view covers, so grow the view to the whole document.
        let contentHeight = webView.scrollView.contentSize.height
        if contentHeight > webView.frame.height {
            webView.frame.size.height = contentHeight
            try await Task.sleep(nanoseconds: 100_000_000) // let the layout settle
        }

        let merged = PDFDocument()
        for rect in rects {
            let configuration = WKPDFConfiguration()
            configuration.rect = rect
            let pageData = try await webView.pdf(configuration: configuration)
            guard let source = PDFDocument(data: pageData)?.page(at: 0),
                  let page = Self.scaledToPoints(source) else {
                throw ConversionError.exportFailed
            }
            merged.insert(page, at: merged.pageCount)
        }

        guard merged.pageCount > 0 else { throw ConversionError.exportFailed }
        return merged
    }

    // MARK: - Private

    /// WebKit exports one CSS px as one PDF point, so a Letter page comes out as 816×1056.
    /// Redraw it at 72 dpi (px × 0.75) so pages have real paper sizes: Letter 612×792, A4 595×842.
    /// The page is drawn, not rasterised, so text and vectors stay sharp.
    private static func scaledToPoints(_ page: PDFPage) -> PDFPage? {
        let scale: CGFloat = 72.0 / 96.0
        let source = page.bounds(for: .mediaBox)
        let size = CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        let data = renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            // PDFPage.draw uses PDF space (origin bottom-left); the renderer's context is flipped.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: size.width / source.width, y: -size.height / source.height)
            page.draw(with: .mediaBox, to: cg)
        }
        return PDFDocument(data: data)?.page(at: 0)
    }

    private func renderPages(_ data: Data) async throws -> [CGRect] {
        let result = try await webView.callAsyncJavaScript(
            "return await window.renderDocx(b64, 'export');",
            arguments: ["b64": data.base64EncodedString()],
            in: nil,
            contentWorld: .page
        )
        guard let items = result as? [[String: Any]] else { throw ConversionError.renderFailed }
        return items.compactMap { item in
            guard
                let x = (item["x"] as? NSNumber)?.doubleValue,
                let y = (item["y"] as? NSNumber)?.doubleValue,
                let w = (item["w"] as? NSNumber)?.doubleValue,
                let h = (item["h"] as? NSNumber)?.doubleValue,
                w > 0, h > 0
            else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private func load(_ pageURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}
