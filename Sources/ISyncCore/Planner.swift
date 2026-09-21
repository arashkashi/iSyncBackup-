import Foundation

/// How the planner decides whether a file present on both sides is unchanged.
public enum CompareMode: String, Codable {
    /// size + mtime (within a window) + permissions. When only mtime differs, both sides are
    /// hashed before deciding, so a `touch`ed-but-identical file is not recopied.
    case quick
    /// Hash every file present on both sides, regardless of metadata. This is the audit mode
    /// that backs a "100% synced" claim; it reads every byte of both trees.
    case hash
}

public struct PlanOptions {
    public var compare: CompareMode = .quick
    /// Two mtimes closer than this (seconds) are considered equal. 0 = exact nanosecond match
    /// (APFS→APFS); 1s when HFS+ is involved; 2s for FAT/exFAT/network destinations.
    public var mtimeWindow: Double = 0
    /// Remove destination items that do not exist in the source (`--delete`).
    public var deleteExtraneous: Bool = false
    /// False when the destination filesystem cannot store POSIX permissions (FAT/exFAT/SMB),
    /// otherwise every run would try to "fix" them again.
    public var comparePermissions: Bool = true

    public init() {}
}

public enum ActionKind: String, Codable {
    case mkdir
    case copy
    /// Sizes match; hash both sides at execution time and copy only if the digests differ.
    case hashCompare
    /// Content is unchanged; only permissions/flags/xattrs need refreshing.
    case updateMeta
    case symlink
    case delete
    /// Directory permissions/flags/xattrs/mtime, applied after all children are final.
    case dirMeta
}

public struct Action {
    public let kind: ActionKind
    public let relPath: String
    public let src: Entry?
    public let dst: Entry?
    public let reason: String

    public init(kind: ActionKind, relPath: String, src: Entry?, dst: Entry?, reason: String) {
        self.kind = kind
        self.relPath = relPath
        self.src = src
        self.dst = dst
        self.reason = reason
    }

    /// Source bytes this action will read (drives the progress bar).
    public var workBytes: Int64 {
        switch kind {
        case .copy, .hashCompare: return src?.size ?? 0
        default: return 0
        }
    }
}

/// The complete, ordered set of operations that turns `destination` into a mirror of `source`.
public struct Plan {
    /// Removals needed because a path changed type (file↔dir↔symlink). Deepest first; run first.
    public var preDeletes: [Action] = []
    /// Shallowest first.
    public var mkdirs: [Action] = []
    /// copy / hashCompare / updateMeta / symlink — independent of each other, safe to run in parallel.
    public var fileActions: [Action] = []
    /// Destination items absent from the source (only with `deleteExtraneous`). Deepest first.
    public var postDeletes: [Action] = []
    /// Deepest first. The destination root itself is never touched.
    public var dirMeta: [Action] = []

    public var unchangedFiles = 0
    public var unchangedBytes: Int64 = 0
    public var unchangedSymlinks = 0
    public var unchangedDirs = 0
    /// Items in the destination that are not in the source and were NOT scheduled for deletion.
    public var extraneous = 0
    public var extraneousBytes: Int64 = 0
    /// Paths whose type changed; each one costs a removal in the destination.
    public var typeConflicts = 0
    /// Sockets, FIFOs, devices in the source — cannot be backed up as files.
    public var skippedSpecial: [Entry] = []

    public var deleteCount: Int { preDeletes.count + postDeletes.count }
    public var deleteBytes: Int64 {
        (preDeletes + postDeletes).reduce(0) { $0 + ($1.dst?.size ?? 0) }
    }
    public var workBytesTotal: Int64 { fileActions.reduce(0) { $0 + $1.workBytes } }
    public var bytesToCopy: Int64 {
        fileActions.reduce(0) { $0 + ($1.kind == .copy ? ($1.src?.size ?? 0) : 0) }
    }
    public var totalActions: Int {
        preDeletes.count + mkdirs.count + fileActions.count + postDeletes.count + dirMeta.count
    }
    public var isEmpty: Bool { totalActions == 0 }
}

public enum Planner {
    /// Flags we can meaningfully compare and reproduce. Excludes UF_COMPRESSED / UF_TRACKED
    /// (kernel-managed; a plain copy never has them) and all SF_* superuser flags.
    public static let comparableFlags: UInt32 = 0x0000_ffff & ~(UInt32(UF_COMPRESSED) | UInt32(UF_TRACKED))

    static func mtimeClose(_ a: timespec, _ b: timespec, window: Double) -> Bool {
        if a == b { return true }
        return abs(a.seconds - b.seconds) <= window
    }

    static func metaEqual(_ s: Entry, _ d: Entry, comparePermissions: Bool) -> Bool {
        (!comparePermissions || s.mode == d.mode)
            && (s.flags & comparableFlags) == (d.flags & comparableFlags)
    }

