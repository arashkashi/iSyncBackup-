import Foundation

/// The metadata `Scanner` needs about one directory entry, however it was obtained.
struct RawEntry {
    var name: String
    var kind: EntryKind
    var size: Int64
    var mtime: timespec
    var mode: mode_t
    var flags: UInt32
    var dev: dev_t
    var ino: ino_t
    var nlink: UInt16
}

/// Reads a whole directory with `getattrlistbulk(2)`: one syscall returns the names *and* the
/// metadata of many entries at once, instead of `readdir` plus an `fstatat` per entry.
///
/// On a spinning disk this is the difference between ~100 and ~3,000 entries per second, because
/// the per-file `fstatat` calls each cost a seek while the bulk call reads the directory's
/// metadata in one go.
///
/// It is strictly an optimisation: `list` returns nil whenever anything is not exactly as
/// expected — the filesystem does not support the call, or an entry arrives without every
/// attribute we asked for — and the caller then falls back to `readdir` + `fstatat`, which works
/// everywhere. Nothing downstream can tell which path produced an `Entry`.
enum BulkDirectory {
    // Requested attributes. The order of the fields in the reply buffer follows the order of
    // these bits (common, then dir, then file), and ATTR_CMN_RETURNED_ATTRS always comes first.
    static let wantCommon: attrgroup_t =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_ACCESSMASK) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
    static let wantDir: attrgroup_t = attrgroup_t(ATTR_DIR_LINKCOUNT)
    static let wantFile: attrgroup_t = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_DATALENGTH)

    /// Attributes every entry must carry for the fast path to be used.
    static let requiredCommon: attrgroup_t =
        attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCESSMASK) | attrgroup_t(ATTR_CMN_FLAGS)
        | attrgroup_t(ATTR_CMN_FILEID)

    static let bufferSize = 128 * 1024

    /// Lists `fd` (an open directory). Returns nil if the fast path cannot be trusted for it.
    /// `buffer` must be at least `bufferSize` bytes; it is reused across calls.
    static func list(fd: Int32, buffer: UnsafeMutableRawPointer) -> [RawEntry]? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = wantCommon
        attrs.dirattr = wantDir
        attrs.fileattr = wantFile

        var out: [RawEntry] = []
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, 0)
            if count < 0 { return nil }      // not supported here, or an error: use the slow path
            if count == 0 { return out }     // end of directory

            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let start = cursor
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                guard length > 0 else { return nil }
                var p = cursor.advanced(by: MemoryLayout<UInt32>.size)

                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p = p.advanced(by: MemoryLayout<attribute_set_t>.size)
                guard returned.commonattr & requiredCommon == requiredCommon else { return nil }

                // Fields appear in bitmap order, and only when the filesystem returned them.
                let nameRef = p.loadUnaligned(as: attrreference_t.self)
                let name = String(cString: p.advanced(by: Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                p = p.advanced(by: MemoryLayout<attrreference_t>.size)

                let dev = p.loadUnaligned(as: dev_t.self)
                p = p.advanced(by: MemoryLayout<dev_t>.size)

                let objType = p.loadUnaligned(as: fsobj_type_t.self)
                p = p.advanced(by: MemoryLayout<fsobj_type_t>.size)

                let mtime = p.loadUnaligned(as: timespec.self)
                p = p.advanced(by: MemoryLayout<timespec>.size)

                let accessMask = p.loadUnaligned(as: UInt32.self)
                p = p.advanced(by: MemoryLayout<UInt32>.size)

                let flags = p.loadUnaligned(as: UInt32.self)
                p = p.advanced(by: MemoryLayout<UInt32>.size)

                let fileID = p.loadUnaligned(as: UInt64.self)
                p = p.advanced(by: MemoryLayout<UInt64>.size)

                // Directories carry ATTR_DIR_*, files carry ATTR_FILE_* — never both, so the
                // layout genuinely differs per entry and must be driven by `returned`.
                var nlink: UInt32 = 1
                if returned.dirattr & attrgroup_t(ATTR_DIR_LINKCOUNT) != 0 {
                    nlink = p.loadUnaligned(as: UInt32.self)
                    p = p.advanced(by: MemoryLayout<UInt32>.size)
                }
                if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                    nlink = p.loadUnaligned(as: UInt32.self)
                    p = p.advanced(by: MemoryLayout<UInt32>.size)
                }
                var size: Int64 = 0
                let kind: EntryKind
                switch objType {
                case fsobj_type_t(VREG.rawValue):
                    kind = .file
                    guard returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 else { return nil }
                    size = p.loadUnaligned(as: Int64.self)
                case fsobj_type_t(VDIR.rawValue): kind = .directory
                case fsobj_type_t(VLNK.rawValue): kind = .symlink
                default: kind = .other
                }

                out.append(RawEntry(
                    name: name,
                    kind: kind,
                    size: kind == .file ? size : 0,
                    mtime: mtime,
                    // ATTR_CMN_ACCESSMASK is the full st_mode; keep only the permission bits,
                    // exactly as the fstatat path does.
                    mode: mode_t(accessMask & 0o7777),
                    flags: flags,
                    dev: dev,
                    ino: ino_t(fileID),
                    nlink: UInt16(truncatingIfNeeded: nlink)
                ))
                cursor = start.advanced(by: length)
            }
        }
    }
}
