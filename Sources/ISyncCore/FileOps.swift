import Foundation
import CryptoKit

// copyfile(3) flag bits. Spelled out because the compound macros do not import into Swift.
let COPYFILE_ACL_: UInt32 = 1 << 0
let COPYFILE_STAT_: UInt32 = 1 << 1
let COPYFILE_XATTR_: UInt32 = 1 << 2
/// mode, flags, times, ACLs, extended attributes (resource forks, Finder info, tags, quarantine…).
let COPYFILE_METADATA_: UInt32 = COPYFILE_ACL_ | COPYFILE_STAT_ | COPYFILE_XATTR_
let COPYFILE_NOFOLLOW_SRC_: UInt32 = 1 << 18
let COPYFILE_NOFOLLOW_DST_: UInt32 = 1 << 19

public struct FileOpError: Error, CustomStringConvertible {
    public let op: String
    public let message: String
    public var description: String { "\(op): \(message)" }
    init(_ op: String, _ message: String? = nil) {
        self.op = op
        self.message = message ?? errnoMessage()
    }
}

public struct CancelledError: Error {}

/// Low-level, crash-safe file operations. All paths are absolute.
public enum FileOps {
    public static let chunkSize = 4 * 1024 * 1024

    static func digestHex(_ d: SHA256Digest) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    /// Hash a whole file. `progress` receives bytes read per chunk.
    public static func hashFile(_ path: String, buffer: UnsafeMutableRawPointer, noCache: Bool = true,
                                cancelled: () -> Bool, progress: (Int) -> Void) throws -> (SHA256Digest, Int64) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw FileOpError("open") }
        defer { close(fd) }
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            if cancelled() { throw CancelledError() }
            let n = read(fd, buffer, chunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileOpError("read")
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            total += Int64(n)
            progress(n)
        }
        return (hasher.finalize(), total)
    }

    private static func writeAll(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) throws {
        var off = 0
        while off < count {
            let n = write(fd, buf + off, count - off)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileOpError("write")
            }
            off += n
        }
    }

    static func tempPath(near dst: String) -> String {
        let dir = (dst as NSString).deletingLastPathComponent
        let token = String(format: "%08x%08x", arc4random(), arc4random())
        return (dir.isEmpty ? "." : dir) + "/.isync-tmp-" + token
    }

    /// uchg/uappnd on the destination would make rename/unlink fail; strip them first.
    static func clearImmutable(_ path: String, flags: UInt32) {
        let bad = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)
        if flags & bad != 0 {
            _ = lchflags(path, flags & ~bad)
        }
    }

    /// Phase 1 of a copy: stream `src` → temp file in the destination directory (hashing on the
    /// way) → atomic `rename()` over `dst`. On return `dst` holds the complete new content but has a
    /// fresh mtime and 0600 permissions; `finalizeCopy` applies the real metadata after
    /// verification. A crash at any point leaves the old file, the complete new one with a fresh
    /// mtime (re-checked by the next run), or a stray `.isync-tmp-*` — never a partial file under
    /// the real name, and never a partial file that looks up to date.
    public static func copyData(from src: String, to dst: String, existing: Entry?,
                                buffer: UnsafeMutableRawPointer, cancelled: () -> Bool,
                                progress: (_ sourceBytes: Int, _ ioBytes: Int) -> Void) throws -> (SHA256Digest, Int64) {
        let sfd = open(src, O_RDONLY | O_NOFOLLOW)
        guard sfd >= 0 else { throw FileOpError("open source") }
        defer { close(sfd) }
        _ = fcntl(sfd, F_NOCACHE, 1)

        let tmp = tempPath(near: dst)
        let dfd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard dfd >= 0 else { throw FileOpError("create temp file") }
        _ = fcntl(dfd, F_NOCACHE, 1)
        var tmpOpen = true
        var tmpExists = true
        defer {
            if tmpOpen { close(dfd) }
            if tmpExists { unlink(tmp) }
        }

        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            if cancelled() { throw CancelledError() }
            let n = read(sfd, buffer, chunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileOpError("read source")
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            try writeAll(dfd, buffer, n)
            total += Int64(n)
            progress(n, 2 * n)
        }
        if close(dfd) != 0 { tmpOpen = false; throw FileOpError("close temp file") }
        tmpOpen = false

        if let e = existing { clearImmutable(dst, flags: e.flags) }
        guard rename(tmp, dst) == 0 else { throw FileOpError("rename into place") }
        tmpExists = false
        return (hasher.finalize(), total)
    }

    public struct FinalizeResult {
        public let verified: Bool
        /// The source no longer matches what was scanned (size or mtime differ).
        public let sourceChanged: Bool
    }

    /// Phase 2 of a copy, run in a later pass so that on spinning disks the reads are sequential:
    ///   1. `fsync` (optional) — the data is on the drive before we look at it
    ///   2. read `dst` back bypassing the page cache and compare the SHA-256 (optional)
    ///   3. apply permissions/flags/ACLs/xattrs from the source, then stamp the mtime that was
    ///      *scanned*, not the source's current one — so if the source changed mid-run the
    ///      backup never claims to be up to date with it
    /// On a digest mismatch `dst` is deleted so the next run cannot mistake it for a good copy.
    public static func finalizeCopy(src: String, dst: String, entry: Entry, expected: SHA256Digest, expectedBytes: Int64,
                                    verify: Bool, fsync doFsync: Bool, buffer: UnsafeMutableRawPointer,
                                    cancelled: () -> Bool, progress: (Int) -> Void) throws -> FinalizeResult {
        let fd = open(dst, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw FileOpError("open for verification") }
        var fdOpen = true
        defer { if fdOpen { close(fd) } }
        if doFsync && fsync(fd) != 0 { throw FileOpError("fsync") }

        if verify {
            _ = fcntl(fd, F_NOCACHE, 1)
            var hasher = SHA256()
            var total: Int64 = 0
            while true {
                if cancelled() { throw CancelledError() }
                let n = read(fd, buffer, chunkSize)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FileOpError("read back")
                }
                if n == 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
                total += Int64(n)
                progress(n)
            }
            if hasher.finalize() != expected || total != expectedBytes {
                close(fd); fdOpen = false
                unlink(dst)
                throw FileOpError("verify", "read-back digest does not match what was written (destination file removed)")
            }
        }
        close(fd); fdOpen = false

        try copyMetadata(from: src, to: dst, mtime: entry.mtime)

        var now = stat()
        let changed = lstat(src, &now) == 0 && (Int64(now.st_size) != entry.size || now.st_mtimespec != entry.mtime)
        return FinalizeResult(verified: verify, sourceChanged: changed)
    }

    /// Permissions, flags, ACLs, xattrs and times from `src`. When `mtime` is given, the
    /// destination is stamped with that (scanned) value rather than the source's current one.
    public static func copyMetadata(from src: String, to dst: String, mtime: timespec? = nil) throws {
        if copyfile(src, dst, nil, COPYFILE_METADATA_ | COPYFILE_NOFOLLOW_SRC_ | COPYFILE_NOFOLLOW_DST_) != 0 {
            throw FileOpError("copy metadata (xattrs/permissions/times)")
        }
        if let m = mtime {
            var times = [m, m]
            if utimensat(AT_FDCWD, dst, &times, AT_SYMLINK_NOFOLLOW) != 0 { throw FileOpError("set mtime") }
        }
    }

    public static func makeDirectory(_ path: String) throws {
        if mkdir(path, 0o755) != 0 {
            var st = stat()
            if errno == EEXIST && lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR { return }
            throw FileOpError("mkdir")
        }
    }

    public static func makeSymlink(target: String, at dst: String, existing: Entry?, mtime: timespec) throws {
        if let e = existing {
            clearImmutable(dst, flags: e.flags)
            if unlink(dst) != 0 && errno != ENOENT { throw FileOpError("remove old symlink") }
        }
        guard symlink(target, dst) == 0 else { throw FileOpError("symlink") }
        var times = [mtime, mtime]
        _ = utimensat(AT_FDCWD, dst, &times, AT_SYMLINK_NOFOLLOW) // best effort
    }

    public static func remove(_ entry: Entry, at path: String) throws {
        clearImmutable(path, flags: entry.flags)
        if entry.kind == .directory {
            if rmdir(path) != 0 && errno != ENOENT { throw FileOpError("rmdir") }
        } else {
            if unlink(path) != 0 && errno != ENOENT { throw FileOpError("unlink") }
        }
    }

    /// Ask the drive to flush its write cache. One call at the end of a run makes everything
    /// written so far durable against power loss; per-file it would be far too slow.
    public static func fullFsync(directory path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FileOpError("open for F_FULLFSYNC") }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0 {
            // Not supported on every filesystem (e.g. some network mounts); fall back to fsync.
            if fsync(fd) != 0 { throw FileOpError("F_FULLFSYNC") }
        }
    }
}
