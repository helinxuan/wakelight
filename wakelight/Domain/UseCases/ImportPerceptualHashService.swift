import Foundation
import UIKit

struct PerceptualHash: Sendable, Equatable {
    let bits: UInt64

    func hammingDistance(to other: PerceptualHash) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }
}

actor ImportPerceptualHashService {
    static let shared = ImportPerceptualHashService()

    private var cache: [String: PerceptualHash] = [:]

    private init() {}

    func hash(localIdentifier: String, image: UIImage) -> PerceptualHash? {
        if let cached = cache[localIdentifier] { return cached }
        guard let small = downsampleTo8x8(image: image) else { return nil }

        let pixels = small.pixels
        let avg = pixels.reduce(0, +) / Double(pixels.count)

        var bits: UInt64 = 0
        for (idx, p) in pixels.enumerated() {
            if p >= avg {
                bits |= (1 << UInt64(idx))
            }
        }

        let ph = PerceptualHash(bits: bits)
        cache[localIdentifier] = ph
        return ph
    }

    private func downsampleTo8x8(image: UIImage) -> (pixels: [Double], width: Int, height: Int)? {
        let size = CGSize(width: 8, height: 8)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: size))
        guard let cg = UIGraphicsGetImageFromCurrentImageContext()?.cgImage,
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let bpp = cg.bitsPerPixel / 8
        let row = cg.bytesPerRow
        var out: [Double] = []
        out.reserveCapacity(64)

        for y in 0..<8 {
            for x in 0..<8 {
                let idx = y * row + x * bpp
                let r = Double(ptr[idx])
                let g = Double(ptr[idx + 1])
                let b = Double(ptr[idx + 2])
                out.append(0.299 * r + 0.587 * g + 0.114 * b)
            }
        }

        return (out, 8, 8)
    }
}
