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

public struct CopyResult {
    public let digest: SHA256Digest
    public let bytes: Int64
    /// Source size or mtime differed between the start and end of the copy.
    public let sourceChangedDuringCopy: Bool
    public let verified: Bool
}

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

    /// Copy `src` to `dst` so that `dst` is either the old content or the complete new content,
    /// never a partial file:
    ///   1. stream source → temp file in the destination directory, hashing the bytes as they pass
    ///   2. fsync the temp file (unless `fsync == false`)
    ///   3. rename temp over `dst` (atomic on APFS/HFS+)
    ///   4. copy permissions, flags, times, ACLs and xattrs onto `dst`
    ///   5. if `verify`: re-read `dst` bypassing the page cache and compare digests;
    ///      on mismatch `dst` is deleted so the next run cannot mistake it for a good copy
    public static func copyFile(from src: String, to dst: String, existing: Entry?, verify: Bool, fsync doFsync: Bool,
                                buffer: UnsafeMutableRawPointer, cancelled: () -> Bool,
                                progress: (_ sourceBytes: Int, _ ioBytes: Int) -> Void) throws -> CopyResult {
        let sfd = open(src, O_RDONLY | O_NOFOLLOW)
        guard sfd >= 0 else { throw FileOpError("open source") }
        defer { close(sfd) }
        _ = fcntl(sfd, F_NOCACHE, 1)

        var before = stat()
        guard fstat(sfd, &before) == 0 else { throw FileOpError("fstat source") }

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
        let digest = hasher.finalize()

        if doFsync && fsync(dfd) != 0 { throw FileOpError("fsync") }
        if close(dfd) != 0 { tmpOpen = false; throw FileOpError("close temp file") }
        tmpOpen = false

        if let e = existing { clearImmutable(dst, flags: e.flags) }
        guard rename(tmp, dst) == 0 else { throw FileOpError("rename into place") }
        tmpExists = false

        // Metadata last, after the data is in place: a crash before this point leaves a file with a
        // fresh mtime, which the next run treats as "changed" and re-checks — self-healing.
        if copyfile(src, dst, nil, COPYFILE_METADATA_ | COPYFILE_NOFOLLOW_SRC_ | COPYFILE_NOFOLLOW_DST_) != 0 {
            throw FileOpError("copy metadata (xattrs/permissions/times)")
        }

        var after = stat()
        var sourceChanged = false
        if fstat(sfd, &after) == 0 {
            sourceChanged = after.st_size != before.st_size || after.st_mtimespec != before.st_mtimespec
        }

        var didVerify = false
        if verify {
            let (readBack, readBytes) = try hashFile(dst, buffer: buffer, cancelled: cancelled) { n in progress(0, n) }
            if readBack != digest || readBytes != total {
                unlink(dst)
                throw FileOpError("verify", "read-back digest does not match what was written (destination file removed)")
            }
            didVerify = true
        }
        return CopyResult(digest: digest, bytes: total, sourceChangedDuringCopy: sourceChanged, verified: didVerify)
    }

    public static func copyMetadata(from src: String, to dst: String) throws {
        if copyfile(src, dst, nil, COPYFILE_METADATA_ | COPYFILE_NOFOLLOW_SRC_ | COPYFILE_NOFOLLOW_DST_) != 0 {
            throw FileOpError("copy metadata")
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
