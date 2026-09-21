import Foundation
import ISyncCore

// MARK: - Helpers

func isDirectory(_ path: String) -> Bool {
    var st = stat()
    return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
}

func isInside(_ path: String, _ ancestor: String) -> Bool {
    if path == ancestor { return true }
    let prefix = ancestor == "/" ? "/" : ancestor + "/"
    return path.hasPrefix(prefix)
}

func relative(_ path: String, to root: String) -> String {
    if path == root { return "" }
    let prefix = root == "/" ? "/" : root + "/"
    return String(path.dropFirst(prefix.count))
}

/// Filesystems that cannot hold POSIX permissions, BSD flags or fine-grained mtimes.
let limitedFilesystems: Set<String> = ["msdos", "exfat", "ntfs", "smbfs", "cifs", "nfs", "webdav", "fusefs", "lifs"]

func fail(_ term: Terminal, _ message: String) -> Int32 {
    term.log(term.red("error: ") + message)
    return 1
}

// MARK: - Main

func run() -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    let opts: Options
    do {
        guard let parsed = try Options.parse(argv) else { return 0 }
        opts = parsed
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        return 1
    }

    let term = Terminal(color: opts.color)
    let stats = Stats()
    let cancellation = Cancellation()

    // Ctrl-C: finish the current chunk, clean up temp files, report what was done.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigint.setEventHandler { cancellation.cancel() }
    sigint.resume()
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    sigterm.setEventHandler { cancellation.cancel() }
    sigterm.resume()

    // --- Resolve and sanity-check paths -------------------------------------------------------
    guard let src = Scanner.canonicalPath(opts.source), isDirectory(src) else {
        return fail(term, "source is not an existing directory: \(opts.source)")
    }
    var destinationCreated = false
    if !FileManager.default.fileExists(atPath: opts.destination) {
        let parent = (opts.destination as NSString).deletingLastPathComponent
        guard isDirectory(parent.isEmpty ? "." : parent) else {
            return fail(term, "destination does not exist and neither does its parent: \(opts.destination)")
        }
        if opts.dryRun {
            term.log(term.yellow("note: ") + "destination \(opts.destination) does not exist; it would be created")
        } else {
            do { try FileOps.makeDirectory(opts.destination) } catch { return fail(term, "cannot create destination: \(error)") }
            destinationCreated = true
        }
    }
    let dst: String
    if destinationCreated || FileManager.default.fileExists(atPath: opts.destination) {
        guard let d = Scanner.canonicalPath(opts.destination), isDirectory(d) else {
            return fail(term, "destination is not a directory: \(opts.destination)")
        }
        dst = d
    } else {
        // dry run against a not-yet-existing destination
        dst = (Scanner.canonicalPath((opts.destination as NSString).deletingLastPathComponent) ?? ".") + "/" + (opts.destination as NSString).lastPathComponent
    }

    if src == dst { return fail(term, "source and destination are the same directory") }
    if isInside(src, dst) {
        return fail(term, "source is inside destination — with --delete this would erase the source. Refusing.")
    }
    var skipRelPaths: Set<String> = []
    let caseInsensitive = Scanner.isCaseInsensitive(src) || (isDirectory(dst) && Scanner.isCaseInsensitive(dst))
    if isInside(dst, src) {
        let rel = relative(dst, to: src)
        skipRelPaths.insert(caseInsensitive ? Tree.fold(rel) : rel)
        term.log(term.yellow("note: ") + "destination lives inside source; '\(rel)' is excluded from the scan")
    }

    let srcFS = Scanner.fsTypeName(src)
    let dstFS = isDirectory(dst) ? Scanner.fsTypeName(dst) : Scanner.fsTypeName((dst as NSString).deletingLastPathComponent)
    let limited = limitedFilesystems.contains(srcFS) || limitedFilesystems.contains(dstFS)
    // APFS keeps nanosecond mtimes and copyfile() reproduces them exactly, so APFS→APFS can
    // compare exactly. HFS+ stores whole seconds; FAT/exFAT/network shares are coarser still.
    let defaultWindow: Double = limited ? 2.0 : ((srcFS == "apfs" && dstFS == "apfs") ? 0.0 : 1.0)
    let mtimeWindow = opts.mtimeWindow ?? defaultWindow

    // --- Exclusions ---------------------------------------------------------------------------
    var rules = IgnoreRules(patterns: IgnoreRules.internalPatterns)
    if opts.useDefaultExcludes { rules.add(contentsOf: IgnoreRules.defaultPatterns) }
    rules.add(contentsOf: opts.excludes)
    let ignoreFile = src + "/.isyncignore"
    var ignoreFileLoaded = false
    if FileManager.default.fileExists(atPath: ignoreFile) {
        do { try rules.load(file: ignoreFile); ignoreFileLoaded = true } catch {
            term.log(term.yellow("warning: ") + "cannot read \(ignoreFile): \(error)")
        }
    }

    // --- Header -------------------------------------------------------------------------------
    if !opts.quiet {
        term.log(term.bold("isync \(Scanner.version)") + (opts.dryRun ? term.yellow("  [dry run]") : ""))
        term.log("  source       \(src)  " + term.dim("(\(srcFS))"))
        term.log("  destination  \(dst)  " + term.dim("(\(dstFS))") + (destinationCreated ? term.yellow("  created") : ""))
        var mode: [String] = []
        mode.append(opts.compare == .hash ? "compare: SHA-256 everything" : (mtimeWindow == 0 ? "compare: size+exact mtime, hash when in doubt" : "compare: size+mtime (±\(mtimeWindow)s), hash when in doubt"))
        mode.append(opts.verify ? "verify copies: on" : "verify copies: OFF")
        mode.append(opts.delete ? "delete extraneous: on" : "delete extraneous: off")
        mode.append("jobs: \(opts.jobs)")
        if caseInsensitive { mode.append("case-insensitive names") }
        if ignoreFileLoaded { mode.append(".isyncignore loaded") }
        term.log("  " + term.dim(mode.joined(separator: " · ")))
        if limited { term.log(term.yellow("  note: ") + "a filesystem in this pair (\(srcFS)/\(dstFS)) cannot store all macOS metadata; permissions are not compared") }
        term.log("")
    }

    // --- Scan ---------------------------------------------------------------------------------
    stats.setPhase(.scanning)
    let frame = FrameBuilder(term: term, stats: stats, dryRun: opts.dryRun)
    if !opts.quiet { term.startLive { frame.lines() } }

    var sourceTree: Tree!
    var destTree: Tree!
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let scanner = Scanner(options: ScanOptions(excludes: rules, oneFileSystem: opts.oneFileSystem, skipRelPaths: skipRelPaths),
                              cancelled: { cancellation.isCancelled },
                              progress: { n in stats.update { $0.scannedSource = n } })
        sourceTree = scanner.scan(root: src, foldKeys: caseInsensitive)
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        if isDirectory(dst) {
            let scanner = Scanner(options: ScanOptions(excludes: rules, oneFileSystem: opts.oneFileSystem),
                                  cancelled: { cancellation.isCancelled },
                                  progress: { n in stats.update { $0.scannedDestination = n } })
            destTree = scanner.scan(root: dst, foldKeys: caseInsensitive)
        } else {
            destTree = Tree(root: dst, foldKeys: caseInsensitive, fsType: dstFS, rootDev: 0)
        }
        group.leave()
    }
    group.wait()
    if cancellation.isCancelled {
        term.stopLive()
        term.log(term.red("✖ INTERRUPTED during scan — nothing was changed."))
        return 130
    }

    // --- Plan ---------------------------------------------------------------------------------
    stats.setPhase(.planning)
    var planOptions = PlanOptions()
    planOptions.compare = opts.compare
    planOptions.mtimeWindow = mtimeWindow
    planOptions.deleteExtraneous = opts.delete
    planOptions.comparePermissions = !limited
    let plan = Planner.plan(source: sourceTree, destination: destTree, options: planOptions)
    term.stopLive()

    for e in sourceTree.errors + destTree.errors { stats.error(e) }

    if !opts.quiet {
        term.log(term.bold("Scanned  ") + "source \(Format.count(sourceTree.count)) items · destination \(Format.count(destTree.count)) items"
                 + term.dim("  (excluded \(Format.count(sourceTree.excludedCount + destTree.excludedCount)))"))
        var parts: [String] = []
        let copies = plan.fileActions.filter { $0.kind == .copy }
        let hashes = plan.fileActions.filter { $0.kind == .hashCompare }
        let metas = plan.fileActions.filter { $0.kind == .updateMeta }
        let links = plan.fileActions.filter { $0.kind == .symlink }
        if !copies.isEmpty { parts.append("copy \(Format.count(copies.count)) files (\(Format.bytes(plan.bytesToCopy)))") }
        if !hashes.isEmpty { parts.append("hash-check \(Format.count(hashes.count)) files (\(Format.bytes(hashes.reduce(0) { $0 + $1.workBytes })))") }
        if !metas.isEmpty { parts.append("metadata \(Format.count(metas.count))") }
        if !links.isEmpty { parts.append("symlinks \(Format.count(links.count))") }
        if !plan.mkdirs.isEmpty { parts.append("mkdir \(Format.count(plan.mkdirs.count))") }
        if plan.deleteCount > 0 { parts.append(term.red("delete \(Format.count(plan.deleteCount)) (\(Format.bytes(plan.deleteBytes)))")) }
        parts.append(term.dim("unchanged \(Format.count(plan.unchangedFiles)) files (\(Format.bytes(plan.unchangedBytes))), \(Format.count(plan.unchangedDirs)) dirs, \(Format.count(plan.unchangedSymlinks)) symlinks"))
        term.log(term.bold("Plan     ") + parts.joined(separator: " · "))
        if plan.typeConflicts > 0 {
            term.log(term.yellow("         \(plan.typeConflicts) path(s) changed type (file/directory/symlink) and will be replaced"))
        }
        if plan.extraneous > 0 {
            term.log(term.yellow("         \(Format.count(plan.extraneous)) item(s) (\(Format.bytes(plan.extraneousBytes))) exist only in the destination — kept; use --delete to remove them"))
        }
        if !plan.skippedSpecial.isEmpty {
            term.log(term.yellow("         \(plan.skippedSpecial.count) special file(s) (sockets/devices/pipes) cannot be copied and are skipped"))
        }
        for e in sourceTree.errors + destTree.errors { term.log(term.red("  scan error: ") + e.description) }
        term.log("")
    }

    // --- Deletion safety gate -----------------------------------------------------------------
    if !opts.dryRun && plan.deleteCount > 0 {
        if !opts.force && destTree.count >= 100 && plan.deleteCount * 4 > destTree.count {
            term.log(term.red("✖ Refusing: ") + "this would delete \(Format.count(plan.deleteCount)) of \(Format.count(destTree.count)) destination items "
                     + "(\(plan.deleteCount * 100 / destTree.count)%). If the source is really that different, re-run with --force.")
            return 1
        }
        if !sourceTree.errors.isEmpty {
            term.log(term.red("✖ Refusing to delete: ") + "the source scan had errors, so 'missing from source' cannot be trusted. Fix the errors or drop --delete.")
            return 1
        }
        if !opts.yes {
            guard isatty(STDIN_FILENO) == 1 else {
                term.log(term.red("✖ ") + "--delete needs confirmation; pass --yes when not running interactively.")
                return 1
            }
            FileHandle.standardError.write("Delete \(Format.count(plan.deleteCount)) item(s) (\(Format.bytes(plan.deleteBytes))) from the destination? [y/N] ".data(using: .utf8)!)
            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                term.log("Aborted; nothing was changed.")
                return 1
            }
        }
    }

    if plan.isEmpty && stats.snapshot.errors.isEmpty {
        // Nothing to do — still report the verdict so the user sees the trust statement.
    }

    // --- Execute ------------------------------------------------------------------------------
    var execOptions = ExecOptions()
    execOptions.dryRun = opts.dryRun
    execOptions.jobs = opts.jobs
    execOptions.verify = opts.verify
    execOptions.fsync = opts.fsync
    execOptions.flushAtEnd = opts.fsync
    // Errors are shown the moment they happen, above the progress block, not just at the end.
    execOptions.onError = { e in term.log(term.red("  error: ") + e.description) }
    let listActions = (opts.verbose || opts.dryRun) && !opts.quiet
    if listActions {
        execOptions.onAction = { action, outcome in
            let tag = outcome.hasPrefix("ERROR") ? term.red(outcome) : term.dim(outcome)
            term.log("  \(action.kind.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(action.relPath)  \(tag)")
        }
    }
    let executor = Executor(plan: plan, source: sourceTree, destination: destTree, options: execOptions, stats: stats, cancellation: cancellation)
    if !opts.quiet { term.startLive { frame.lines() } }
    let completed = executor.run()
    stats.setPhase(completed ? .done : .interrupted)
    term.stopLive()

    // --- Summary & verdict --------------------------------------------------------------------
    let s = stats.snapshot
    let elapsed = Date().timeIntervalSince(s.startedAt)
    if listActions { term.log("") }

    if !opts.quiet {
        var lines: [String] = []
        lines.append("copied \(Format.count(s.filesCopied)) files (\(Format.bytes(s.bytesCopied)))"
                     + (s.filesUpdated > 0 ? ", \(Format.count(s.filesUpdated)) of them replaced older versions" : ""))
        if s.verified > 0 { lines.append("verified \(Format.count(s.verified)) copies by re-reading the destination (SHA-256)") }
        if s.hashedIdentical > 0 { lines.append("\(Format.count(s.hashedIdentical)) files confirmed identical by SHA-256") }
        if plan.unchangedFiles > 0 { lines.append("\(Format.count(plan.unchangedFiles)) files (\(Format.bytes(plan.unchangedBytes))) unchanged by size+mtime — not re-read") }
        if s.metaUpdated > 0 { lines.append("metadata refreshed on \(Format.count(s.metaUpdated)) files") }
        if s.symlinks > 0 { lines.append("\(Format.count(s.symlinks)) symlinks") }
        if s.dirsCreated > 0 { lines.append("\(Format.count(s.dirsCreated)) directories created") }
        if s.deleted > 0 { lines.append("\(Format.count(s.deleted)) items deleted") }
        if plan.extraneous > 0 { lines.append(term.yellow("\(Format.count(plan.extraneous)) extra items remain in the destination (no --delete)")) }
        lines.append("elapsed \(Format.duration(elapsed))" + (s.bytesCopied > 0 && elapsed > 0 ? " · \(Format.rate(Double(s.bytesCopied) / elapsed)) effective" : ""))
        term.log(term.bold("Summary  ") + lines.joined(separator: "\n         "))
    }

    if !s.warnings.isEmpty {
        term.log("")
        for w in s.warnings.prefix(50) { term.log(term.yellow("  warning: ") + w.description) }
        if s.warnings.count > 50 { term.log(term.yellow("  … and \(s.warnings.count - 50) more warnings (see --report)")) }
    }
    if !s.errors.isEmpty {
        term.log("")
        for e in s.errors.prefix(50) { term.log(term.red("  error: ") + e.description) }
        if s.errors.count > 50 { term.log(term.red("  … and \(s.errors.count - 50) more errors (see --report)")) }
    }
    term.log("")

    let verdict: String
    let exitCode: Int32
    if !completed {
        verdict = "INTERRUPTED — NOT SYNCED. \(Format.count(s.actionsDone)) of \(Format.count(s.actionsTotal)) actions were completed; the destination is consistent for those. Run again to finish."
        exitCode = 130
        term.log(term.red(term.bold("✖ " + verdict)))
    } else if !s.errors.isEmpty {
        verdict = "NOT SYNCED — \(s.errors.count) error(s). Everything else was applied; fix the errors above and run again."
        exitCode = 2
        term.log(term.red(term.bold("✖ " + verdict)))
    } else if opts.dryRun {
        verdict = plan.isEmpty ? "DRY RUN — already in sync, nothing would change."
                               : "DRY RUN — \(Format.count(plan.totalActions)) action(s) would be performed. Nothing was changed."
        exitCode = 0
        term.log(term.cyan(term.bold("● " + verdict)))
    } else if !s.warnings.isEmpty {
        verdict = "SYNCED WITH WARNINGS — \(s.warnings.count) file(s) changed while being copied. Run again to capture their latest content."
        exitCode = 3
        term.log(term.yellow(term.bold("▲ " + verdict)))
    } else {
        let basis: String
        if opts.compare == .hash {
            basis = "every file was compared by SHA-256"
        } else if opts.verify {
            basis = "all copies verified by SHA-256; unchanged files matched by size+mtime"
        } else {
            basis = "copies were NOT verified (--no-verify); unchanged files matched by size+mtime"
        }
        verdict = plan.isEmpty && s.filesCopied == 0
            ? "SYNCED — destination already mirrors source (\(basis))."
            : "SYNCED — destination now mirrors source (\(basis))."
        exitCode = 0
        term.log(term.green(term.bold("✔ " + verdict)))
    }

    // --- Report -------------------------------------------------------------------------------
    if let path = opts.reportPath {
        let report = Report(
            tool: "isync", version: Scanner.version, startedAt: s.startedAt, finishedAt: Date(), durationSeconds: elapsed,
            verdict: verdict, exitCode: exitCode,
            settings: .init(source: src, destination: dst, dryRun: opts.dryRun, compare: opts.compare, verify: opts.verify,
                            delete: opts.delete, fsync: opts.fsync, jobs: opts.jobs, mtimeWindow: mtimeWindow,
                            excludes: opts.excludes, sourceFilesystem: srcFS, destinationFilesystem: dstFS, caseInsensitive: caseInsensitive),
            counts: .init(scannedSource: sourceTree.count, scannedDestination: destTree.count,
                          unchangedFiles: plan.unchangedFiles, unchangedBytes: plan.unchangedBytes,
                          unchangedSymlinks: plan.unchangedSymlinks, unchangedDirectories: plan.unchangedDirs,
                          filesCopied: s.filesCopied, bytesCopied: s.bytesCopied, filesUpdated: s.filesUpdated,
                          hashedIdentical: s.hashedIdentical, verified: s.verified, metadataUpdated: s.metaUpdated,
                          symlinks: s.symlinks, directoriesCreated: s.dirsCreated, directoryMetadataSet: s.dirMetaSet,
                          deleted: s.deleted, extraneousLeft: plan.extraneous, typeConflicts: plan.typeConflicts,
                          skippedSpecial: plan.skippedSpecial.count, sourceChangedDuringCopy: s.sourceChangedDuringCopy),
            errors: s.errors, warnings: s.warnings, skippedSpecial: plan.skippedSpecial.map { $0.relPath })
        do { try report.write(to: path); if !opts.quiet { term.log(term.dim("report written to \(path)")) } }
        catch { term.log(term.red("error: ") + "cannot write report: \(error)") }
    }
    return exitCode
}

