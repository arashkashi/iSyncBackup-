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
    public static let version = "0.2.0"

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

    public init(options: ScanOptions, cancelled: @escaping () -> Bool = { false }, progress: ((Int, String) -> Void)? = nil) {
        self.options = options
        self.cancelled = cancelled
        self.progress = progress
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

        while let ent = readdir(dir) {
            if cancelled() { return }
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(PATH_MAX)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }

            let rel = parentRel.isEmpty ? name : parentRel + "/" + name
            let abs = absPath == "/" ? "/" + name : absPath + "/" + name

            var st = stat()
            guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                // ENOENT here means it vanished between readdir and stat — not worth an error.
                if errno != ENOENT {
                    tree.errors.append(SyncError(path: abs, op: "lstat", message: errnoMessage()))
                }
                continue
            }

            let fmt = st.st_mode & S_IFMT
            let kind: EntryKind
            switch fmt {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }

            if options.skipRelPaths.contains(tree.key(rel)) { tree.excludedCount += 1; continue }
            if options.excludes.matches(relPath: rel, name: name, isDirectory: kind == .directory) {
                tree.excludedCount += 1
                continue
            }

            var linkTarget: String? = nil
            if kind == .symlink {
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlinkat(dfd, name, &buf, buf.count - 1)
                if n < 0 {
                    tree.errors.append(SyncError(path: abs, op: "readlink", message: errnoMessage()))
                    continue
                }
                buf[Int(n)] = 0
                linkTarget = String(cString: buf)
            }

            let entry = Entry(
                relPath: rel,
                kind: kind,
                size: kind == .file ? Int64(st.st_size) : 0,
                mtime: st.st_mtimespec,
                mode: st.st_mode & 0o7777,
                flags: st.st_flags,
                dev: st.st_dev,
                ino: st.st_ino,
                nlink: st.st_nlink,
                linkTarget: linkTarget
            )
            tree.insert(entry)

            scannedCount += 1
            if scannedCount % 500 == 0 { progress?(scannedCount, parentRel) }

            if kind == .directory {
                if options.oneFileSystem && st.st_dev != tree.rootDev {
                    continue // record the mount point, don't cross into it
                }
                subdirs.append((abs, rel))
            }
        }

        for sub in subdirs {
            if cancelled() { return }
            walk(directory: sub.abs, relPath: sub.rel, into: tree)
        }
    }
}
