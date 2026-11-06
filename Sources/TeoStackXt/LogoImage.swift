#if canImport(SwiftUI)
import AppKit
import TeoStackCore

/// Converte l'immagine scelta dall'utente (PNG, JPEG, TIFF, PDF, HEIC…) in un JPEG a colori su fondo bianco, pronto per i report:
/// i PDF dei report incorporano solo JPEG. Le parti trasparenti diventano bianche (le pagine dei report sono bianche).
enum LogoImage {
    /// Lato massimo in pixel: più che sufficiente per un logo di 130 × 30 pt anche stampato.
    static let maxSide: CGFloat = 1200

    static func jpegData(from url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }
}
#endif
