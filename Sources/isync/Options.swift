import Foundation
import ISyncCore

struct Options {
    var source = ""
    var destination = ""
    var dryRun = false
    var delete = false
    var force = false
    var yes = false
    var compare: CompareMode = .quick
    var verify = true
    var fsync = true
    var excludes: [String] = []
    var useDefaultExcludes = true
    var oneFileSystem = false
    var jobs = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    var mtimeWindow: Double? = nil
    var reportPath: String? = nil
    var verbose = false
    var quiet = false
    var color = true

    static let usage = """
    isync \(Scanner.version) — one-way, verified folder mirroring for macOS

    USAGE
      isync [options] <source> <destination>

    Makes <destination> an exact mirror of <source>. Only differences are transferred.
    Nothing is deleted from <destination> unless --delete is given.

    OPTIONS
      -n, --dry-run             Show what would happen; change nothing (hashes are still computed).
          --delete              Remove items from destination that no longer exist in source.
          --force               Skip the safety guard that refuses to delete >25% of the destination.
      -y, --yes                 Delete without asking (the prompt shows the list; "no" keeps the
                                items and syncs the rest; no terminal counts as "no").
          --compare quick|hash  quick (default): size + mtime + permissions, hashing only when in doubt.
                                hash: SHA-256 every file on both sides (full audit; reads everything).
          --no-verify           Skip re-reading each copied file to confirm the bytes on disk.
          --no-fsync            Skip per-file fsync (faster on many small files; less crash-safe).
          --exclude PATTERN     Glob to skip (repeatable). Name match if no "/", else relative path.
          --no-default-excludes Also copy .DS_Store, .Spotlight-V100, .fseventsd, .Trashes, … .
      -x, --one-file-system     Do not descend into other mounted volumes.
      -j, --jobs N              Parallel file workers (default: \(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)))).
          --mtime-window SEC    Treat mtimes this close as equal (default: 0 APFS→APFS, 1 with HFS+, 2 FAT/exFAT/network).
          --report FILE         Write a JSON report of the run.
      -v, --verbose             Print one line per action.
      -q, --quiet               Only print the final verdict and errors.
          --no-color            Disable colors (also honours NO_COLOR).
      -h, --help                Show this help.
          --version             Show version.

    A `.isyncignore` file in the source root adds exclude patterns (one per line).

    EXIT CODES
      0  synced (and verified, per the options used)     2  finished with errors — NOT synced
      1  bad arguments / refused to start                3  synced, with warnings (e.g. source changed mid-copy)
      130 interrupted
    """

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ argv: [String]) throws -> Options? {
        var o = Options()
        var positional: [String] = []
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < argv.count else { throw UsageError(description: "\(flag) needs a value") }
            return argv[i]
        }
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "-h", "--help":
                print(usage); return nil
            case "--version":
                print("isync \(Scanner.version)"); return nil
            case "-n", "--dry-run": o.dryRun = true
            case "--delete": o.delete = true
            case "--force": o.force = true
            case "-y", "--yes": o.yes = true
            case "--compare":
                let v = try value(a)
                guard let m = CompareMode(rawValue: v) else { throw UsageError(description: "--compare must be quick or hash") }
                o.compare = m
            case "--no-verify": o.verify = false
            case "--no-fsync": o.fsync = false
            case "--exclude": o.excludes.append(try value(a))
            case "--no-default-excludes": o.useDefaultExcludes = false
            case "-x", "--one-file-system": o.oneFileSystem = true
            case "-j", "--jobs":
                guard let n = Int(try value(a)), n >= 1, n <= 64 else { throw UsageError(description: "--jobs must be 1…64") }
                o.jobs = n
            case "--mtime-window":
                guard let w = Double(try value(a)), w >= 0 else { throw UsageError(description: "--mtime-window must be ≥ 0") }
                o.mtimeWindow = w
            case "--report": o.reportPath = try value(a)
            case "-v", "--verbose": o.verbose = true
            case "-q", "--quiet": o.quiet = true
            case "--no-color": o.color = false
            default:
                if a.hasPrefix("-") && a != "-" { throw UsageError(description: "unknown option \(a)") }
                positional.append(a)
            }
            i += 1
        }
        guard positional.count == 2 else {
            throw UsageError(description: "expected <source> and <destination>\n\n\(usage)")
        }
        o.source = positional[0]
        o.destination = positional[1]
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { o.color = false }
        return o
    }
}
