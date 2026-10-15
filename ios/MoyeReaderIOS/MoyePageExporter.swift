import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct MoyeExportedPage: Sendable {
    let data: Data
    let fileExtension: String
}

enum MoyePageExporter {
    static func encode(image: UIImage, original: Data?, url: URL, restored: Bool) -> MoyeExportedPage? {
        let originalType = original.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceGetType($0) as String? } ?? ""
        if !restored, let original {
            let extensions = ["public.jpeg": "jpg", "public.png": "png", "org.webmproject.webp": "webp", "public.avif": "avif", "public.heic": "heic", "public.heif": "heif"]
            return MoyeExportedPage(data: original, fileExtension: extensions[originalType] ?? UTType(originalType)?.preferredFilenameExtension ?? "img")
        }
        let png = image.pngData()
        let compressedPhoto = ["org.webmproject.webp", "public.avif", "public.heic", "public.heif"].contains(originalType)
        let canUseJPEG = originalType == "public.jpeg" || (compressedPhoto && image.cgImage.map(isOpaque) == true)
        if canUseJPEG, let jpeg = image.jpegData(compressionQuality: 0.95), png.map({ jpeg.count < $0.count }) ?? true {
            return MoyeExportedPage(data: jpeg, fileExtension: "jpg")
        }
        return png.map { MoyeExportedPage(data: $0, fileExtension: "png") }
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        if [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return true }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for index in stride(from: 3, to: context.bytesPerRow * image.height, by: 4) { if bytes[index] != 255 { return false } }
        return true
    }
}