    public static func plan(source: Tree, destination dst: Tree, options: PlanOptions) -> Plan {
        var plan = Plan()
        // Destination keys we have accounted for; whatever is left over is extraneous.
        var handled = Set<String>()
        // Directories whose contents will change, so their mtime must be re-applied afterwards.
        var dirtyDirs = Set<String>()

        func parentKey(_ relPath: String) -> String? {
            guard let slash = relPath.lastIndex(of: "/") else { return nil }
            return dst.key(String(relPath[..<slash]))
        }
        func markDirty(_ relPath: String) {
            if let p = parentKey(relPath) { dirtyDirs.insert(p) }
        }
        /// Remove a destination item that is in the way, including everything under it.
        func removeConflicting(_ d: Entry) {
            plan.typeConflicts += 1
            if d.kind == .directory {
                for child in dst.descendants(of: d.relPath) {
                    handled.insert(dst.key(child.relPath))
                    plan.preDeletes.append(Action(kind: .delete, relPath: child.relPath, src: nil, dst: child,
                                                  reason: "inside replaced directory"))
                }
            }
            plan.preDeletes.append(Action(kind: .delete, relPath: d.relPath, src: nil, dst: d,
                                          reason: "type changed to \(source[d.relPath]?.kind.rawValue ?? "?")"))
            markDirty(d.relPath)
        }

        let sourceEntries = source.entries.values.sorted { $0.relPath < $1.relPath }

        for s in sourceEntries {
            let d = dst[s.relPath]
            if d != nil { handled.insert(dst.key(s.relPath)) }

            switch s.kind {
            case .other:
                plan.skippedSpecial.append(s)

            case .directory:
                if let d = d, d.kind == .directory {
                    // Metadata decided after the loop, once we know which dirs got dirty.
                    continue
                }
                if let d = d { removeConflicting(d) }
                plan.mkdirs.append(Action(kind: .mkdir, relPath: s.relPath, src: s, dst: d, reason: d == nil ? "new" : "replaced"))
                markDirty(s.relPath)

            case .file:
                guard let d = d else {
                    plan.fileActions.append(Action(kind: .copy, relPath: s.relPath, src: s, dst: nil, reason: "new"))
                    markDirty(s.relPath)
                    continue
                }
                if d.kind != .file {
                    removeConflicting(d)
                    plan.fileActions.append(Action(kind: .copy, relPath: s.relPath, src: s, dst: nil, reason: "replaced \(d.kind.rawValue)"))
                    markDirty(s.relPath)
                    continue
                }
                if s.size != d.size {
                    plan.fileActions.append(Action(kind: .copy, relPath: s.relPath, src: s, dst: d, reason: "size changed"))
                    markDirty(s.relPath)
                    continue
                }
                if options.compare == .hash {
                    plan.fileActions.append(Action(kind: .hashCompare, relPath: s.relPath, src: s, dst: d, reason: "audit"))
                    markDirty(s.relPath)
                    continue
                }
                if !mtimeClose(s.mtime, d.mtime, window: options.mtimeWindow) {
                    plan.fileActions.append(Action(kind: .hashCompare, relPath: s.relPath, src: s, dst: d, reason: "mtime changed"))
                    markDirty(s.relPath)
                    continue
                }
                if !metaEqual(s, d, comparePermissions: options.comparePermissions) {
                    plan.fileActions.append(Action(kind: .updateMeta, relPath: s.relPath, src: s, dst: d, reason: "permissions/flags changed"))
                    continue
                }
                plan.unchangedFiles += 1
                plan.unchangedBytes += s.size

            case .symlink:
                if let d = d {
                    if d.kind == .symlink {
                        if d.linkTarget == s.linkTarget {
                            plan.unchangedSymlinks += 1
                            continue
                        }
                        plan.fileActions.append(Action(kind: .symlink, relPath: s.relPath, src: s, dst: d, reason: "target changed"))
                        markDirty(s.relPath)
                        continue
                    }
                    removeConflicting(d)
                    plan.fileActions.append(Action(kind: .symlink, relPath: s.relPath, src: s, dst: nil, reason: "replaced \(d.kind.rawValue)"))
                    markDirty(s.relPath)
                    continue
                }
                plan.fileActions.append(Action(kind: .symlink, relPath: s.relPath, src: s, dst: nil, reason: "new"))
                markDirty(s.relPath)
            }
        }

        // Extraneous destination items.
        for (key, d) in dst.entries where !handled.contains(key) {
            if options.deleteExtraneous {
                plan.postDeletes.append(Action(kind: .delete, relPath: d.relPath, src: nil, dst: d, reason: "not in source"))
                markDirty(d.relPath)
            } else {
                plan.extraneous += 1
                plan.extraneousBytes += d.size
            }
        }

        // Directory metadata: new dirs, dirs whose contents we touch, dirs whose own metadata differs.
        for s in sourceEntries where s.kind == .directory {
            let d = dst[s.relPath]
            let isNew = d == nil || d!.kind != .directory
            let dirty = dirtyDirs.contains(dst.key(s.relPath))
            var differs = false
            if let d = d, d.kind == .directory {
                differs = !mtimeClose(s.mtime, d.mtime, window: options.mtimeWindow)
                    || !metaEqual(s, d, comparePermissions: options.comparePermissions)
            }
            if isNew || dirty || differs {
                plan.dirMeta.append(Action(kind: .dirMeta, relPath: s.relPath, src: s, dst: d,
                                           reason: isNew ? "new" : (dirty ? "contents changed" : "metadata changed")))
            } else {
                plan.unchangedDirs += 1
            }
        }

        // Ordering guarantees: parents before children for creation, children before parents for removal.
        plan.mkdirs.sort { $0.relPath < $1.relPath }
        plan.preDeletes.sort { ($0.dst?.depth ?? 0, $0.relPath) > ($1.dst?.depth ?? 0, $1.relPath) }
        plan.postDeletes.sort { ($0.dst?.depth ?? 0, $0.relPath) > ($1.dst?.depth ?? 0, $1.relPath) }
        plan.dirMeta.sort { ($0.src?.depth ?? 0, $0.relPath) > ($1.src?.depth ?? 0, $1.relPath) }
        // Big files first: keeps all workers busy until the end instead of one worker finishing
        // a huge file alone while the others idle.
        plan.fileActions.sort { $0.workBytes > $1.workBytes }

        return plan
    }
}
