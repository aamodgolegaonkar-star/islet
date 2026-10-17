import CoreGraphics
import Foundation
import ImageIO
import IsletCore

/// Samples artwork pixels for palette extraction. Safe to call off the main actor.
enum ArtworkPixels {
    static func palette(from data: Data) -> Palette {
        guard let pixels = samplePixels(data, side: 32) else { return .fallback }
        return PaletteExtractor.palette(from: pixels)
    }

    static func samplePixels(_ data: Data, side: Int) -> [RGB]? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side * 2,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).map { i in
            RGB(Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
        }
    }
}
