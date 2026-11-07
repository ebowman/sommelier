import Foundation

public protocol LayoutStore: Sendable {
    func load() throws -> Layout
    func save(_ layout: Layout) throws
}

public struct FileLayoutStore: LayoutStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sommelier/layout.json")
    }

    public func load() throws -> Layout { try loadWithWarnings().0 }

    /// Missing file -> `Layout.empty`. Corrupt content -> backed up to `<file>.bak` and `.corrupt` thrown.
    public func loadWithWarnings() throws -> (Layout, [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return (.empty, []) }
        let data = try Data(contentsOf: url)
        let decoded: (layout: Layout, warnings: [String], adoptBarOrder: Bool)
        do {
            decoded = try Layout.decode(data)
        } catch {
            let bak = url.appendingPathExtension("bak")
            try? fm.removeItem(at: bak)
            try? data.write(to: bak)
            throw LayoutError.corrupt(underlying: error, backup: bak)
        }
        return (try Layout.migrate(decoded.layout), decoded.warnings)
    }

    public func save(_ layout: Layout) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(layout)
        let tmp = dir.appendingPathComponent("\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
            if rename(tmp.path, url.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}

public final class InMemoryLayoutStore: LayoutStore, @unchecked Sendable {
    private let lock = NSLock()
    private var layout: Layout
    public init(_ layout: Layout = .empty) { self.layout = layout }
    public func load() throws -> Layout { lock.lock(); defer { lock.unlock() }; return layout }
    public func save(_ layout: Layout) throws { lock.lock(); defer { lock.unlock() }; self.layout = layout }
}
