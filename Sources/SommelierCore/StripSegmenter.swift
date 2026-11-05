import CoreGraphics
import Foundation

/// Pure segmentation of a captured menu bar strip into item blobs (gdu.104, measurement only).
public enum StripSegmenter {
    /// One bool per pixel column: occupied when any pixel differs from the background by more than `threshold` in max channel distance.
    /// `bgra` is a BGRA8 buffer. `background` nil = the most frequent colour of the first column block (first 8 columns).
    public static func occupancy(width: Int, height: Int, bgra: UnsafeBufferPointer<UInt8>, bytesPerRow: Int,
                                 background: (r: UInt8, g: UInt8, b: UInt8)?, threshold: Int = 40) -> [Bool] {
        guard width > 0, height > 0, bytesPerRow >= width * 4, bgra.count >= (height - 1) * bytesPerRow + width * 4 else { return [] }
        let bg: (r: UInt8, g: UInt8, b: UInt8)
        if let background { bg = background } else {
            var counts: [UInt32: Int] = [:]
            for y in 0..<height {
                for x in 0..<min(8, width) {
                    let o = y * bytesPerRow + x * 4
                    counts[UInt32(bgra[o + 2]) << 16 | UInt32(bgra[o + 1]) << 8 | UInt32(bgra[o]), default: 0] += 1
                }
            }
            // Deterministic tie-break: smaller packed value.
            let best = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 0
            bg = (UInt8(best >> 16 & 0xFF), UInt8(best >> 8 & 0xFF), UInt8(best & 0xFF))
        }
        var out = [Bool](repeating: false, count: width)
        for x in 0..<width {
            for y in 0..<height {
                let o = y * bytesPerRow + x * 4
                let d = max(abs(Int(bgra[o]) - Int(bg.b)), abs(Int(bgra[o + 1]) - Int(bg.g)), abs(Int(bgra[o + 2]) - Int(bg.r)))
                if d > threshold { out[x] = true; break }
            }
        }
        return out
    }

    /// Merge occupied runs separated by gaps smaller than `minGap`, drop runs narrower than `minWidth` (pixels), and convert to
    /// screen points (divide by `scale`, add `originX`). y/height come from `stripY`/`stripHeight` (the strip's point frame).
    public static func segments(occupied: [Bool], minGap: Int = 4, minWidth: Int = 6, scale: CGFloat, originX: CGFloat,
                                stripY: CGFloat = 0, stripHeight: CGFloat = 0) -> [CGRect] {
        guard scale > 0 else { return [] }
        var runs: [(Int, Int)] = []   // [start, end) in pixels
        var x = 0
        while x < occupied.count {
            if occupied[x] {
                let s = x
                while x < occupied.count, occupied[x] { x += 1 }
                runs.append((s, x))
            } else { x += 1 }
        }
        var merged: [(Int, Int)] = []
        for r in runs {
            if let l = merged.last, r.0 - l.1 < minGap { merged[merged.count - 1].1 = r.1 } else { merged.append(r) }
        }
        return merged.filter { $0.1 - $0.0 >= minWidth }.map {
            CGRect(x: originX + CGFloat($0.0) / scale, y: stripY, width: CGFloat($0.1 - $0.0) / scale, height: stripHeight)
        }
    }
}

/// One pixelwatch sample: the scanner's on-bar items versus the blobs drawn.
public struct PixelSample: Codable, Sendable, Equatable {
    public var t: Double
    public var blobs: Int
    public var axOnBar: Int
    public var matched: Int
    public var itemsWithoutBlob: [String]
    public var blobsWithoutItem: Int
    public var staleWithBlob: [String]
    public var moving: Bool

    public init(t: Double = 0, blobs: Int, axOnBar: Int, matched: Int, itemsWithoutBlob: [String], blobsWithoutItem: Int,
                staleWithBlob: [String], moving: Bool = false) {
        self.t = t; self.blobs = blobs; self.axOnBar = axOnBar; self.matched = matched
        self.itemsWithoutBlob = itemsWithoutBlob; self.blobsWithoutItem = blobsWithoutItem
        self.staleWithBlob = staleWithBlob; self.moving = moving
    }

