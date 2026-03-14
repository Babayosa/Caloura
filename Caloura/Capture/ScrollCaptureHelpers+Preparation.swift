import CoreGraphics
import Foundation

extension ScrollCaptureHelpers {
    static func renderToBitmap(_ image: CGImage) -> BitmapData? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = ctx.makeImage(),
              let data = rendered.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else {
            return nil
        }

        return BitmapData(
            pointer: pointer,
            data: data,
            bytesPerRow: bytesPerRow,
            width: width,
            height: height
        )
    }

    static func prepareFrame(_ image: CGImage) -> PreparedFrame? {
        guard let bitmap = renderToBitmap(image) else { return nil }
        let grayscale = makeGrayscale(bitmap)
        let rowHashes = makeRowHashes(
            grayscale: grayscale,
            width: bitmap.width,
            height: bitmap.height
        )
        let coarseHash = makeCoarseHash(rowHashes)
        return PreparedFrame(
            image: image,
            bitmap: bitmap,
            grayscale: grayscale,
            rowHashes: rowHashes,
            coarseHash: coarseHash
        )
    }

    static func pixelMatchRatio(
        _ bmpA: BitmapData,
        _ bmpB: BitmapData
    ) -> Double {
        guard bmpA.width == bmpB.width && bmpA.height == bmpB.height else {
            return 0
        }

        var sampledPixels = 0
        var matchingPixels = 0
        for row in stride(from: 0, to: bmpA.height, by: 3) {
            let offsetA = row * bmpA.bytesPerRow
            let offsetB = row * bmpB.bytesPerRow
            for column in stride(from: 0, to: bmpA.width, by: 4) {
                let pixelOffset = column * 4
                let red = abs(
                    Int(bmpA.pointer[offsetA + pixelOffset]) -
                    Int(bmpB.pointer[offsetB + pixelOffset])
                )
                let green = abs(
                    Int(bmpA.pointer[offsetA + pixelOffset + 1]) -
                    Int(bmpB.pointer[offsetB + pixelOffset + 1])
                )
                let blue = abs(
                    Int(bmpA.pointer[offsetA + pixelOffset + 2]) -
                    Int(bmpB.pointer[offsetB + pixelOffset + 2])
                )
                if red + green + blue < 10 {
                    matchingPixels += 1
                }
                sampledPixels += 1
            }
        }

        return sampledPixels > 0
            ? Double(matchingPixels) / Double(sampledPixels)
            : 0
    }

    static func hashSimilarity(
        _ lhs: PreparedFrame,
        _ rhs: PreparedFrame
    ) -> Double {
        guard lhs.rowHashes.count == rhs.rowHashes.count else { return 0 }
        let hashStride = max(1, lhs.rowHashes.count / 24)
        var matches = 0
        var samples = 0
        for index in Swift.stride(from: 0, to: lhs.rowHashes.count, by: hashStride) {
            if lhs.rowHashes[index] == rhs.rowHashes[index] {
                matches += 1
            }
            samples += 1
        }
        return samples > 0 ? Double(matches) / Double(samples) : 0
    }

    private static func makeGrayscale(_ bitmap: BitmapData) -> [UInt8] {
        var grayscale = [UInt8](repeating: 0, count: bitmap.width * bitmap.height)
        let width = bitmap.width
        let height = bitmap.height

        for row in 0..<height {
            let sourceRow = row * bitmap.bytesPerRow
            let destinationRow = row * width
            for column in 0..<width {
                let sourceOffset = sourceRow + column * 4
                let red = Int(bitmap.pointer[sourceOffset])
                let green = Int(bitmap.pointer[sourceOffset + 1])
                let blue = Int(bitmap.pointer[sourceOffset + 2])
                grayscale[destinationRow + column] = UInt8(
                    (77 * red + 150 * green + 29 * blue) >> 8
                )
            }
        }

        return grayscale
    }

    private static func makeRowHashes(
        grayscale: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt64] {
        let sampleStride = max(1, width / 64)
        return (0..<height).map { row in
            var hash: UInt64 = 14_695_981_039_346_656_037
            let offset = row * width
            for column in stride(from: 0, to: width, by: sampleStride) {
                hash ^= UInt64(grayscale[offset + column])
                hash &*= 1_099_511_628_211
            }
            return hash
        }
    }

    private static func makeCoarseHash(_ rowHashes: [UInt64]) -> UInt64 {
        let hashStride = max(1, rowHashes.count / 32)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for index in Swift.stride(from: 0, to: rowHashes.count, by: hashStride) {
            hash ^= rowHashes[index]
            hash &*= 0x1000_0000_01b3
        }
        return hash
    }
}