/// Builds the live status block from a stats snapshot.
final class FrameBuilder {
    let term: Terminal
    let stats: Stats
    let dryRun: Bool
    private let byteMeter = RateMeter()
    private let ioMeter = RateMeter()
    private let actionMeter = RateMeter()
    private var spinnerIndex = 0
    private let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(term: Terminal, stats: Stats, dryRun: Bool) {
        self.term = term; self.stats = stats; self.dryRun = dryRun
    }

    func lines() -> [String] {
        let s = stats.snapshot
        let width = term.width
        spinnerIndex = (spinnerIndex + 1) % spinner.count
        let spin = term.cyan(spinner[spinnerIndex])
        let elapsed = Date().timeIntervalSince(s.startedAt)
        var out: [String] = []

        switch s.phase {
        case .scanning, .planning:
            out.append("\(spin) \(term.bold(s.phase == .scanning ? "Scanning" : "Planning"))   " + term.dim("elapsed \(Format.duration(elapsed))"))
            out.append("  source \(Format.count(s.scannedSource)) items · destination \(Format.count(s.scannedDestination)) items")
        default:
            byteMeter.add(s.workBytesDone)
            ioMeter.add(s.ioBytes)
            actionMeter.add(Int64(s.actionsDone))
            // Big files run first, so bytes finish long before the many small files do.
            // Take the more pessimistic of the two estimates.
            let byteRate = byteMeter.rate, actionRate = actionMeter.rate
            let byteETA = byteRate > 0 ? Double(s.workBytesTotal - s.workBytesDone) / byteRate : 0
            let actionETA = actionRate > 0 ? Double(s.actionsTotal - s.actionsDone) / actionRate : 0
            let eta = max(byteETA, actionETA)
            let phaseName: String
            switch s.phase {
            case .removingConflicts: phaseName = "Removing replaced items"
            case .creatingDirectories: phaseName = "Creating directories"
            case .syncingFiles: phaseName = dryRun ? "Checking files (dry run)" : "Syncing files"
            case .deleting: phaseName = "Deleting extraneous items"
            case .directoryMetadata: phaseName = "Applying directory metadata"
            case .flushing: phaseName = "Flushing destination to disk"
            default: phaseName = s.phase.rawValue
            }
            out.append("\(spin) \(term.bold(phaseName))   " + term.dim("elapsed \(Format.duration(elapsed))")
                       + (s.phase == .syncingFiles && eta > 0 ? term.dim(" · ETA \(Format.duration(eta))") : ""))
            let fraction = s.workBytesTotal > 0 ? Double(s.workBytesDone) / Double(s.workBytesTotal) : (s.actionsTotal > 0 ? Double(s.actionsDone) / Double(s.actionsTotal) : 1)
            let pct = String(format: "%5.1f%%", fraction * 100)
            let right = " \(pct)  \(Format.bytes(s.workBytesDone)) / \(Format.bytes(s.workBytesTotal))  " + term.dim("I/O \(Format.rate(ioMeter.rate))")
            let barWidth = max(10, min(50, width - 52))
            out.append("  " + term.green(Format.bar(fraction: fraction, width: barWidth)) + right)
            var counters = ["actions \(Format.count(s.actionsDone))/\(Format.count(s.actionsTotal))",
                            "copied \(Format.count(s.filesCopied))"]
            if s.verified > 0 { counters.append("verified \(Format.count(s.verified))") }
            if s.hashedIdentical > 0 { counters.append("identical \(Format.count(s.hashedIdentical))") }
            if s.metaUpdated > 0 { counters.append("meta \(Format.count(s.metaUpdated))") }
            if s.deleted > 0 { counters.append("deleted \(Format.count(s.deleted))") }
            counters.append(s.errors.isEmpty ? term.dim("errors 0") : term.red("errors \(s.errors.count)"))
            out.append("  " + counters.joined(separator: " · "))
            for (_, text) in s.current.sorted(by: { $0.key < $1.key }).prefix(3) {
                out.append("  " + term.dim(Format.fit(text, width - 4)))
            }
        }
        return out
    }
}

exit(run())
