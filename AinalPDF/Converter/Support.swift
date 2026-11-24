import Foundation
import CoreGraphics

/// Page size the user picks before converting. Sizes are in PDF points.
enum PageOption: String, CaseIterable, Identifiable {
    case a4 = "A4"
    case letter = "Letter"
    case original = "Original size"

    var id: String { rawValue }

    /// Portrait size. `original` has none: pictures then keep their own size.
    var portrait: CGSize {
        switch self {
        case .letter: return CGSize(width: 612, height: 792)
        case .a4, .original: return CGSize(width: 595, height: 842)
        }
    }
    var landscape: CGSize { CGSize(width: portrait.height, height: portrait.width) }
}

func log(_ message: String) {
    #if DEBUG
    print("[AinalPDF] \(message)")
    #endif
}
