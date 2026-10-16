import Foundation

/// What one worker accumulated while reading directories. Workers fill their own batch with no
/// locking and merge it into the shared `Tree` occasionally, so the hot path stays contention-free.
struct ScanBatch {
    var entries: [(key: String, entry: Entry)] = []
    var errors: [SyncError] = []
    var excluded = 0
    var scanned = 0
    var bulkFailures = 0

    var isEmpty: Bool { entries.isEmpty && errors.isEmpty && excluded == 0 && bulkFailures == 0 }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        errors.removeAll(keepingCapacity: true)
        excluded = 0
        bulkFailures = 0
    }
}

/// The set of directories still to be read.
///
/// Workers take a directory, read it, and hand back the subdirectories they found. A worker only
/// stops when the queue is empty *and* no other worker is still reading — otherwise it could quit
/// while a directory that is about to produce more work is still being read.
final class DirectoryQueue {
    private let cond = NSCondition()
    private var pending: [(abs: String, rel: String)]
    /// Directories claimed by a worker but not yet finished.
    private var active = 0
    private var aborted = false

    init(root: (abs: String, rel: String)) {
        pending = [root]
    }

    /// Claims the next directory, blocking while others may still produce work.
    /// Returns nil when the whole tree has been read (or the scan was aborted).
    func next() -> (abs: String, rel: String)? {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if aborted { return nil }
            if let d = pending.popLast() {
                active += 1
                return d
            }
            if active == 0 {
                // Nothing queued and nobody working: the tree is exhausted. Wake the others.
                cond.broadcast()
                return nil
            }
            cond.wait()
        }
    }

    /// Returns the subdirectories found in the directory just read. Must be called exactly once
    /// for every directory `next()` handed out, or the scan will not terminate.
    func finish(pushing subdirs: [(abs: String, rel: String)]) {
        cond.lock()
        pending.append(contentsOf: subdirs)
        active -= 1
        cond.broadcast()
        cond.unlock()
    }

    /// Drops all queued work and releases every blocked worker (cancellation).
    func abort() {
        cond.lock()
        aborted = true
        pending.removeAll()
        cond.broadcast()
        cond.unlock()
    }
}

/// Shared entry counter, read by the progress display.
final class ScanProgress {
    private let lock = NSLock()
    private var total = 0
    func add(_ n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        total += n
        return total
    }
    var value: Int { lock.lock(); defer { lock.unlock() }; return total }
}
