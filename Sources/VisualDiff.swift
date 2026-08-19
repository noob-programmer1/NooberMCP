import Foundation
import AppKit

enum VisualDiff {
    struct DiffResult {
        let diffPercent: Double
        let passed: Bool
        let totalPixels: Int
        let changedPixels: Int
    }

    static func compare(current: Data, baseline: Data, threshold: Double = 5.0) -> DiffResult? {
        guard let currentImage = NSImage(data: current),
              let baselineImage = NSImage(data: baseline),
              let currentBitmap = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let baselineBitmap = baselineImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = min(currentBitmap.width, baselineBitmap.width)
        let height = min(currentBitmap.height, baselineBitmap.height)
        let totalPixels = width * height
        guard totalPixels > 0 else { return nil }

        // Get raw pixel data
        guard let currentPixels = pixelData(from: currentBitmap, width: width, height: height),
              let baselinePixels = pixelData(from: baselineBitmap, width: width, height: height) else {
            return nil
        }

        var changedPixels = 0
        let tolerance: UInt8 = 10 // Allow minor color differences
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let rDiff = abs(Int(currentPixels[i]) - Int(baselinePixels[i]))
            let gDiff = abs(Int(currentPixels[i+1]) - Int(baselinePixels[i+1]))
            let bDiff = abs(Int(currentPixels[i+2]) - Int(baselinePixels[i+2]))
            if rDiff > Int(tolerance) || gDiff > Int(tolerance) || bDiff > Int(tolerance) {
                changedPixels += 1
            }
        }

        let diffPercent = Double(changedPixels) / Double(totalPixels) * 100.0
        return DiffResult(diffPercent: diffPercent, passed: diffPercent <= threshold, totalPixels: totalPixels, changedPixels: changedPixels)
    }

    private static func pixelData(from cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    // Baseline management
    static let baselinesDir: String = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
        return home + "/.noobqa/baselines"
    }()

    static func saveBaseline(_ data: Data, bundleId: String, screen: String) {
        let dir = baselinesDir + "/\(bundleId)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(screen.replacingOccurrences(of: "/", with: "_")).png"
        try? data.write(to: URL(fileURLWithPath: path))
    }

    static func loadBaseline(bundleId: String, screen: String) -> Data? {
        let path = baselinesDir + "/\(bundleId)/\(screen.replacingOccurrences(of: "/", with: "_")).png"
        return FileManager.default.contents(atPath: path)
    }
}
