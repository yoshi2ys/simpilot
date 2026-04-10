import Foundation
import ImageIO
import UniformTypeIdentifiers
#if !os(visionOS)
import UIKit
#endif
import XCTest

final class ScreenshotHandler {
    func handle(_ request: HTTPRequest) -> Data {
        let filePath = request.queryParams["file"]
        let scaleParam = request.queryParams["scale"] ?? "1"

        let screenshot = XCUIScreen.main.screenshot()
        let fullPng = screenshot.pngRepresentation
        let pngData: Data
        let scaleOut: Any
        if scaleParam == "native" {
            pngData = fullPng
            scaleOut = "native"
        } else {
            let scale = Double(scaleParam) ?? 1.0
            pngData = ScreenshotScaler.scaled(pngData: fullPng, scale: scale) ?? fullPng
            scaleOut = scale
        }

        if let filePath = filePath, !filePath.isEmpty {
            do {
                try pngData.write(to: URL(fileURLWithPath: filePath))
                return HTTPResponseBuilder.json(["file": filePath, "size": pngData.count, "scale": scaleOut])
            } catch {
                return HTTPResponseBuilder.error(
                    "Failed to write screenshot: \(error.localizedDescription)",
                    code: "write_failed",
                    status: 500
                )
            }
        } else {
            let base64 = pngData.base64EncodedString()
            return HTTPResponseBuilder.json([
                "base64": base64, "format": "png", "size": pngData.count, "scale": scaleOut
            ])
        }
    }
}

/// Downsamples a PNG so the long edge shrinks from native pixels to
/// `scale * points`. Native screenshots are @3x, so `scale=1` on an iPhone
/// yields ~1/3 long edge and ~1/9 bytes — the point of this is to slash
/// base64 tokens sent to LLMs. Returns `nil` if decoding fails (callers
/// fall back to the original data).
enum ScreenshotScaler {
    static func scaled(pngData: Data, scale: Double) -> Data? {
        guard scale > 0,
              let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pixelW = props[kCGImagePropertyPixelWidth] as? Double,
              let pixelH = props[kCGImagePropertyPixelHeight] as? Double else {
            return nil
        }

        let nativeLong = max(pixelW, pixelH)
        #if os(visionOS)
        // visionOS has no UIScreen. Vision Pro renders at ~2x effective density.
        let nativeScale: Double = 2.0
        #else
        let nativeScale = Double(UIScreen.main.scale)
        #endif
        let targetLong = (nativeLong / nativeScale) * scale
        guard targetLong < nativeLong else { return pngData }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: targetLong,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
