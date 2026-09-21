import Foundation

/// What kind of filesystem object an entry is.
public enum EntryKind: String, Codable {
    case file, directory, symlink
    /// Sockets, FIFOs, device nodes. Never copied; reported as skipped.
    case other
}

extension timespec: @retroactive Equatable {
    public static func == (a: timespec, b: timespec) -> Bool {
        a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec
    }
}

extension timespec {
    /// Seconds as a Double (loses precision beyond ~1µs; only used for windowed compares).
    var seconds: Double { Double(tv_sec) + Double(tv_nsec) / 1e9 }
}

/// One scanned filesystem object, relative to a tree root.
public struct Entry: Equatable {
    /// Path relative to the tree root, "/"-separated, original case, no leading slash.
    public let relPath: String
    public let kind: EntryKind
    /// Logical size (`st_size`), not allocated blocks — matters for sparse/cloned files on APFS.
    public let size: Int64
    /// Modification time with nanosecond precision (`st_mtimespec`).
    public let mtime: timespec
    /// Permission + setuid/setgid/sticky bits only (`st_mode & 0o7777`).
    public let mode: mode_t
    /// BSD file flags (`st_flags`): uchg, hidden, etc.
    public let flags: UInt32
    public let dev: dev_t
    public let ino: ino_t
    public let nlink: UInt16
    /// Target of a symlink, verbatim. Nil for everything else.
    public let linkTarget: String?

    public init(relPath: String, kind: EntryKind, size: Int64, mtime: timespec, mode: mode_t,
                flags: UInt32, dev: dev_t, ino: ino_t, nlink: UInt16, linkTarget: String?) {
        self.relPath = relPath
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.flags = flags
        self.dev = dev
        self.ino = ino
        self.nlink = nlink
        self.linkTarget = linkTarget
    }

    /// Number of path components (root children have depth 1).
    public var depth: Int {
        relPath.isEmpty ? 0 : relPath.utf8.reduce(1) { $0 + ($1 == UInt8(ascii: "/") ? 1 : 0) }
    }

    public var name: String {
        if let slash = relPath.lastIndex(of: "/") { return String(relPath[relPath.index(after: slash)...]) }
        return relPath
    }
}

/// A non-fatal problem encountered during scan or execution.
/// Errors never abort the run; they are collected and make the final verdict "NOT SYNCED".
public struct SyncError: Codable, CustomStringConvertible {
    public let path: String
    public let op: String
    public let message: String

    public init(path: String, op: String, message: String) {
        self.path = path
        self.op = op
        self.message = message
    }

    public var description: String { "\(op) \(path): \(message)" }
}

/// Read errno right after a failing syscall.
func errnoMessage() -> String {
    String(cString: strerror(errno))
}

/// The scanned contents of one directory tree.
public final class Tree {
    /// Absolute, canonical root path (no trailing slash except for "/").
    public let root: String
    /// Whether lookups fold case + Unicode normalization. Decided by the caller for both trees at once.
    public let foldKeys: Bool
    public let fsType: String
    public let rootDev: dev_t
    public private(set) var entries: [String: Entry] = [:]
    public var errors: [SyncError] = []
    /// Entries skipped because of `--one-file-system` or exclude rules (count only).
    public var excludedCount = 0

    public init(root: String, foldKeys: Bool, fsType: String, rootDev: dev_t) {
        self.root = root
        self.foldKeys = foldKeys
        self.fsType = fsType
        self.rootDev = rootDev
    }

    /// Case-insensitive filesystems (the macOS default) treat "Foo" and "foo" as one file.
    /// APFS compares names case-folded and normalization-insensitive; this approximates that.
    public static func fold(_ relPath: String) -> String {
        relPath.decomposedStringWithCanonicalMapping.lowercased()
    }

    public func key(_ relPath: String) -> String {
        foldKeys ? Tree.fold(relPath) : relPath
    }

    public subscript(relPath: String) -> Entry? {
        entries[key(relPath)]
    }

    public func insert(_ entry: Entry) {
        entries[key(entry.relPath)] = entry
    }

    public var count: Int { entries.count }

    /// Absolute path of an entry (or of any relative path) inside this tree.
    public func absolutePath(_ relPath: String) -> String {
        if relPath.isEmpty { return root }
        return root == "/" ? "/" + relPath : root + "/" + relPath
    }

    /// All entries whose path is strictly under `relPath`.
    public func descendants(of relPath: String) -> [Entry] {
        let prefix = key(relPath) + "/"
        return entries.compactMap { $0.key.hasPrefix(prefix) ? $0.value : nil }
    }
}
