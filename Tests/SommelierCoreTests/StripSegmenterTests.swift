import Testing
import CoreGraphics
@testable import SommelierCore

@Suite struct StripSegmenterTests {
    func occ(_ runs: [(Int, Int)], width: Int) -> [Bool] {
        var o = [Bool](repeating: false, count: width)
        for (s, e) in runs { for x in s..<e { o[x] = true } }
        return o
    }

    @Test func gapsOneToThreeMerge() {
        for g in 1...3 {
            let r = StripSegmenter.segments(occupied: occ([(10, 20), (20 + g, 30)], width: 60), scale: 1, originX: 0, stripHeight: 24)
            #expect(r.count == 1)
            #expect(r[0].minX == 10 && r[0].maxX == 30)
        }
    }
    @Test func gapsFourPlusSplit() {
        for g in 4...6 {
            let r = StripSegmenter.segments(occupied: occ([(10, 20), (20 + g, 40)], width: 60), scale: 1, originX: 0)
            #expect(r.count == 2)
        }
    }
    @Test func narrowNoiseDropped() {
        let r = StripSegmenter.segments(occupied: occ([(5, 8), (20, 40)], width: 60), scale: 1, originX: 0)
        #expect(r.count == 1 && r[0].minX == 20)
    }
    @Test func scaleTwoAndOrigin() {
        let r = StripSegmenter.segments(occupied: occ([(20, 60)], width: 100), scale: 2, originX: 100, stripY: 0, stripHeight: 24)
        #expect(r == [CGRect(x: 110, y: 0, width: 20, height: 24)])
    }
    @Test func allBackground() {
        #expect(StripSegmenter.segments(occupied: [Bool](repeating: false, count: 50), scale: 2, originX: 0).isEmpty)
        #expect(StripSegmenter.segments(occupied: [], scale: 2, originX: 0).isEmpty)
    }
    @Test func occupancyOnSyntheticBuffer() {
        let w = 12, h = 3
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { buf[i * 4] = 30; buf[i * 4 + 1] = 30; buf[i * 4 + 2] = 30; buf[i * 4 + 3] = 255 }
        // bright pixel (white) in column 5, row 1; faint (+10) in column 8
        let o5 = (1 * w + 5) * 4; buf[o5] = 255; buf[o5 + 1] = 255; buf[o5 + 2] = 255
        let o8 = (2 * w + 8) * 4; buf[o8] = 40
        let res = buf.withUnsafeBufferPointer { StripSegmenter.occupancy(width: w, height: h, bgra: $0, bytesPerRow: w * 4, background: nil) }
        #expect(res.count == w)
        #expect(res.enumerated().filter { $0.element }.map(\.offset) == [5])
        let res2 = buf.withUnsafeBufferPointer { StripSegmenter.occupancy(width: w, height: h, bgra: $0, bytesPerRow: w * 4, background: (30, 30, 30), threshold: 5) }
        #expect(res2.enumerated().filter { $0.element }.map(\.offset) == [5, 8])
    }
}

@Suite struct PixelMatchTests {
    func f(_ x: CGFloat, _ w: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: w, height: 24) }
    @Test func exact() {
        let s = PixelSample.match(items: [("a", f(0, 20), false), ("b", f(30, 20), false)], blobs: [f(0, 20), f(30, 20)])
        #expect(s.matched == 2 && s.itemsWithoutBlob.isEmpty && s.blobsWithoutItem == 0 && !s.disagrees)
    }
    @Test func partialOverlap() {
        // overlap 8 of min width 20 = 0.4 -> no; overlap 12 = 0.6 -> yes
        #expect(PixelSample.match(items: [("a", f(0, 20), false)], blobs: [f(12, 20)]).matched == 0)
        #expect(PixelSample.match(items: [("a", f(0, 20), false)], blobs: [f(8, 20)]).matched == 1)
    }
    @Test func itemWithoutBlob() {
        let s = PixelSample.match(items: [("a", f(0, 20), false), ("b", f(100, 20), false)], blobs: [f(0, 20)])
        #expect(s.itemsWithoutBlob == ["b"] && s.blobsWithoutItem == 0 && s.disagrees)
    }
    @Test func blobWithoutItem() {
        let s = PixelSample.match(items: [("a", f(0, 20), false)], blobs: [f(0, 20), f(50, 10)])
        #expect(s.blobsWithoutItem == 1 && s.itemsWithoutBlob.isEmpty && s.blobs == 2 && s.axOnBar == 1)
    }
    @Test func staleWithBlob() {
        let s = PixelSample.match(items: [("a", f(0, 20), true), ("b", f(100, 20), true)], blobs: [f(0, 20)])
        #expect(s.staleWithBlob == ["a"] && s.itemsWithoutBlob == ["b"])
    }
    @Test func oneBlobMatchesOneItem() {
        let s = PixelSample.match(items: [("a", f(0, 20), false), ("b", f(2, 20), false)], blobs: [f(0, 22)])
        #expect(s.matched == 1 && s.itemsWithoutBlob.count == 1)
    }
}

@Suite struct PixelWatchSummaryTests {
    func s(_ t: Double, without: [String] = [], extra: Int = 0, moving: Bool = false) -> PixelSample {
        PixelSample(t: t, blobs: 3, axOnBar: 3, matched: 3 - without.count, itemsWithoutBlob: without, blobsWithoutItem: extra, staleWithBlob: [], moving: moving)
    }
    @Test func statistics() {
        let samples = [s(0), s(0.5, without: ["a"]), s(1, without: ["a", "b"]), s(1.5, without: ["a"]), s(2), s(2.5, without: ["b"]), s(3, extra: 1), s(3.5)]
        let sum = PixelWatchSummary(samples: samples, scanTimes: [])
        #expect(sum.sampleCount == 8)
        #expect(sum.disagreementFraction == 5.0 / 8.0)
        #expect(sum.longestRunPerKey["a"] == .init(samples: 3, seconds: 1.0))
        #expect(sum.longestRunPerKey["b"] == .init(samples: 1, seconds: 0))
        #expect(sum.topOffenders.map(\.key) == ["a", "b"] && sum.topOffenders[0].samples == 3 && sum.topOffenders[1].samples == 2)
        #expect(sum.description.contains("62.5%"))
    }
    @Test func topTen() {
        let samples = (0..<12).map { s(Double($0), without: ["k\($0)"]) }
        #expect(PixelWatchSummary(samples: samples).topOffenders.count == 10)
    }
    @Test func unnoticedMoving() {
        let samples = [s(0, moving: true), s(5, moving: true), s(10, moving: true), s(11)]
        let sum = PixelWatchSummary(samples: samples, scanTimes: [0.4, 5.5, 12])
        #expect(sum.movingFrames == 3)
        #expect(sum.unnoticedMoving == 1)   // t=10: next scan at 12 is > 1 s later
    }
    @Test func emptySamples() {
        let sum = PixelWatchSummary(samples: [])
        #expect(sum.disagreementFraction == 0 && sum.unnoticedMoving == 0)
    }
}
