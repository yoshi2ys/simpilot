import Foundation
import ImageIO
import UniformTypeIdentifiers
#if !os(visionOS)
import UIKit
#endif
import XCTest

final class ScreenshotHandler {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    /// Validity of the `scale` query param. `native` keeps native pixels,
    /// `factor` is a positive downscale target, `invalid` is anything else
    /// (non-numeric, zero, or negative) — rejected rather than coerced (A23).
    enum ScaleSpec: Equatable {
        case native
        case factor(Double)
        case invalid
    }

    static func parseScale(_ scaleParam: String) -> ScaleSpec {
        if scaleParam == "native" { return .native }
        if let value = Double(scaleParam), value > 0 { return .factor(value) }
        return .invalid
    }

    /// Map an action body's `screenshot_scale` (a JSON String, Double, or
    /// absent) to a `ScaleSpec`. Absent → 1.0 (the historical default); a bogus
    /// factor → `.invalid` rather than a silent 1.0 (A23). Shared with
    /// `ActionHandler`'s inline screenshot so both agree.
    static func scaleSpec(from raw: Any?) -> ScaleSpec {
        if let str = raw as? String { return parseScale(str) }
        if let value = raw as? Double { return value > 0 ? .factor(value) : .invalid }
        return .factor(1.0)
    }

    func handle(_ request: HTTPRequest) -> Data {
        let filePath = request.queryParams["file"]
        let scaleParam = request.queryParams["scale"] ?? "1"
        let elementQuery = request.queryParams["element"]
        let format = request.queryParams["format"] ?? "png"
        guard format == "png" || format == "jpeg" else {
            return HTTPResponseBuilder.error(
                "Invalid format '\(format)': must be 'png' or 'jpeg'",
                code: "invalid_request"
            )
        }
        let quality = Int(request.queryParams["quality"] ?? "80") ?? 80
        if format == "jpeg" && !(0...100).contains(quality) {
            return HTTPResponseBuilder.error(
                "Invalid quality \(quality): must be 0-100",
                code: "invalid_request"
            )
        }
        // Validate scale up front (fail fast, before the screenshot). `nil` ==
        // native pixels; a non-numeric / non-positive factor is rejected instead
        // of silently coercing to 1.0 or returning native while reporting the
        // bogus factor — see A23.
        let scaleValue: Double?
        switch Self.parseScale(scaleParam) {
        case .native:
            scaleValue = nil
        case .factor(let s):
            scaleValue = s
        case .invalid:
            return HTTPResponseBuilder.error(
                "Invalid scale '\(scaleParam)': must be a positive number or 'native'",
                code: "invalid_request"
            )
        }

        let fullPng: Data
        if let elementQuery = elementQuery {
            let app = appManager.currentApp()
            let element: XCUIElement
            do {
                element = try ElementResolver.resolve(query: elementQuery, in: app)
            } catch {
                return HTTPResponseBuilder.error(
                    "Element not found: \(elementQuery)",
                    code: "element_not_found"
                )
            }
            var pngResult: Data?
            let failure = catchObjCException {
                pngResult = element.screenshot().pngRepresentation
            }
            if let failure {
                return HTTPResponseBuilder.error(
                    "Screenshot failed for element '\(elementQuery)': \(failure)",
                    code: "screenshot_failed"
                )
            }
            fullPng = pngResult!
        } else {
            fullPng = XCUIScreen.main.screenshot().pngRepresentation
        }
        let pngData: Data
        let scaleOut: Any
        if let scaleValue {
            pngData = ScreenshotScaler.scaled(pngData: fullPng, scale: scaleValue) ?? fullPng
            scaleOut = scaleValue
        } else {
            pngData = fullPng
            scaleOut = "native"
        }

        let outputData: Data
        let outputFormat: String
        if format == "jpeg" {
            outputData = ScreenshotConverter.toJPEG(pngData: pngData, quality: quality) ?? pngData
            outputFormat = outputData == pngData ? "png" : "jpeg"
        } else {
            outputData = pngData
            outputFormat = "png"
        }

        if let filePath = filePath, !filePath.isEmpty {
            do {
                try outputData.write(to: URL(fileURLWithPath: filePath))
                return HTTPResponseBuilder.json([
                    "file": filePath, "size": outputData.count,
                    "scale": scaleOut, "format": outputFormat
                ])
            } catch {
                return HTTPResponseBuilder.error(
                    "Failed to write screenshot: \(error.localizedDescription)",
                    code: "write_failed",
                    status: 500
                )
            }
        } else {
            let base64 = outputData.base64EncodedString()
            return HTTPResponseBuilder.json([
                "base64": base64, "format": outputFormat, "size": outputData.count, "scale": scaleOut
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

/// Converts PNG data to JPEG using ImageIO. Returns nil on failure.
enum ScreenshotConverter {
    static func toJPEG(pngData: Data, quality: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
