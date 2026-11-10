import Foundation

public protocol LayoutStore: Sendable {
    func load() throws -> Layout
    func save(_ layout: Layout) throws
    /// gdu.145: copies the current stored layout aside BEFORE a migration changes it. Returns the backup's name (nil: nothing to copy).
    /// Never overwrites an existing backup. Throws when the copy cannot be made (the migration must then not run).
    func backupBeforeMigration() throws -> String?
}

public extension LayoutStore {
    func backupBeforeMigration() throws -> String? { nil }
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

    /// `<file>.gdu145-backup`; if that exists, `<file>.gdu145-backup-2`, `-3`, ... (an earlier backup is never overwritten).
    public func backupBeforeMigration() throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        var n = 1
        var dest = url.appendingPathExtension("gdu145-backup")
        while fm.fileExists(atPath: dest.path) { n += 1; dest = url.appendingPathExtension("gdu145-backup-\(n)") }
        try fm.copyItem(at: url, to: dest)
        return dest.lastPathComponent
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
