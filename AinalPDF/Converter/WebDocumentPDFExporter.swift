//
//  WebDocumentPDFExporter.swift
//  airprinter
//

import PDFKit
import UIKit
import WebKit

/// Turns whatever WebKit rendered for an office document into a paginated, printable PDF.
///
/// WebKit shows each format differently, so the export strategy follows what is on the page:
/// - presentations (`div.slide`): one landscape A4 page per slide
/// - spreadsheets: grid lines, margins, landscape when the sheet is wide
/// - iWork files (WebKit embeds a PDF): paper orientation follows the pages
/// - text, rtf, csv and Word documents: A4 pages with margins
@MainActor
enum WebDocumentPDFExporter {

    private enum Kind {
        case slides
        case pdfEmbed
        case spreadsheet
        case plainText
        case document
    }

    private static let portrait = CGSize(width: PageSize.a4Width, height: PageSize.a4Height)
    private static let landscape = CGSize(width: PageSize.a4Height, height: PageSize.a4Width)

    static func export(from webView: WKWebView, fileExtension: FileNameExtensions?) async -> PDFDocument? {
        let kind = await detectKind(webView, fileExtension: fileExtension)
        log("WebDocumentPDFExporter: \(kind)")

        let data: Data?
        switch kind {
        case .slides:
            data = await slidesPDF(from: webView)
        case .pdfEmbed:
            data = await embeddedPDF(from: webView)
        case .spreadsheet:
            data = await spreadsheetPDF(from: webView)
        case .plainText:
            data = await printedPDF(from: webView, paper: portrait, insets: UIEdgeInsets(top: 48, left: 40, bottom: 48, right: 40)).data
        case .document:
            // WebKit's print formatter lays a page out at 1.25x the paper width and shrinks it to fit, so content of a
            // fixed (paper) width ends up in the left part of the page. Laying it out at 1.25x fills the width.
            _ = await run(webView, "document.body.style.zoom = '1.25'")
            data = await printedPDF(from: webView, paper: portrait, insets: UIEdgeInsets(top: 36, left: 0, bottom: 36, right: 0)).data
        }
        guard let data else { return nil }
        return writeToScratchFile(data)
    }

    // MARK: - Detection

    private static func detectKind(_ webView: WKWebView, fileExtension: FileNameExtensions?) async -> Kind {
        let slideCount = await intValue(webView, "document.querySelectorAll('div.slide').length")
        if slideCount > 0 { return .slides }

        let contentType = await stringValue(webView, "document.contentType")
        if contentType == "application/pdf" { return .pdfEmbed }

        switch fileExtension {
        case .xlsx, .csv: return .spreadsheet
        case .txt, .rtf: return .plainText
        default: return .document
        }
    }

    // MARK: - Slides

