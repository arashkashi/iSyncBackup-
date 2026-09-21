import Foundation
import CryptoKit

public struct ExecOptions {
    public var dryRun = false
    /// Parallel workers for the file phase. I/O bound: more than ~8 rarely helps on one disk.
    public var jobs = 4
    /// Re-read every copied file from the destination and compare digests.
    public var verify = true
    /// fsync each file before renaming it into place.
    public var fsync = true
    /// F_FULLFSYNC the destination once at the end.
    public var flushAtEnd = true
    /// Called for every completed action (for `--verbose` logging). May be called from any thread.
    public var onAction: ((Action, String) -> Void)? = nil
    /// Called the moment an action fails, so errors can be shown while the run is still going.
    public var onError: ((SyncError) -> Void)? = nil

    public init() {}
}

/// Executes a `Plan` against the filesystem, phase by phase, reporting into `Stats`.
public final class Executor {
    private let plan: Plan
    private let source: Tree
    private let destination: Tree
    private let options: ExecOptions
    private let stats: Stats
    private let cancel: Cancellation

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
        for a in plan.preDeletes { if cancel.isCancelled { return false }; perform(a, worker: 0) }

        stats.setPhase(.creatingDirectories)
        for a in plan.mkdirs { if cancel.isCancelled { return false }; perform(a, worker: 0) }

        stats.setPhase(.syncingFiles)
        runParallel(plan.fileActions)
        if cancel.isCancelled { return false }

        stats.setPhase(.deleting)
        for a in plan.postDeletes { if cancel.isCancelled { return false }; perform(a, worker: 0) }

        stats.setPhase(.directoryMetadata)
        for a in plan.dirMeta { if cancel.isCancelled { return false }; perform(a, worker: 0) }

        if options.flushAtEnd && !options.dryRun {
            stats.setPhase(.flushing)
            do { try FileOps.fullFsync(directory: destination.root) } catch {
                stats.error(SyncError(path: destination.root, op: "flush", message: "\(error)"))
            }
        }
        return !cancel.isCancelled
    }

    private func runParallel(_ actions: [Action]) {
        guard !actions.isEmpty else { return }
        let workers = max(1, min(options.jobs, actions.count))
        let next = Counter()
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileOps.chunkSize, alignment: 4096)
            defer { buffer.deallocate() }
            while !cancel.isCancelled {
                let i = next.next()
                guard i < actions.count else { break }
                perform(actions[i], worker: worker, buffer: buffer)
            }
            stats.setCurrent(worker: worker, nil)
        }
    }

    // MARK: - Individual actions

    private func perform(_ a: Action, worker: Int, buffer: UnsafeMutableRawPointer? = nil) {
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
                outcome = try copy(a, from: srcPath, to: dstPath, worker: worker, buffer: buffer!)

            case .hashCompare:
                outcome = try hashCompare(a, srcPath: srcPath, dstPath: dstPath, worker: worker, buffer: buffer!)

            case .updateMeta:
                outcome = "metadata"
                if !options.dryRun { try FileOps.copyMetadata(from: srcPath, to: dstPath) }
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

    private func copy(_ a: Action, from srcPath: String, to dstPath: String, worker: Int, buffer: UnsafeMutableRawPointer) throws -> String {
        let src = a.src!
        stats.setCurrent(worker: worker, "→ \(a.relPath)")
        defer { stats.setCurrent(worker: worker, nil) }

        if options.dryRun {
            stats.addWork(bytes: src.size, io: 0)
            stats.update { $0.filesCopied += 1; $0.bytesCopied += src.size; if a.dst != nil { $0.filesUpdated += 1 } }
            return "would copy (\(a.reason))"
        }

        var verifying = false
        var accounted: Int64 = 0
        let result: CopyResult
        do {
            result = try FileOps.copyFile(from: srcPath, to: dstPath, existing: a.dst, verify: options.verify,
                                          fsync: options.fsync, buffer: buffer, cancelled: { self.cancel.isCancelled }) { srcBytes, io in
                accounted += Int64(srcBytes)
                self.stats.addWork(bytes: Int64(srcBytes), io: Int64(io))
                if srcBytes == 0 && !verifying {
                    verifying = true
                    self.stats.setCurrent(worker: worker, "✓ verifying \(a.relPath)")
                }
            }
        } catch {
            // Keep the progress bar honest: the bytes this action was budgeted for are "done"
            // (as a failure) even though they were never read.
            if !(error is CancelledError) { stats.addWork(bytes: max(0, src.size - accounted), io: 0) }
            throw error
        }
        stats.update {
            $0.filesCopied += 1
            $0.bytesCopied += result.bytes
            if a.dst != nil { $0.filesUpdated += 1 }
            if result.verified { $0.verified += 1 }
            if result.sourceChangedDuringCopy { $0.sourceChangedDuringCopy += 1 }
        }
        if result.sourceChangedDuringCopy {
            stats.warning(SyncError(path: a.relPath, op: "copy", message: "source was modified while being copied; run again"))
        }
        return "copied (\(a.reason))" + (result.verified ? ", verified" : "")
    }

    private func hashCompare(_ a: Action, srcPath: String, dstPath: String, worker: Int, buffer: UnsafeMutableRawPointer) throws -> String {
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
            if !options.dryRun && a.dst.map({ !Planner.metaEqual(a.src!, $0, comparePermissions: true) || $0.mtime != a.src!.mtime }) ?? false {
                try FileOps.copyMetadata(from: srcPath, to: dstPath)
            }
            stats.addWork(bytes: sbytes, io: 0)
            stats.update { $0.hashedIdentical += 1 }
            return "identical by SHA-256 (\(a.reason))"
        }
        // Different: fall through to a real copy. The bytes already hashed are re-read; progress is
        // accounted for by the copy itself.
        let copyAction = Action(kind: .copy, relPath: a.relPath, src: a.src, dst: a.dst, reason: "content changed")
        return try copy(copyAction, from: srcPath, to: dstPath, worker: worker, buffer: buffer)
    }
}

/// Lock-protected monotonically increasing index for the worker pool.
final class Counter {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = value; value += 1; return v }
}
