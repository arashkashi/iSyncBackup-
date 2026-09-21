import Foundation
import CryptoKit

public struct ExecOptions {
    public var dryRun = false
    /// Parallel workers for the file phases. I/O bound: more than ~8 rarely helps on one disk.
    public var jobs = 4
    /// Re-read every copied file from the destination and compare digests.
    public var verify = true
    /// fsync each copied file before it is verified and stamped.
    public var fsync = true
    /// F_FULLFSYNC the destination once at the end.
    public var flushAtEnd = true
    /// False on filesystems that cannot store permissions (avoids pointless metadata refreshes).
    public var comparePermissions = true
    /// Called for every completed action (for `--verbose` logging). May be called from any thread.
    public var onAction: ((Action, String) -> Void)? = nil
    /// Called the moment an action fails, so errors can be shown while the run is still going.
    public var onError: ((SyncError) -> Void)? = nil

    public init() {}
}

/// Executes a `Plan` against the filesystem, phase by phase, reporting into `Stats`.
///
/// Copies happen in two passes. Pass 1 streams data into place (temp file + atomic rename).
/// Pass 2 walks the copied files *in the order they were written* — sequential on spinning
/// disks — and for each one fsyncs, reads it back, compares the SHA-256, and only then applies
/// the real permissions and the scanned mtime. Until pass 2 has run, a copied file carries a
/// fresh mtime, so an interrupted run can never leave something that merely looks synced.
public final class Executor {
    private struct Pending {
        let actionIndex: Int
        let digest: SHA256Digest
        let bytes: Int64
    }

    private let plan: Plan
    private let source: Tree
    private let destination: Tree
    private let options: ExecOptions
    private let stats: Stats
    private let cancel: Cancellation
    private let pendingLock = NSLock()
    private var pending: [Pending] = []

    public init(plan: Plan, source: Tree, destination: Tree, options: ExecOptions, stats: Stats, cancellation: Cancellation) {
        self.plan = plan
        self.source = source
        self.destination = destination
        self.options = options
        self.stats = stats
        self.cancel = cancellation
    }

    /// Returns false if the run was interrupted.
    public func run() -> Bool {
        stats.update {
            $0.actionsTotal = plan.totalActions
            $0.workBytesTotal = plan.workBytesTotal
        }

        stats.setPhase(.removingConflicts)
        for a in plan.preDeletes { if cancel.isCancelled { return false }; perform(a, index: -1, worker: 0) }

        stats.setPhase(.creatingDirectories)
        for a in plan.mkdirs { if cancel.isCancelled { return false }; perform(a, index: -1, worker: 0) }

        stats.setPhase(.syncingFiles)
        runParallel(count: plan.fileActions.count) { i, worker, buffer in
            self.perform(self.plan.fileActions[i], index: i, worker: worker, buffer: buffer)
        }
        if cancel.isCancelled { noteUnfinalized(); return false }

        stats.setPhase(.verifying)
        finalizeCopies()
        if cancel.isCancelled { noteUnfinalized(); return false }

        stats.setPhase(.deleting)
        for a in plan.postDeletes { if cancel.isCancelled { return false }; perform(a, index: -1, worker: 0) }

        stats.setPhase(.directoryMetadata)
        for a in plan.dirMeta { if cancel.isCancelled { return false }; perform(a, index: -1, worker: 0) }

        if options.flushAtEnd && !options.dryRun {
            stats.setPhase(.flushing)
            do { try FileOps.fullFsync(directory: destination.root) } catch {
                stats.error(SyncError(path: destination.root, op: "flush", message: "\(error)"))
            }
        }
        return !cancel.isCancelled
    }

    private func noteUnfinalized() {
        pendingLock.lock(); let n = pending.count; pendingLock.unlock()
        let done = stats.snapshot.finalizeDone
        stats.update { $0.unfinalized = max(0, n - done) }
    }

