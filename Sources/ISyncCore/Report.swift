import Foundation

/// Machine-readable outcome of a run (`--report file.json`). This is the auditable record
/// behind the terminal verdict.
public struct Report: Codable {
    public struct Settings: Codable {
        public var source: String
        public var destination: String
        public var dryRun: Bool
        public var compare: CompareMode
        public var verify: Bool
        public var delete: Bool
        public var fsync: Bool
        public var jobs: Int
        public var mtimeWindow: Double
        public var excludes: [String]
        public var sourceFilesystem: String
        public var destinationFilesystem: String
        public var caseInsensitive: Bool

        public init(source: String, destination: String, dryRun: Bool, compare: CompareMode, verify: Bool, delete: Bool,
                    fsync: Bool, jobs: Int, mtimeWindow: Double, excludes: [String], sourceFilesystem: String,
                    destinationFilesystem: String, caseInsensitive: Bool) {
            self.source = source; self.destination = destination; self.dryRun = dryRun; self.compare = compare
            self.verify = verify; self.delete = delete; self.fsync = fsync; self.jobs = jobs; self.mtimeWindow = mtimeWindow
            self.excludes = excludes; self.sourceFilesystem = sourceFilesystem
            self.destinationFilesystem = destinationFilesystem; self.caseInsensitive = caseInsensitive
        }
    }

    public struct Counts: Codable {
        public var scannedSource: Int
        public var scannedDestination: Int
        public var unchangedFiles: Int
        public var unchangedBytes: Int64
        public var unchangedSymlinks: Int
        public var unchangedDirectories: Int
        public var filesCopied: Int
        public var bytesCopied: Int64
        public var filesUpdated: Int
        public var hashedIdentical: Int
        public var verified: Int
        public var metadataUpdated: Int
        public var symlinks: Int
        public var directoriesCreated: Int
        public var directoryMetadataSet: Int
        public var deleted: Int
        public var extraneousLeft: Int
        public var typeConflicts: Int
        public var skippedSpecial: Int
        public var sourceChangedDuringCopy: Int

        public init(scannedSource: Int, scannedDestination: Int, unchangedFiles: Int, unchangedBytes: Int64,
                    unchangedSymlinks: Int, unchangedDirectories: Int, filesCopied: Int, bytesCopied: Int64,
                    filesUpdated: Int, hashedIdentical: Int, verified: Int, metadataUpdated: Int, symlinks: Int,
                    directoriesCreated: Int, directoryMetadataSet: Int, deleted: Int, extraneousLeft: Int,
                    typeConflicts: Int, skippedSpecial: Int, sourceChangedDuringCopy: Int) {
            self.scannedSource = scannedSource; self.scannedDestination = scannedDestination
            self.unchangedFiles = unchangedFiles; self.unchangedBytes = unchangedBytes
            self.unchangedSymlinks = unchangedSymlinks; self.unchangedDirectories = unchangedDirectories
            self.filesCopied = filesCopied; self.bytesCopied = bytesCopied; self.filesUpdated = filesUpdated
            self.hashedIdentical = hashedIdentical; self.verified = verified; self.metadataUpdated = metadataUpdated
            self.symlinks = symlinks; self.directoriesCreated = directoriesCreated
            self.directoryMetadataSet = directoryMetadataSet; self.deleted = deleted; self.extraneousLeft = extraneousLeft
            self.typeConflicts = typeConflicts; self.skippedSpecial = skippedSpecial
            self.sourceChangedDuringCopy = sourceChangedDuringCopy
        }
    }

    public var tool: String
    public var version: String
    public var startedAt: Date
    public var finishedAt: Date
    public var durationSeconds: Double
    public var verdict: String
    public var exitCode: Int32
    public var settings: Settings
    public var counts: Counts
    public var errors: [SyncError]
    public var warnings: [SyncError]
    public var skippedSpecial: [String]

    public init(tool: String, version: String, startedAt: Date, finishedAt: Date, durationSeconds: Double, verdict: String,
                exitCode: Int32, settings: Settings, counts: Counts, errors: [SyncError], warnings: [SyncError],
                skippedSpecial: [String]) {
        self.tool = tool; self.version = version; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds; self.verdict = verdict; self.exitCode = exitCode
        self.settings = settings; self.counts = counts; self.errors = errors; self.warnings = warnings
        self.skippedSpecial = skippedSpecial
    }

    public func write(to path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
