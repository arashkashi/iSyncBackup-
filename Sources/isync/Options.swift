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
    var scanJobs = 8
    var mtimeWindow: Double? = nil
    var reportPath: String? = nil
    var verbose = false
    var quiet = false
    var color = true

    static let shortUsage = "usage: isync [options] <source> <destination>"

    // MARK: - help text
    //
    // The OPTIONS and EXAMPLES lists are data rather than one pre-formatted block: the columns are
    // then computed, so editing an entry cannot silently misalign the rest, and the flags and
    // commands can be highlighted without guessing where they start in a string.

    /// Flag column, then one or more description lines.
    private static var optionRows: [(flags: String, help: [String])] {
        [
            ("-n, --dry-run", ["Show what would happen; change nothing (hashes are still computed)."]),
            ("    --delete", ["Remove items from destination that no longer exist in source."]),
            ("    --force", ["Skip the safety guard that refuses to delete >25% of the destination."]),
            ("-y, --yes", ["Delete without asking (the prompt shows the list; \"no\" keeps the",
                           "items and syncs the rest; no terminal counts as \"no\")."]),
            ("    --compare quick|hash", ["quick (default): size + mtime + permissions, hashing only when",
                                          "in doubt.  hash: SHA-256 every file on both sides (full audit)."]),
            ("    --no-verify", ["Skip re-reading each copied file to confirm the bytes on disk."]),
            ("    --no-fsync", ["Skip per-file fsync (faster on many small files; less crash-safe)."]),
            ("    --exclude PATTERN", ["Glob to skip (repeatable). Name match if no \"/\", else relative path."]),
            ("    --no-default-excludes", ["Also copy .DS_Store, .Spotlight-V100, .fseventsd, .Trashes, … ."]),
            ("-x, --one-file-system", ["Do not descend into other mounted volumes."]),
            ("    --scan-jobs N", ["Directories read at once while scanning (default 8). The tree is",
                                   "identical at any setting; only the speed changes."]),
            ("-j, --jobs N", ["Parallel file workers (default: one per core, max 8)."]),
            ("    --mtime-window SEC", ["Treat mtimes this close as equal (default: 0 APFS→APFS,",
                                        "1 with HFS+, 2 FAT/exFAT/network)."]),
            ("    --report FILE", ["Write a JSON report of the run."]),
            ("-v, --verbose", ["Print one line per action."]),
            ("-q, --quiet", ["Only print the final verdict and errors."]),
            ("    --no-color", ["Disable colors (also honours NO_COLOR)."]),
            ("-h, --help", ["Show this help."]),
            ("    --version", ["Show version."]),
        ]
    }

    /// What it is for, then the command(s) to run. Kept identical to the Examples section of
    /// README.md — if you change one, change the other.
    private static let exampleRows: [(what: [String], cmds: [String])] = [
        (["Back up a folder. New and changed files are copied and verified;",
          "nothing is ever deleted from the backup."],
         ["isync ~/Documents /Volumes/BackupDrive/Documents"]),

        (["Dry run: print every action it would take, and change nothing.",
          "Safe to run at any time — it only reads."],
         ["isync -n --delete ~/Documents /Volumes/BackupDrive/Documents"]),

        (["Keep an exact mirror. Lists whatever exists only in the destination",
          "and asks before removing it; answering no still finishes the copying."],
         ["isync --delete ~/Documents /Volumes/BackupDrive/Documents"]),

        (["Back up a whole volume, staying on it (-x skips other mounts)."],
         ["isync -x --delete /Volumes/Archive /Volumes/ArchiveBackup/Archive"]),

        (["Skip caches and build junk. The same patterns can go in a",
          ".isyncignore file in the source root, one per line."],
         ["isync --exclude node_modules --exclude '*.tmp' ~/Code /Volumes/Backup/Code"]),

        (["Audit a backup you already have: re-reads every byte on both sides,",
          "compares SHA-256 and repairs what differs. This is what catches a",
          "drive silently corrupting a file (bit rot)."],
         ["isync --compare hash ~/Documents /Volumes/BackupDrive/Documents"]),

        (["Unattended (cron or launchd): never prompts, writes a JSON record.",
          "Exit code 0 means synced; anything else means read the report."],
         ["isync -q --yes --delete --report ~/isync-report.json SRC DST"]),

        (["First bulk copy onto a spinning hard drive — run BOTH lines.",
          "The first skips per-file checks for speed, the second reads",
          "everything back and verifies it. Do not skip the second line."],
         ["isync -x --delete --no-fsync --no-verify SRC DST",
          "isync -x --compare hash SRC DST"]),
    ]

    static func usage(color: Bool) -> String {
        func esc(_ s: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
        func head(_ s: String) -> String { esc(s, "1") }       // bold
        func flag(_ s: String) -> String { esc(s, "1;36") }    // bold cyan
        func cmd(_ s: String) -> String { esc(s, "36") }       // cyan
        func note(_ s: String) -> String { esc(s, "2") }       // dim

        let column = 26
        var out = head("isync \(Scanner.version)") + " — one-way, verified folder mirroring for macOS\n\n"

        out += head("USAGE") + "\n  isync [options] <source> <destination>\n\n"
        out += "Makes <destination> an exact mirror of <source>. Only differences are transferred.\n"
        out += "Nothing is deleted from <destination> unless --delete is given.\n\n"

        out += head("OPTIONS") + "\n"
        for row in optionRows {
            let gap = String(repeating: " ", count: max(1, column - row.flags.count))
            out += "  " + flag(row.flags) + gap + row.help[0] + "\n"
            for line in row.help.dropFirst() {
                out += "  " + String(repeating: " ", count: column) + line + "\n"
            }
        }
        out += "\nA `.isyncignore` file in the source root adds exclude patterns (one per line).\n\n"

        out += head("EXIT CODES") + "\n"
        out += "  0    synced (and verified, per the options used)\n"
        out += "  1    bad arguments, or refused to start\n"
        out += "  2    finished with errors — NOT synced\n"
        out += "  3    synced, with warnings (e.g. the source changed mid-copy)\n"
        out += "  130  interrupted\n\n"

        out += head("EXAMPLES") + "\n"
        for ex in exampleRows {
            for line in ex.what { out += "  " + note(line) + "\n" }
            for c in ex.cmds { out += "    " + cmd(c) + "\n" }
            out += "\n"
        }
        return String(out.reversed().drop { $0 == "\n" }.reversed())
    }

    /// Colour for `--help`. Decided here rather than from the parsed options because `--help`
    /// prints and exits before the rest of argv is read: stdout a terminal, NO_COLOR unset,
    /// and --no-color not asked for anywhere on the line.
    private static func helpColor(_ argv: [String]) -> Bool {
        isatty(STDOUT_FILENO) == 1
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            && !argv.contains("--no-color")
    }

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
                print(usage(color: helpColor(argv))); return nil
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
            case "--scan-jobs":
                guard let n = Int(try value(a)), n >= 1, n <= 64 else { throw UsageError(description: "--scan-jobs must be 1…64") }
                o.scanJobs = n
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
            // A full help dump on a typo buries the actual complaint; point at --help instead.
            throw UsageError(description: """
            expected <source> and <destination>
            \(shortUsage)
            Run `isync --help` for all options and examples.
            """)
        }
        o.source = positional[0]
        o.destination = positional[1]
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { o.color = false }
        return o
    }
}
