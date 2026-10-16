import Foundation

public struct ScanOptions {
    public var excludes: IgnoreRules
    /// Don't descend into directories on a different device (mount points). The mount point
    /// directory itself is still recorded, as an empty directory — same behaviour as `rsync -x`.
    public var oneFileSystem: Bool
    /// Relative paths (already folded if the tree folds) to skip entirely — used to keep the
    /// destination out of the source scan when it lives inside it.
    public var skipRelPaths: Set<String>

    public init(excludes: IgnoreRules = IgnoreRules(), oneFileSystem: Bool = false, skipRelPaths: Set<String> = []) {
        self.excludes = excludes
        self.oneFileSystem = oneFileSystem
        self.skipRelPaths = skipRelPaths
    }
}

/// Walks a directory tree with `opendir`/`readdir`/`fstatat` (never following symlinks) and
/// builds a `Tree`. Errors (unreadable directories, vanished files) are recorded, not thrown.
public final class Scanner {
    public static let version = "0.4.1"

    /// `pathconf(_PC_CASE_SENSITIVE)` is 0 on the default macOS APFS/HFS+ volumes.
    public static func isCaseInsensitive(_ path: String) -> Bool {
        pathconf(path, _PC_CASE_SENSITIVE) == 0
    }

    /// e.g. "apfs", "hfs", "exfat", "msdos", "smbfs".
    public static func fsTypeName(_ path: String) -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return "unknown" }
        return withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
    }

    public static func canonicalPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    private let options: ScanOptions
    /// (entries so far, directory currently being read)
    private let progress: ((Int, String) -> Void)?
    private var scannedCount = 0
    private var cancelled: () -> Bool
    /// Reused across every directory; freed in deinit.
    private let bulkBuffer = UnsafeMutableRawPointer.allocate(byteCount: BulkDirectory.bufferSize, alignment: 8)
    /// Set false by `ISYNC_NO_BULK=1` to force the portable readdir path (used by the tests that
    /// prove the two paths agree).
    private let useBulk = ProcessInfo.processInfo.environment["ISYNC_NO_BULK"] == nil
    /// Directories the bulk path could not handle (reported in the JSON report).
    public private(set) var useBulkFailures = 0

    public init(options: ScanOptions, cancelled: @escaping () -> Bool = { false }, progress: ((Int, String) -> Void)? = nil) {
        self.options = options
        self.cancelled = cancelled
        self.progress = progress
    }

    deinit { bulkBuffer.deallocate() }


    /// Applies exclusions, resolves symlinks and records one entry. Shared by both read paths so
    /// they cannot drift apart.
    private func add(name: String, kind: EntryKind, size: Int64, mtime: timespec, mode: mode_t,
                     flags: UInt32, dev: dev_t, ino: ino_t, nlink: UInt16,
                     absPath: String, parentRel: String, dfd: Int32, into tree: Tree,
                     subdirs: inout [(abs: String, rel: String)]) {
        let rel = parentRel.isEmpty ? name : parentRel + "/" + name
        let abs = absPath == "/" ? "/" + name : absPath + "/" + name

        if options.skipRelPaths.contains(tree.key(rel)) { tree.excludedCount += 1; return }
        if options.excludes.matches(relPath: rel, name: name, isDirectory: kind == .directory) {
            tree.excludedCount += 1
            return
        }

        var linkTarget: String? = nil
        if kind == .symlink {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlinkat(dfd, name, &buf, buf.count - 1)
            if n < 0 {
                if errno != ENOENT {
                    tree.errors.append(SyncError(path: abs, op: "readlink", message: errnoMessage()))
                }
                return
            }
            buf[Int(n)] = 0
            linkTarget = String(cString: buf)
        }

        tree.insert(Entry(relPath: rel, kind: kind, size: size, mtime: mtime, mode: mode,
                          flags: flags, dev: dev, ino: ino, nlink: nlink, linkTarget: linkTarget))

        scannedCount += 1
        if scannedCount % 500 == 0 { progress?(scannedCount, parentRel) }

        if kind == .directory {
            if options.oneFileSystem && dev != tree.rootDev {
                return // record the mount point, don't cross into it
            }
            subdirs.append((abs, rel))
        }
    }

    public func scan(root: String, foldKeys: Bool) -> Tree {
        var st = stat()
        let rootDev: dev_t = lstat(root, &st) == 0 ? st.st_dev : 0
        let tree = Tree(root: root, foldKeys: foldKeys, fsType: Scanner.fsTypeName(root), rootDev: rootDev)
        walk(directory: root, relPath: "", into: tree)
        progress?(scannedCount, "")
        return tree
    }

    private func walk(directory absPath: String, relPath parentRel: String, into tree: Tree) {
        progress?(scannedCount, parentRel)
        guard let dir = opendir(absPath) else {
            tree.errors.append(SyncError(path: absPath, op: "opendir", message: errnoMessage()))
            return
        }
        defer { closedir(dir) }
        let dfd = dirfd(dir)

        // Collect first, then recurse: keeps one open dir fd per depth level, not per sibling.
        var subdirs: [(abs: String, rel: String)] = []

        // Fast path: one syscall returns names and metadata for many entries at once. On a
        // spinning disk this is ~30x faster than a stat per entry. It yields exactly the same
        // fields, and falls back to readdir + fstatat whenever it cannot.
        if useBulk, let raw = BulkDirectory.list(fd: dfd, buffer: bulkBuffer) {
            for r in raw {
                if cancelled() { return }
                add(name: r.name, kind: r.kind, size: r.size, mtime: r.mtime, mode: r.mode,
                    flags: r.flags, dev: r.dev, ino: r.ino, nlink: r.nlink,
                    absPath: absPath, parentRel: parentRel, dfd: dfd, into: tree, subdirs: &subdirs)
            }
        } else {
            useBulkFailures += 1
            while let ent = readdir(dir) {
                if cancelled() { return }
                let name = withUnsafePointer(to: &ent.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(PATH_MAX)) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }

                let abs = absPath == "/" ? "/" + name : absPath + "/" + name
                var st = stat()
                guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                    // ENOENT here means it vanished between readdir and stat — not worth an error.
                    if errno != ENOENT {
                        tree.errors.append(SyncError(path: abs, op: "lstat", message: errnoMessage()))
                    }
                    continue
                }
                let kind: EntryKind
                switch st.st_mode & S_IFMT {
                case S_IFREG: kind = .file
                case S_IFDIR: kind = .directory
                case S_IFLNK: kind = .symlink
                default: kind = .other
                }
                add(name: name, kind: kind, size: kind == .file ? Int64(st.st_size) : 0,
                    mtime: st.st_mtimespec, mode: st.st_mode & 0o7777, flags: st.st_flags,
                    dev: st.st_dev, ino: st.st_ino, nlink: st.st_nlink,
                    absPath: absPath, parentRel: parentRel, dfd: dfd, into: tree, subdirs: &subdirs)
            }
        }

        for sub in subdirs {
            if cancelled() { return }
            walk(directory: sub.abs, relPath: sub.rel, into: tree)
        }
    }
}
