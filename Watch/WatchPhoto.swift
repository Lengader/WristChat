import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WatchPhoto {
    static func compressedJPEG(_ original: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil) else {
            throw WristError.unreadablePhoto
        }
        for size in [1024, 768, 512] {
            let thumbnailOptions: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: size,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality as String: 0.72] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= 350_000 { return output as Data }
        }
        throw WristError.unreadablePhoto
    }
}
