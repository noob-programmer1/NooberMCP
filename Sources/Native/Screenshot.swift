import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Screenshots sized for LLMs. A raw 3x PNG of an iPhone is ~1–3 MB of base64; at point
/// resolution as JPEG it is ~60–150 KB with the same tap-coordinate space as every other tool.
enum Screenshot {
    struct Image {
        let data: Data
        let mimeType: String
        let width: Int
        let height: Int
        var base64: String { data.base64EncodedString() }
    }

    enum Quality: String {
        case fast      // point resolution, JPEG q0.6 — default
        case full      // native pixels, PNG
    }

    static func simulator(udid: String, pointSize: CGSize?, quality: Quality) -> (Image?, String) {
        // Xcode 27's simctl writes a file literally named "-" instead of stdout, so use a temp file.
        let path = NSTemporaryDirectory() + "noober-sim-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let r = Exec.xcrun(["simctl", "io", udid, "screenshot", "--type=png", path], timeout: 20) else {
            return (nil, "simctl screenshot timed out")
        }
        guard r.ok, let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return (nil, "screenshot failed: \(r.message)")
        }
        return encode(data, pointSize: pointSize, quality: quality)
    }

    /// Physical device (Xcode 27 `devicectl device capture screenshot`).
    static func device(id: String, quality: Quality) -> (Image?, String) {
        let path = NSTemporaryDirectory() + "noober-dev-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let r = Exec.xcrun(["devicectl", "device", "capture", "screenshot", "--device", id, "--destination", path, "-q"], timeout: 30) else {
            return (nil, "devicectl screenshot timed out")
        }
        guard r.ok, let data = FileManager.default.contents(atPath: path) else {
            return (nil, "devicectl screenshot failed: \(r.message) (needs Xcode 27+ and an unlocked, paired device)")
        }
        return encode(data, pointSize: nil, quality: quality, assumeScale: 3)
    }

    static func encode(_ png: Data, pointSize: CGSize?, quality: Quality, assumeScale: CGFloat? = nil) -> (Image?, String) {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return (nil, "could not decode screenshot")
        }
        if quality == .full {
            return (Image(data: png, mimeType: "image/png", width: cg.width, height: cg.height),
                    "\(cg.width)x\(cg.height)px PNG")
        }
        var target = CGSize(width: cg.width, height: cg.height)
        if let p = pointSize, p.width > 0 {
            target = p
        } else if let s = assumeScale {
            target = CGSize(width: CGFloat(cg.width) / s, height: CGFloat(cg.height) / s)
        }
        let w = Int(target.width.rounded()), h = Int(target.height.rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return (nil, "could not scale screenshot")
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return (nil, "could not scale screenshot") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return (nil, "could not encode screenshot")
        }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return (Image(data: out as Data, mimeType: "image/jpeg", width: w, height: h),
                "\(w)x\(h) (points — same space as tap coordinates), \(out.length / 1024) KB")
    }
}
