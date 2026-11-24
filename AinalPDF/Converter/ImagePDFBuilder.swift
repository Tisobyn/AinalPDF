import PDFKit
import UIKit

/// Puts pictures on A4 pages. One picture = one page. Wide pictures get a landscape page.
enum ImagePDFBuilder {

    static func makePDF(from images: [UIImage]) -> PDFDocument? {
        guard !images.isEmpty else { return nil }
        let margin: CGFloat = 24
        let merged = PDFDocument()

        for image in images {
            let isWide = image.size.width > image.size.height
            let sheet = isWide
                ? CGSize(width: PageSize.a4Height, height: PageSize.a4Width)
                : CGSize(width: PageSize.a4Width, height: PageSize.a4Height)
            let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: sheet)).pdfData { context in
                context.beginPage()
                let area = CGSize(width: sheet.width - 2 * margin, height: sheet.height - 2 * margin)
                let scale = min(area.width / image.size.width, area.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let origin = CGPoint(x: (sheet.width - size.width) / 2, y: (sheet.height - size.height) / 2)
                image.draw(in: CGRect(origin: origin, size: size))
            }
            if let page = PDFDocument(data: data)?.page(at: 0) {
                merged.insert(page, at: merged.pageCount)
            }
        }
        return merged.pageCount > 0 ? merged : nil
    }
}
