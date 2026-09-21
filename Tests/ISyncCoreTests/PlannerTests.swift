import XCTest
@testable import ISyncCore

final class PlannerTests: XCTestCase {
    // MARK: fixtures

    func ts(_ sec: Int, _ nsec: Int = 0) -> timespec { timespec(tv_sec: sec, tv_nsec: nsec) }

    func file(_ path: String, size: Int64 = 10, mtime: timespec? = nil, mode: mode_t = 0o644, flags: UInt32 = 0) -> Entry {
        Entry(relPath: path, kind: .file, size: size, mtime: mtime ?? ts(1_000_000), mode: mode, flags: flags,
              dev: 1, ino: 1, nlink: 1, linkTarget: nil)
    }
    func dir(_ path: String, mtime: timespec? = nil, mode: mode_t = 0o755) -> Entry {
        Entry(relPath: path, kind: .directory, size: 0, mtime: mtime ?? ts(1_000_000), mode: mode, flags: 0,
              dev: 1, ino: 1, nlink: 2, linkTarget: nil)
    }
    func link(_ path: String, to target: String) -> Entry {
        Entry(relPath: path, kind: .symlink, size: 0, mtime: ts(1_000_000), mode: 0o755, flags: 0,
              dev: 1, ino: 1, nlink: 1, linkTarget: target)
    }
    func tree(_ entries: [Entry], fold: Bool = false) -> Tree {
        let t = Tree(root: "/x", foldKeys: fold, fsType: "apfs", rootDev: 1)
        for e in entries { t.insert(e) }
        return t
    }
    func plan(_ src: [Entry], _ dst: [Entry], fold: Bool = false, configure: (inout PlanOptions) -> Void = { _ in }) -> Plan {
        var o = PlanOptions()
        configure(&o)
        return Planner.plan(source: tree(src, fold: fold), destination: tree(dst, fold: fold), options: o)
    }
    func kinds(_ actions: [Action]) -> [String: ActionKind] {
        Dictionary(uniqueKeysWithValues: actions.map { ($0.relPath, $0.kind) })
    }

    // MARK: tests

