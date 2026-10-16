import XCTest
@testable import ISyncCore

/// The bulk (`getattrlistbulk`) and portable (`readdir` + `fstatat`) read paths must produce
/// byte-identical trees. If they ever diverge, a "faster" scan would silently change what gets
/// copied — so this is the test that guards the optimisation.
final class ScannerTests: XCTestCase {
    var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "isync-scan-" + UUID().uuidString
        let fm = FileManager.default
        // A tree with every awkward case the scanner must classify.
        try fm.createDirectory(atPath: root + "/a/b/c", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: root + "/a/file.txt"))
        try Data().write(to: URL(fileURLWithPath: root + "/a/zero.bin"))
        try Data(repeating: 7, count: 300_000).write(to: URL(fileURLWithPath: root + "/a/b/big.bin"))
        try Data("ü🙂".utf8).write(to: URL(fileURLWithPath: root + "/a/ünïcödé 🙂.txt"))
        try fm.createSymbolicLink(atPath: root + "/a/link", withDestinationPath: "file.txt")
        try fm.createSymbolicLink(atPath: root + "/a/dangling", withDestinationPath: "/nope/nothing")
        chmod(root + "/a/file.txt", 0o640)
        chmod(root + "/a/b", 0o700)
        var t = [timespec(tv_sec: 1_600_000_000, tv_nsec: 123_456_789),
                 timespec(tv_sec: 1_600_000_000, tv_nsec: 123_456_789)]
        utimensat(AT_FDCWD, root + "/a/file.txt", &t, 0)
        _ = "x".withCString { setxattr(root + "/a/file.txt", "com.example.tag", $0, 1, 0, 0) }
        lchflags(root + "/a/zero.bin", UInt32(UF_HIDDEN))
        mkfifo(root + "/a/fifo", 0o644)
    }

    override func tearDownWithError() throws {
        lchflags(root + "/a/zero.bin", 0)
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Canonical form of a whole tree, for comparison.
    func describe(_ tree: Tree) -> [String] {
        tree.entries.values.map { e in
            "\(e.relPath)|\(e.kind.rawValue)|\(e.size)|\(e.mtime.tv_sec).\(e.mtime.tv_nsec)|\(String(e.mode, radix: 8))|\(e.flags)|\(e.ino)|\(e.linkTarget ?? "")"
        }.sorted()
    }

    func scan(bulk: Bool, options: ScanOptions = ScanOptions()) -> Tree {
        // The scanner reads ISYNC_NO_BULK at init time.
        if bulk { unsetenv("ISYNC_NO_BULK") } else { setenv("ISYNC_NO_BULK", "1", 1) }
        defer { unsetenv("ISYNC_NO_BULK") }
        return Scanner(options: options).scan(root: root, foldKeys: true)
    }

    func testBothReadPathsProduceIdenticalTrees() {
        let fast = scan(bulk: true)
        let slow = scan(bulk: false)
        XCTAssertEqual(fast.count, slow.count, "entry counts differ")
        XCTAssertEqual(describe(fast), describe(slow), "the bulk path and the portable path disagree")
        XCTAssertTrue(fast.errors.isEmpty && slow.errors.isEmpty)
    }

    func testIdenticalWithExclusionsAndSkips() {
        var o = ScanOptions()
        var rules = IgnoreRules()
        rules.add("*.bin")
        rules.add("empty/")
        o.excludes = rules
        o.skipRelPaths = ["a/b/c"]
        let fast = scan(bulk: true, options: o)
        let slow = scan(bulk: false, options: o)
        XCTAssertEqual(describe(fast), describe(slow))
        XCTAssertEqual(fast.excludedCount, slow.excludedCount)
        XCTAssertNil(fast["a/zero.bin"])
        XCTAssertNil(fast["empty"])
        XCTAssertNil(fast["a/b/c"])
    }

    func testClassifiesEveryKindTheSameWay() {
        let t = scan(bulk: true)
        XCTAssertEqual(t["a"]?.kind, .directory)
        XCTAssertEqual(t["a/file.txt"]?.kind, .file)
        XCTAssertEqual(t["a/file.txt"]?.size, 5)
        XCTAssertEqual(t["a/file.txt"]?.mode, 0o640)
        XCTAssertEqual(t["a/file.txt"]?.mtime.tv_sec, 1_600_000_000)
        XCTAssertEqual(t["a/file.txt"]?.mtime.tv_nsec, 123_456_789, "nanosecond precision must survive")
        XCTAssertEqual(t["a/zero.bin"]?.size, 0)
        XCTAssertEqual(t["a/zero.bin"]?.flags, UInt32(UF_HIDDEN))
        XCTAssertEqual(t["a/b/big.bin"]?.size, 300_000)
        XCTAssertEqual(t["a/link"]?.kind, .symlink)
        XCTAssertEqual(t["a/link"]?.linkTarget, "file.txt")
        XCTAssertEqual(t["a/dangling"]?.linkTarget, "/nope/nothing")
        XCTAssertEqual(t["a/fifo"]?.kind, .other)
        XCTAssertEqual(t["a/ünïcödé 🙂.txt"]?.kind, .file)
        XCTAssertEqual(t["a/b"]?.mode, 0o700)
    }

    func testPlansAreIdenticalWhicheverPathScanned() {
        // The real guarantee: the same source and destination produce the same plan either way.
        let dst = NSTemporaryDirectory() + "isync-scan-dst-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dst) }

        func plan(bulk: Bool) -> (Int, Int, Int, Int64) {
            if bulk { unsetenv("ISYNC_NO_BULK") } else { setenv("ISYNC_NO_BULK", "1", 1) }
            defer { unsetenv("ISYNC_NO_BULK") }
            let sc = Scanner(options: ScanOptions())
            let s = sc.scan(root: root, foldKeys: true)
            let d = Scanner(options: ScanOptions()).scan(root: dst, foldKeys: true)
            var o = PlanOptions()
            o.deleteExtraneous = true
            let p = Planner.plan(source: s, destination: d, options: o)
            return (p.fileActions.count, p.mkdirs.count, p.totalActions, p.workBytesTotal)
        }
        XCTAssertEqual("\(plan(bulk: true))", "\(plan(bulk: false))")
    }
}