    private func runParallel(count: Int, _ body: @escaping (Int, Int, UnsafeMutableRawPointer) -> Void) {
        guard count > 0 else { return }
        let workers = max(1, min(options.jobs, count))
        let next = Counter()
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileOps.chunkSize, alignment: 4096)
            defer { buffer.deallocate() }
            while !cancel.isCancelled {
                let i = next.next()
                guard i < count else { break }
                body(i, worker, buffer)
            }
            stats.setCurrent(worker: worker, nil)
        }
    }

    // MARK: - Pass 1: individual actions

    private func perform(_ a: Action, index: Int, worker: Int, buffer: UnsafeMutableRawPointer? = nil) {
        let srcPath = source.absolutePath(a.relPath)
        let dstPath = destination.absolutePath(a.relPath)
        var outcome = ""
        do {
            switch a.kind {
            case .mkdir:
                outcome = "mkdir"
                if !options.dryRun { try FileOps.makeDirectory(dstPath) }
                stats.update { $0.dirsCreated += 1 }

            case .copy:
                outcome = try copy(a, index: index, from: srcPath, to: dstPath, worker: worker, buffer: buffer!)

            case .hashCompare:
                outcome = try hashCompare(a, index: index, srcPath: srcPath, dstPath: dstPath, worker: worker, buffer: buffer!)

            case .updateMeta:
                outcome = "metadata"
                if !options.dryRun { try FileOps.copyMetadata(from: srcPath, to: dstPath, mtime: a.src!.mtime) }
                stats.update { $0.metaUpdated += 1 }

            case .symlink:
                outcome = "symlink"
                if !options.dryRun {
                    try FileOps.makeSymlink(target: a.src!.linkTarget ?? "", at: dstPath, existing: a.dst, mtime: a.src!.mtime)
                }
                stats.update { $0.symlinks += 1 }

            case .delete:
                outcome = "delete"
                if !options.dryRun { try FileOps.remove(a.dst!, at: dstPath) }
                stats.update { $0.deleted += 1 }

            case .dirMeta:
                // A directory marked "contents changed" only needs work if something actually
                // changed inside it (a hash-check that found both sides identical touches nothing).
                if a.reason == "contents changed", let src = a.src, !options.dryRun {
                    var st = stat()
                    if lstat(dstPath, &st) == 0, st.st_mtimespec == src.mtime, (st.st_mode & 0o7777) == src.mode,
                       (st.st_flags & Planner.comparableFlags) == (src.flags & Planner.comparableFlags) {
                        outcome = "dir metadata already current"
                        break
                    }
                }
                outcome = "dir metadata"
                if !options.dryRun { try FileOps.copyMetadata(from: srcPath, to: dstPath) }
                stats.update { $0.dirMetaSet += 1 }
            }
        } catch is CancelledError {
            return
        } catch {
            outcome = "ERROR \(error)"
            let e = SyncError(path: a.relPath, op: a.kind.rawValue, message: "\(error)")
            stats.error(e)
            options.onError?(e)
        }
        stats.update { $0.actionsDone += 1 }
        options.onAction?(a, outcome)
    }

    private func copy(_ a: Action, index: Int, from srcPath: String, to dstPath: String, worker: Int, buffer: UnsafeMutableRawPointer) throws -> String {
        let src = a.src!
        stats.setCurrent(worker: worker, "→ \(a.relPath)")
        defer { stats.setCurrent(worker: worker, nil) }

        if options.dryRun {
            stats.addWork(bytes: src.size, io: 0)
            stats.update { $0.filesCopied += 1; $0.bytesCopied += src.size; if a.dst != nil { $0.filesUpdated += 1 } }
            return "would copy (\(a.reason))"
        }

        var accounted: Int64 = 0
        let digest: SHA256Digest
        let bytes: Int64
        do {
            (digest, bytes) = try FileOps.copyData(from: srcPath, to: dstPath, existing: a.dst, buffer: buffer,
                                                   cancelled: { self.cancel.isCancelled }) { srcBytes, io in
                accounted += Int64(srcBytes)
                self.stats.addWork(bytes: Int64(srcBytes), io: Int64(io))
            }
        } catch {
            // Keep the progress bar honest: this action's byte budget is spent even though it failed.
            if !(error is CancelledError) { stats.addWork(bytes: max(0, src.size - accounted), io: 0) }
            throw error
        }
        pendingLock.lock()
        pending.append(Pending(actionIndex: index, digest: digest, bytes: bytes))
        pendingLock.unlock()
        stats.update {
            $0.filesCopied += 1
            $0.bytesCopied += bytes
            if a.dst != nil { $0.filesUpdated += 1 }
        }
        return "copied (\(a.reason))"
    }

    private func hashCompare(_ a: Action, index: Int, srcPath: String, dstPath: String, worker: Int, buffer: UnsafeMutableRawPointer) throws -> String {
        stats.setCurrent(worker: worker, "# hashing \(a.relPath)")
        defer { stats.setCurrent(worker: worker, nil) }
        let sd: SHA256Digest, dd: SHA256Digest
        let sbytes: Int64, dbytes: Int64
        do {
            (sd, sbytes) = try FileOps.hashFile(srcPath, buffer: buffer, cancelled: { self.cancel.isCancelled }) { n in
                self.stats.addWork(bytes: 0, io: Int64(n))
            }
            (dd, dbytes) = try FileOps.hashFile(dstPath, buffer: buffer, cancelled: { self.cancel.isCancelled }) { n in
                self.stats.addWork(bytes: 0, io: Int64(n))
            }
        } catch {
            if !(error is CancelledError) { stats.addWork(bytes: a.src?.size ?? 0, io: 0) }
            throw error
        }
        if sd == dd && sbytes == dbytes {
            // Same bytes. Only bring the metadata (mtime etc.) in line so the next run is a quick skip.
            if !options.dryRun, let d = a.dst, let s = a.src,
               !Planner.metaEqual(s, d, comparePermissions: options.comparePermissions) || d.mtime != s.mtime {
                try FileOps.copyMetadata(from: srcPath, to: dstPath, mtime: s.mtime)
            }
            stats.addWork(bytes: sbytes, io: 0)
            stats.update { $0.hashedIdentical += 1 }
            return "identical by SHA-256 (\(a.reason))"
        }
        // Different: fall through to a real copy.
        let copyAction = Action(kind: .copy, relPath: a.relPath, src: a.src, dst: a.dst, reason: "content changed")
        return try copy(copyAction, index: index, from: srcPath, to: dstPath, worker: worker, buffer: buffer)
    }

    // MARK: - Pass 2: fsync, read back, stamp metadata

    private func finalizeCopies() {
        pendingLock.lock()
        let list = pending
        pendingLock.unlock()
        guard !list.isEmpty else { return }
        stats.update {
            $0.finalizeTotal = list.count
            $0.finalizeBytesTotal = list.reduce(0) { $0 + $1.bytes }
        }
        runParallel(count: list.count) { i, worker, buffer in
            let p = list[i]
            let a = self.plan.fileActions[p.actionIndex]
            let srcPath = self.source.absolutePath(a.relPath)
            let dstPath = self.destination.absolutePath(a.relPath)
            self.stats.setCurrent(worker: worker, (self.options.verify ? "✓ " : "· ") + a.relPath)
            defer { self.stats.setCurrent(worker: worker, nil) }
            var accounted: Int64 = 0
            do {
                let r = try FileOps.finalizeCopy(src: srcPath, dst: dstPath, entry: a.src!, expected: p.digest, expectedBytes: p.bytes,
                                                 verify: self.options.verify, fsync: self.options.fsync, buffer: buffer,
                                                 cancelled: { self.cancel.isCancelled }) { n in
                    accounted += Int64(n)
                    self.stats.update { $0.finalizeBytesDone += Int64(n); $0.ioBytes += Int64(n) }
                }
                self.stats.update {
                    if r.verified { $0.verified += 1 }
                    if r.sourceChanged { $0.sourceChangedDuringCopy += 1 }
                }
                if r.sourceChanged {
                    self.stats.warning(SyncError(path: a.relPath, op: "copy", message: "source was modified during the run; run again to capture the latest version"))
                }
                self.options.onAction?(a, self.options.verify ? "verified" : "finalized")
            } catch is CancelledError {
                return
            } catch {
                self.stats.update { if self.options.verify { $0.verifyFailed += 1 } }
                let e = SyncError(path: a.relPath, op: "verify", message: "\(error)")
                self.stats.error(e)
                self.options.onError?(e)
            }
            self.stats.update {
                $0.finalizeDone += 1
                $0.finalizeBytesDone += max(0, p.bytes - accounted)
            }
        }
    }
}

/// Lock-protected monotonically increasing index for the worker pool.
final class Counter {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = value; value += 1; return v }
}