    public var disagrees: Bool { !itemsWithoutBlob.isEmpty || blobsWithoutItem > 0 }

    /// An item matches a blob when their x-overlap >= `minOverlap` x the narrower width; each blob matches at most one item
    /// (items are taken in the order given; the best-overlapping free blob wins). `t` and `moving` are set by the caller.
    public static func match(items: [(key: String, frame: CGRect, stale: Bool)], blobs: [CGRect], minOverlap: CGFloat = 0.5) -> PixelSample {
        var used = Set<Int>()
        var matched = 0
        var without: [String] = []
        var staleWith: [String] = []
        for it in items {
            var best: (Int, CGFloat)? = nil
            for (i, b) in blobs.enumerated() where !used.contains(i) {
                let ov = min(it.frame.maxX, b.maxX) - max(it.frame.minX, b.minX)
                let need = minOverlap * min(it.frame.width, b.width)
                if ov > 0, ov >= need, ov > (best?.1 ?? 0) { best = (i, ov) }
            }
            if let (i, _) = best {
                used.insert(i); matched += 1
                if it.stale { staleWith.append(it.key) }
            } else { without.append(it.key) }
        }
        return PixelSample(blobs: blobs.count, axOnBar: items.count, matched: matched, itemsWithoutBlob: without,
                           blobsWithoutItem: blobs.count - used.count, staleWithBlob: staleWith)
    }
}

/// End-of-run statistics over the samples.
public struct PixelWatchSummary: Sendable, CustomStringConvertible {
    public struct Run: Sendable, Equatable { public var samples: Int; public var seconds: Double }
    public let sampleCount: Int
    public let disagreementFraction: Double
    public let longestRunPerKey: [String: Run]
    public let topOffenders: [(key: String, samples: Int)]
    public let unnoticedMoving: Int
    public let movingFrames: Int

    public init(samples: [PixelSample], scanTimes: [Double] = []) {
        sampleCount = samples.count
        disagreementFraction = samples.isEmpty ? 0 : Double(samples.filter(\.disagrees).count) / Double(samples.count)
        var counts: [String: Int] = [:]
        var longest: [String: Run] = [:]
        var current: [String: (start: Double, n: Int, last: Double)] = [:]
        for s in samples {
            let now = Set(s.itemsWithoutBlob)
            for k in now {
                counts[k, default: 0] += 1
                var c = current[k] ?? (s.t, 0, s.t)
                c.n += 1; c.last = s.t
                current[k] = c
                let run = Run(samples: c.n, seconds: c.last - c.start)
                if run.samples > (longest[k]?.samples ?? 0) { longest[k] = run }
            }
            for k in current.keys where !now.contains(k) { current[k] = nil }
        }
        longestRunPerKey = longest
        topOffenders = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(10).map { ($0.key, $0.value) }
        let moving = samples.filter(\.moving)
        movingFrames = moving.count
        unnoticedMoving = moving.filter { m in !scanTimes.contains { $0 >= m.t && $0 <= m.t + 1.0 } }.count
    }

    public var description: String {
        var l = ["pixelwatch summary: \(sampleCount) samples",
                 String(format: "samples with any disagreement: %.1f%%", disagreementFraction * 100),
                 "moving frames: \(movingFrames), not followed by a scanner change within 1 s: \(unnoticedMoving)"]
        l.append("top offending keys (items with no blob):")
        if topOffenders.isEmpty { l.append("  none") }
        for o in topOffenders {
            let r = longestRunPerKey[o.key]
            l.append(String(format: "  %@: %d samples, longest run %d samples / %.1f s", o.key, o.samples, r?.samples ?? 0, r?.seconds ?? 0))
        }
        return l.joined(separator: "\n")
    }
}
