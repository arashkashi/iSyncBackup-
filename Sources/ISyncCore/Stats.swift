import Foundation

public enum Phase: String, Codable {
    case idle, scanning, planning, confirming, removingConflicts, creatingDirectories,
         syncingFiles, verifying, deleting, directoryMetadata, flushing, done, interrupted
}

/// Cooperative cancellation flag (set from a SIGINT handler, polled by workers).
public final class Cancellation {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Counters shared between worker threads and the UI thread. Every access goes through one lock;
/// contention is negligible because updates happen per file or per 4 MiB chunk.
public final class Stats {
    public struct Snapshot {
        public var phase: Phase = .idle
        public var scannedSource = 0
        public var scannedDestination = 0
        public var scanningSource: String? = nil
        public var scanningDestination: String? = nil
        public var actionsTotal = 0
        public var actionsDone = 0
        public var workBytesTotal: Int64 = 0
        public var workBytesDone: Int64 = 0
        /// Cumulative bytes read + written by the tool (for the throughput display).
        public var ioBytes: Int64 = 0
        public var filesCopied = 0
        public var bytesCopied: Int64 = 0
        public var filesUpdated = 0        // copied over an existing file
        public var metaUpdated = 0
        public var hashedIdentical = 0     // hashCompare found both sides equal
        public var verified = 0
        public var verifyFailed = 0
        /// Second pass over copied files: fsync + read-back + metadata.
        public var finalizeTotal = 0
        public var finalizeDone = 0
        public var finalizeBytesTotal: Int64 = 0
        public var finalizeBytesDone: Int64 = 0
        /// Copies left without metadata/verification because the run was interrupted.
        public var unfinalized = 0
        public var symlinks = 0
        public var dirsCreated = 0
        public var dirMetaSet = 0
        public var deleted = 0
        public var sourceChangedDuringCopy = 0
        public var errors: [SyncError] = []
        public var warnings: [SyncError] = []
        /// What each worker is doing right now, keyed by worker index.
        public var current: [Int: String] = [:]
        public var startedAt = Date()
    }

    private let lock = NSLock()
    private var s = Snapshot()

    public init() {}

    public var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return s }

    public func update(_ body: (inout Snapshot) -> Void) {
        lock.lock(); body(&s); lock.unlock()
    }

    public func setPhase(_ p: Phase) { update { $0.phase = p } }

    public func addWork(bytes: Int64, io: Int64) {
        update { $0.workBytesDone += bytes; $0.ioBytes += io }
    }

    public func error(_ e: SyncError) { update { $0.errors.append(e) } }
    public func warning(_ e: SyncError) { update { $0.warnings.append(e) } }

    public func setCurrent(worker: Int, _ text: String?) {
        update { if let t = text { $0.current[worker] = t } else { $0.current.removeValue(forKey: worker) } }
    }
}
