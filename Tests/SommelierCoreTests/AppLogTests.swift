import Testing
import Foundation
@testable import SommelierCore

@Suite("AppLog file sink")
struct AppLogTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-applog-\(UUID().uuidString)", isDirectory: true)
    }
    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @Test func writesLinesInOrderWithTimestampCategoryText() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sink = FileLogSink(directory: dir)
        let d = Date(timeIntervalSince1970: 1_800_000_000.123)
        sink.write(category: .engine, text: "engine: first", date: d)
        sink.write(category: .arrange, text: "arrange rows: V[a] H[]", date: d.addingTimeInterval(1))
        sink.write(category: .poll, text: "two\nlines", date: d.addingTimeInterval(2))
        sink.flush()
        let lines = read(sink.fileURL).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "2027-01-15T08:00:00.123Z engine engine: first")
        #expect(lines[1] == "2027-01-15T08:00:01.123Z arrange arrange rows: V[a] H[]")
        #expect(lines[2] == "2027-01-15T08:00:02.123Z poll two\\nlines")
    }

    @Test func categoriesMapToTheirRawNames() {
        let names = AppLog.Category.allCases.map(\.rawValue)
        #expect(names == ["engine", "apps", "poll", "reveal", "activator", "arrange", "panel", "app", "permissions"])
        for c in AppLog.Category.allCases {
            let line = FileLogSink.format(date: Date(timeIntervalSince1970: 0), category: c, text: "x")
            #expect(line == "1970-01-01T00:00:00.000Z \(c.rawValue) x\n")
        }
    }

    @Test func rotatesAtSizeLimitKeepingThreeOldFiles() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sink = FileLogSink(directory: dir, maxBytes: 400, keep: 3)
        for i in 0..<60 { sink.write(category: .app, text: String(format: "line %02d ", i) + String(repeating: "x", count: 40)) }
        sink.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["sommelier.log", "sommelier.log.1", "sommelier.log.2", "sommelier.log.3"])
        for n in names {
            let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.size] as? Int ?? .max
            #expect(size <= 400)
        }
        #expect(read(sink.fileURL).contains("line 59 "))
        // older lines live in higher-numbered files
        func firstNumber(_ n: String) -> Int {
            let t = read(dir.appendingPathComponent(n)); let r = t.range(of: "line ")!
            return Int(t[r.upperBound...].prefix(2))!
        }
        #expect(firstNumber("sommelier.log.3") < firstNumber("sommelier.log.2"))
        #expect(firstNumber("sommelier.log.2") < firstNumber("sommelier.log.1"))
        #expect(firstNumber("sommelier.log.1") < firstNumber("sommelier.log"))
    }

    @Test func createsAMissingDirectory() {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let sink = FileLogSink(directory: root.appendingPathComponent("a/b/c"))
        sink.write(category: .app, text: "hello")
        sink.flush()
        #expect(read(sink.fileURL).hasSuffix(" app hello\n"))
    }

    @Test func anUnwritableDirectoryDropsSilently() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        let sink = FileLogSink(directory: dir.appendingPathComponent("sub"))
        for i in 0..<5 { sink.write(category: .app, text: "dropped \(i)") }
        sink.flush()   // must not crash; the failure is reported once to os_log
        #expect(!FileManager.default.fileExists(atPath: sink.fileURL.path))
    }
}