    /// One PDF page per slide: each slide is captured on its own and placed, scaled to fit, on a landscape A4 page.
    private static func slidesPDF(from webView: WKWebView) async -> Data? {
        // Large decks load their slides progressively.
        for _ in 0 ..< 60 {
            if await intValue(webView, "document.querySelectorAll('div.loading-slide').length") == 0 { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        let rectsJSON = await stringValue(webView, """
        JSON.stringify([...document.querySelectorAll('div.slide')].map(s => {
          const r = s.getBoundingClientRect();
          return { x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height };
        }))
        """)
        guard let rectsJSON,
              let raw = try? JSONSerialization.jsonObject(with: Data(rectsJSON.utf8)) as? [[String: Double]],
              !raw.isEmpty else { return nil }

        // `createPDF` takes the rect in CSS px, the same unit `getBoundingClientRect` reports, however much WebKit
        // scales the 720 px wide slide layout to fit the view.
        var slides: [PDFPage] = []
        for item in raw {
            guard let x = item["x"], let y = item["y"], let w = item["w"], let h = item["h"], w > 1, h > 1 else { continue }
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: x, y: y, width: w, height: h)
            guard let slideData = try? await webView.pdf(configuration: configuration),
                  let page = PDFDocument(data: slideData)?.page(at: 0) else { continue }
            slides.append(page)
        }
        guard !slides.isEmpty else { return nil }

        let sheet = landscape
        let margin: CGFloat = 24
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: sheet))
        return renderer.pdfData { context in
            for slide in slides {
                context.beginPage()
                let source = slide.bounds(for: .mediaBox)
                let scale = min((sheet.width - 2 * margin) / source.width, (sheet.height - 2 * margin) / source.height)
                let width = source.width * scale
                let height = source.height * scale
                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: (sheet.width - width) / 2, y: (sheet.height - height) / 2 + height)
                cg.scaleBy(x: scale, y: -scale)
                slide.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
            }
        }
    }

    // MARK: - Spreadsheets

    /// A sheet is laid out at its natural width. It is scaled to fill the printable width of the page, and a wide one
    /// goes on landscape paper so the text stays readable. Grid lines and unbroken rows make it usable on paper.
    private static func spreadsheetPDF(from webView: WKWebView) async -> Data? {
        // The widest table, not the page: the page can be much wider than the sheet it holds.
        let naturalWidth = max(await intValue(webView, """
        Math.ceil(Math.max(0, ...[...document.querySelectorAll('table')].map(t => t.getBoundingClientRect().width)) || document.body.scrollWidth)
        """), 1)
        let paper = naturalWidth > 640 ? landscape : portrait
        let insets = UIEdgeInsets(top: 36, left: 24, bottom: 36, right: 24)
        let printableWidth = paper.width - insets.left - insets.right
        // Fill the page width, but never blow a small sheet up by more than 1.5x.
        let zoom = min(printableWidth / CGFloat(naturalWidth), 2.2)
        log("spreadsheet: natural width \(naturalWidth), paper \(paper), zoom \(zoom)")

        _ = await run(webView, """
        (function () {
          const s = document.createElement('style');
          s.textContent = 'table { margin-left: auto !important; margin-right: auto !important; } td, th { border: 1px solid #cfcfcf !important; } tr { page-break-inside: avoid; } thead { display: table-header-group; }';
          document.head.appendChild(s);
          document.body.style.zoom = '\(zoom)';
        })()
        """)
        return await printedPDF(from: webView, paper: paper, insets: insets).data
    }

    // MARK: - iWork (WebKit embeds a PDF)

    /// WebKit shows the converted document as one tall column of equally spaced pages. Printing that plugin draws
    /// every page at its natural size, which crops large slides, so instead the column is captured once as a vector
    /// page (`createPDF`) and cut into its pages. The page count comes from a print pass, and each page is fitted
    /// onto its own A4 sheet: landscape for slides, portrait for documents.
    private static func embeddedPDF(from webView: WKWebView) async -> Data? {
        // Capture the column first: the print pass below re-lays the plugin out at paper width.
        guard let columnData = try? await webView.pdf(configuration: WKPDFConfiguration()),
              let column = PDFDocument(data: columnData)?.page(at: 0) else { return nil }
        let pageCount = await printedPDF(from: webView, paper: portrait, insets: .zero).pageCount
        guard pageCount > 0 else { return nil }

        let columnSize = column.bounds(for: .mediaBox).size
        // The capture is at least as tall as the view, so a short document leaves blank space below its pages:
        // the plugin's element reports the height the pages really take.
        let embedHeight = CGFloat(Double((await stringValue(webView, "(document.querySelector('embed') || {style: {}}).style.height || ''") ?? "")
            .replacingOccurrences(of: "px", with: "")) ?? 0)
        let contentHeight = embedHeight > 0 ? min(embedHeight, columnSize.height) : columnSize.height
        let pitch = contentHeight / CGFloat(pageCount)
        let trim: CGFloat = 2 // the thin gap between pages
        let margin: CGFloat = 24

        // The pages as rects of the column, top down.
        var pages = (0 ..< pageCount).map { index in
            CGRect(x: trim, y: CGFloat(index) * pitch + trim, width: columnSize.width - 2 * trim, height: pitch - 2 * trim)
        }
        var sheet = pages[0].width > pages[0].height ? landscape : portrait

        // A spreadsheet (Numbers) comes as one single, extremely tall page. Fitted onto one sheet it would be a
        // thin unreadable strip, so it is cut into sheet-sized slices at fit-to-width scale instead.
        var isSliced = false
        if pageCount == 1, pages[0].height > pages[0].width * 1.6 {
            isSliced = true
            sheet = portrait
            let sliceHeight = pages[0].width * (sheet.height - 2 * margin) / (sheet.width - 2 * margin)
            let whole = pages[0]
            pages = stride(from: whole.minY, to: whole.maxY - 1, by: sliceHeight).map { top in
                CGRect(x: whole.minX, y: top, width: whole.width, height: min(sliceHeight, whole.maxY - top))
            }
        }
        log("embedded PDF: \(pageCount) pages, column \(columnSize), \(pages.count) sheets of \(sheet)")

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: sheet))
        return renderer.pdfData { context in
            for page in pages {
                context.beginPage()
                let scale = min((sheet.width - 2 * margin) / page.width, (sheet.height - 2 * margin) / page.height)
                let width = page.width * scale
                let height = page.height * scale
                // Whole pages (slides) are centered on the sheet; a short last slice of a sliced sheet stays at the top.
                let origin = CGPoint(x: (sheet.width - width) / 2, y: isSliced ? margin : (sheet.height - height) / 2)
                let cg = context.cgContext
                cg.saveGState()
                cg.clip(to: CGRect(origin: origin, size: CGSize(width: width, height: height)))
                // PDF space has its origin at the bottom left: move this page's bottom left corner to the sheet position.
                cg.translateBy(x: origin.x, y: origin.y + height)
                cg.scaleBy(x: scale, y: -scale)
                cg.translateBy(x: -page.minX, y: -(columnSize.height - page.maxY))
                column.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
            }
        }
    }

    // MARK: - Printing

    /// Prints the web view with WebKit's print formatter onto `paper`-sized pages, keeping `insets` free on every page.
    private static func printedPDF(
        from webView: WKWebView,
        paper: CGSize,
        insets: UIEdgeInsets
    ) async -> (data: Data?, pageCount: Int) {
        let originalBounds = webView.bounds
        defer { webView.bounds = originalBounds }

        let sheet = CGRect(origin: .zero, size: paper)
        var bounds = originalBounds
        bounds.size = paper
        webView.bounds = bounds

        let formatter = webView.viewPrintFormatter()
        formatter.perPageContentInsets = insets

        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: sheet), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: sheet), forKey: "printableRect")

        // Every page is drawn into its own small PDF, in one go without a pause. No global graphics context
        // stays open while the screen gets its turn, so other drawing on the main thread cannot disturb it.
        // The web view is hidden while this runs (see `FilePreviewView`), so its paper-size layout is not seen.
        renderer.prepare(forDrawingPages: NSMakeRange(0, renderer.numberOfPages))
        let pageCount = renderer.numberOfPages
        let merged = PDFDocument()
        for index in 0 ..< pageCount {
            let single = UIGraphicsPDFRenderer(bounds: sheet).pdfData { context in
                context.beginPage()
                renderer.drawPage(at: index, in: context.pdfContextBounds)
            }
            if let page = PDFDocument(data: single)?.page(at: 0) {
                merged.insert(page, at: merged.pageCount)
            }
            // A short pause after each page lets the screen react, so a long web page does not freeze the app
            // (Sentry AIR_PRINTER-P2). iOS needs this drawing on the main thread, and this function stays there
            // before and after every pause.
            await Task.yield()
            // The caller went away: stop quietly. The caller does not report this as a failure.
            if Task.isCancelled { return (nil, 0) }
        }

        guard merged.pageCount > 0 else { return (nil, 0) }
        return (merged.dataRepresentation(), merged.pageCount)
    }

    private static func writeToScratchFile(_ data: Data) -> PDFDocument? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("web-\(UUID().uuidString).pdf")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log("Failed to write generated PDF: \(error.localizedDescription)")
            return nil
        }
        return PDFDocument(url: url)
    }

    // MARK: - JavaScript helpers

    private static func run(_ webView: WKWebView, _ script: String) async -> Any? {
        try? await webView.evaluateJavaScript(script)
    }

    private static func intValue(_ webView: WKWebView, _ script: String) async -> Int {
        (await run(webView, script) as? NSNumber)?.intValue ?? 0
    }

    private static func stringValue(_ webView: WKWebView, _ script: String) async -> String? {
        await run(webView, script) as? String
    }
}
