import CoreGraphics
import Foundation

enum ScrollCaptureHelpers {
    static let bandCount = 8

    struct BitmapData: @unchecked Sendable {
        let pointer: UnsafePointer<UInt8>
        let data: CFData
        let bytesPerRow: Int
        let width: Int
        let height: Int

        var byteCount: Int {
            bytesPerRow * height
        }
    }

    struct PreparedFrame: @unchecked Sendable {
        let image: CGImage
        let bitmap: BitmapData
        let grayscale: [UInt8]
        let rowHashes: [UInt64]
        let coarseHash: UInt64

        var width: Int { bitmap.width }
        var height: Int { bitmap.height }
    }

    struct BandComparisonOptions {
        let displacement: Int
        let stickyHeaderHeight: Int
        let bottomExclusion: Int
        let excludedBands: IndexSet
    }

    struct DisplacementRefinement {
        let displacement: Int
        let error: Double
        let runnerUpError: Double
    }
}