    func testIdenticalTreesProduceNoActions() {
        let entries = [dir("d"), file("d/a"), link("d/l", to: "a")]
        let p = plan(entries, entries)
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.unchangedFiles, 1)
        XCTAssertEqual(p.unchangedDirs, 1)
        XCTAssertEqual(p.unchangedSymlinks, 1)
    }

    func testNewFileIsCopiedAndParentDirGetsMetadata() {
        let p = plan([dir("d"), file("d/a")], [dir("d")])
        XCTAssertEqual(kinds(p.fileActions)["d/a"], .copy)
        XCTAssertEqual(p.dirMeta.map { $0.relPath }, ["d"])
        XCTAssertEqual(p.dirMeta.first?.reason, "contents changed")
    }

    func testSizeChangeCopiesDirectly() {
        let p = plan([file("a", size: 10)], [file("a", size: 11)])
        XCTAssertEqual(p.fileActions.first?.kind, .copy)
        XCTAssertEqual(p.fileActions.first?.reason, "size changed")
    }

    func testMtimeChangeWithSameSizeHashesInsteadOfCopying() {
        let p = plan([file("a", mtime: ts(200))], [file("a", mtime: ts(100))])
        XCTAssertEqual(p.fileActions.first?.kind, .hashCompare)
    }

    func testExactMtimeComparisonByDefaultOnAPFS() {
        // Same second, different nanoseconds: with window 0 this is a change.
        let p = plan([file("a", mtime: ts(100, 500))], [file("a", mtime: ts(100, 400))])
        XCTAssertEqual(p.fileActions.first?.kind, .hashCompare)
    }

    func testMtimeWindowTreatsCloseTimesAsEqual() {
        let p = plan([file("a", mtime: ts(100, 900_000_000))], [file("a", mtime: ts(101, 100_000_000))]) { $0.mtimeWindow = 1 }
        XCTAssertTrue(p.fileActions.isEmpty)
        XCTAssertEqual(p.unchangedFiles, 1)
    }

    func testModeChangeOnlyUpdatesMetadata() {
        let p = plan([file("a", mode: 0o600)], [file("a", mode: 0o644)])
        XCTAssertEqual(p.fileActions.first?.kind, .updateMeta)
    }

    func testPermissionsIgnoredOnLimitedFilesystems() {
        let p = plan([file("a", mode: 0o600)], [file("a", mode: 0o644)]) { $0.comparePermissions = false }
        XCTAssertTrue(p.fileActions.isEmpty)
    }

    func testKernelManagedFlagsAreIgnored() {
        // UF_COMPRESSED on the source (APFS transparent compression) must not cause endless updates.
        let p = plan([file("a", flags: UInt32(UF_COMPRESSED))], [file("a", flags: 0)])
        XCTAssertTrue(p.fileActions.isEmpty)
        let q = plan([file("a", flags: UInt32(UF_HIDDEN))], [file("a", flags: 0)])
        XCTAssertEqual(q.fileActions.first?.kind, .updateMeta)
    }

    func testHashModeHashesEverythingOfEqualSize() {
        let p = plan([file("a"), file("b", size: 5)], [file("a"), file("b", size: 6)]) { $0.compare = .hash }
        XCTAssertEqual(kinds(p.fileActions)["a"], .hashCompare)
        XCTAssertEqual(kinds(p.fileActions)["b"], .copy)
        XCTAssertEqual(p.unchangedFiles, 0)
    }

    func testExtraneousCountedButNotDeletedByDefault() {
        let p = plan([file("a")], [file("a"), file("b", size: 7), dir("e")])
        XCTAssertEqual(p.extraneous, 2)
        XCTAssertEqual(p.extraneousBytes, 7)
        XCTAssertTrue(p.postDeletes.isEmpty)
    }

    func testDeleteOrdersChildrenBeforeParents() {
        let p = plan([], [dir("d"), dir("d/e"), file("d/e/f"), file("d/g")]) { $0.deleteExtraneous = true }
        let paths = p.postDeletes.map { $0.relPath }
        XCTAssertEqual(paths.count, 4)
        XCTAssertLessThan(paths.firstIndex(of: "d/e/f")!, paths.firstIndex(of: "d/e")!)
        XCTAssertLessThan(paths.firstIndex(of: "d/e")!, paths.firstIndex(of: "d")!)
        XCTAssertLessThan(paths.firstIndex(of: "d/g")!, paths.firstIndex(of: "d")!)
    }

    func testFileReplacingDirectoryRemovesSubtreeFirstEvenWithoutDelete() {
        let p = plan([file("x")], [dir("x"), file("x/inner"), dir("x/sub"), file("x/sub/deep")])
        XCTAssertEqual(p.typeConflicts, 1)
        let pre = p.preDeletes.map { $0.relPath }
        XCTAssertEqual(Set(pre), ["x", "x/inner", "x/sub", "x/sub/deep"])
        XCTAssertEqual(pre.last, "x", "the directory itself must go last")
        XCTAssertLessThan(pre.firstIndex(of: "x/sub/deep")!, pre.firstIndex(of: "x/sub")!)
        XCTAssertEqual(kinds(p.fileActions)["x"], .copy)
        XCTAssertEqual(p.extraneous, 0, "subtree members are not double-counted as extraneous")
    }

    func testDirectoryReplacingFile() {
        let p = plan([dir("x"), file("x/a")], [file("x")])
        XCTAssertEqual(p.preDeletes.map { $0.relPath }, ["x"])
        XCTAssertEqual(p.mkdirs.map { $0.relPath }, ["x"])
        XCTAssertEqual(kinds(p.fileActions)["x/a"], .copy)
    }

    func testSymlinkTargetChange() {
        let p = plan([link("l", to: "b")], [link("l", to: "a")])
        XCTAssertEqual(p.fileActions.first?.kind, .symlink)
        XCTAssertEqual(p.fileActions.first?.reason, "target changed")
    }

    func testMkdirsShallowFirst() {
        let p = plan([dir("a/b/c"), dir("a"), dir("a/b")], [])
        XCTAssertEqual(p.mkdirs.map { $0.relPath }, ["a", "a/b", "a/b/c"])
        XCTAssertEqual(p.dirMeta.map { $0.relPath }, ["a/b/c", "a/b", "a"], "metadata deepest first")
    }

    func testCaseFoldingMatchesAcrossCaseOnInsensitiveVolumes() {
        let p = plan([file("Readme.MD")], [file("readme.md")], fold: true)
        XCTAssertTrue(p.isEmpty, "same file on a case-insensitive volume; no phantom copy+delete")
        let q = plan([file("Readme.MD")], [file("readme.md")], fold: false)
        XCTAssertEqual(q.fileActions.count, 1)
        XCTAssertEqual(q.extraneous, 1)
    }

    func testUnicodeNormalizationFolds() {
        let nfc = "caf\u{00E9}.txt"
        let nfd = "cafe\u{0301}.txt"
        XCTAssertEqual(Tree.fold(nfc), Tree.fold(nfd))
    }

    func testSpecialFilesAreSkippedNotCopied() {
        let fifo = Entry(relPath: "p", kind: .other, size: 0, mtime: ts(1), mode: 0o644, flags: 0, dev: 1, ino: 1, nlink: 1, linkTarget: nil)
        let p = plan([fifo], [])
        XCTAssertTrue(p.fileActions.isEmpty)
        XCTAssertEqual(p.skippedSpecial.map { $0.relPath }, ["p"])
    }

    func testBigFilesScheduledFirst() {
        let p = plan([file("small", size: 1), file("big", size: 1000), file("mid", size: 50)], [])
        XCTAssertEqual(p.fileActions.map { $0.relPath }, ["big", "mid", "small"])
        XCTAssertEqual(p.workBytesTotal, 1051)
    }

    func testIgnoreRules() {
        var r = IgnoreRules(patterns: [".DS_Store", "*.tmp", "Library/Caches/*", "build/", "/top-only"])
        XCTAssertTrue(r.matches(relPath: "a/b/.DS_Store", name: ".DS_Store", isDirectory: false))
        XCTAssertTrue(r.matches(relPath: "x/y.tmp", name: "y.tmp", isDirectory: false))
        XCTAssertTrue(r.matches(relPath: "Library/Caches/foo", name: "foo", isDirectory: true))
        XCTAssertFalse(r.matches(relPath: "Other/Library/Caches/foo", name: "foo", isDirectory: true), "path patterns are root-anchored")
        XCTAssertTrue(r.matches(relPath: "src/build", name: "build", isDirectory: true))
        XCTAssertFalse(r.matches(relPath: "src/build", name: "build", isDirectory: false), "trailing slash means directories only")
        XCTAssertTrue(r.matches(relPath: "top-only", name: "top-only", isDirectory: false))
        r.add("# a comment")
        r.add("   ")
        XCTAssertEqual(r.count, 5)
    }
}
