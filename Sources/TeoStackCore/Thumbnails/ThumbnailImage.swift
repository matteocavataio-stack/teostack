import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Conversione di un'immagine (TIFF a 16 bit di art-cmd) in JPEG ridotto per l'anteprima.
enum ThumbnailImage {
    static func makeJPEG(from source: URL, to output: URL, maxWidth: Int, ffmpeg: FFmpegRunner?) throws {
        #if canImport(ImageIO)
        try makeJPEGWithImageIO(from: source, to: output, maxWidth: maxWidth)
        #else
        guard let ffmpeg else { throw MetadataError.toolMissing("Per convertire l'immagine serve ffmpeg.") }
        try ffmpeg.convertImage(from: source.path, to: output.path, maxWidth: maxWidth)
        #endif
    }

    #if canImport(ImageIO)
    private static func makeJPEGWithImageIO(from source: URL, to output: URL, maxWidth: Int) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw MetadataError.invalidOutput(tr("L'immagine prodotta da art-cmd non è leggibile."))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxWidth,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw MetadataError.invalidOutput(tr("Impossibile ridurre l'immagine dell'anteprima."))
        }
        try? FileManager.default.removeItem(at: output)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw MetadataError.toolFailed(tr("Impossibile creare il file JPEG dell'anteprima."))
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw MetadataError.toolFailed(tr("Impossibile scrivere il file JPEG dell'anteprima."))
        }
    }
    #endif
}
