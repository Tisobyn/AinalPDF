import Foundation
import CoreGraphics

/// A4 size in PDF points.
enum PageSize {
    static let a4Width: CGFloat = 595
    static let a4Height: CGFloat = 842
}

func log(_ message: String) {
    #if DEBUG
    print("[AinalPDF] \(message)")
    #endif
}
