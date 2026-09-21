import XCTest
@testable import ISyncCore

/// Runs the real executor on small temporary trees.
final class ExecutorTests: XCTestCase {
    var root: String!
    var src: String { root + "/src" }
    var dst: String { root + "/dst" }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "isync-exec-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func write(_ path: String, _ text: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func makePlan(delete: Bool = true) -> (Plan, Tree, Tree) {
        let scanner = Scanner(options: ScanOptions())
        let s = scanner.scan(root: src, foldKeys: true)
        let d = scanner.scan(root: dst, foldKeys: true)
        var o = PlanOptions()
        o.deleteExtraneous = delete
        return (Planner.plan(source: s, destination: d, options: o), s, d)
    }

    @discardableResult
    func run(_ plan: Plan, _ s: Tree, _ d: Tree, configure: (inout ExecOptions) -> Void = { _ in }) -> (Stats.Snapshot, Bool) {
        var o = ExecOptions()
        o.jobs = 2
        o.flushAtEnd = false
        configure(&o)
        let stats = Stats()
        let ex = Executor(plan: plan, source: s, destination: d, options: o, stats: stats, cancellation: Cancellation())
        let ok = ex.run()
        return (stats.snapshot, ok)
    }

    func testDeletionQuestionIsAskedOnlyAfterCopyingAndDeclineKeepsItems() throws {
        write(src + "/new.txt", "new content")
        write(dst + "/extra.txt", "extra")
        write(dst + "/old-dir/inner.txt", "inner")
        let (plan, s, d) = makePlan()
        XCTAssertEqual(plan.postDeletes.count, 3)

        var askedWhenNewFileExisted: Bool? = nil
        let (snap, ok) = run(plan, s, d) { o in
            o.confirmDeletions = {
                askedWhenNewFileExisted = self.exists(self.dst + "/new.txt")
                return false
            }
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(askedWhenNewFileExisted, true, "the copy must be complete before the question is asked")
        XCTAssertTrue(exists(dst + "/extra.txt"))
        XCTAssertTrue(exists(dst + "/old-dir/inner.txt"))
        XCTAssertEqual(snap.deleted, 0)
        XCTAssertEqual(snap.deletesSkipped, 3)
        XCTAssertEqual(snap.actionsDone, snap.actionsTotal, "skipped deletions still count as handled")
        XCTAssertTrue(snap.errors.isEmpty)
    }

    func testApprovalDeletesExtraneousItemsChildrenFirst() throws {
        write(src + "/keep.txt", "k")
        write(dst + "/keep.txt", "k")
        write(dst + "/extra.txt", "extra")
        write(dst + "/old-dir/deep/inner.txt", "inner")
        let (plan, s, d) = makePlan()
        var asked = 0
        let (snap, ok) = run(plan, s, d) { o in o.confirmDeletions = { asked += 1; return true } }
        XCTAssertTrue(ok)
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(exists(dst + "/extra.txt"))
        XCTAssertFalse(exists(dst + "/old-dir"))
        XCTAssertEqual(snap.deleted, 4)
        XCTAssertEqual(snap.deletesSkipped, 0)
        XCTAssertTrue(snap.errors.isEmpty)
    }

    func testNoQuestionWhenNothingToDeleteOrInDryRun() throws {
        write(src + "/a.txt", "a")
        let (plan1, s1, d1) = makePlan()
        var asked = 0
        run(plan1, s1, d1) { o in o.confirmDeletions = { asked += 1; return true } }
        XCTAssertEqual(asked, 0, "nothing extraneous, nothing to ask")

        write(dst + "/extra.txt", "x")
        let (plan2, s2, d2) = makePlan()
        let (snap, _) = run(plan2, s2, d2) { o in o.dryRun = true; o.confirmDeletions = { asked += 1; return true } }
        XCTAssertEqual(asked, 0, "dry run changes nothing, so there is nothing to confirm")
        XCTAssertTrue(exists(dst + "/extra.txt"))
        XCTAssertEqual(snap.deleted, 1, "dry run still reports what it would have deleted")
    }

    func testWithoutConfirmationHookDeletionsJustHappen() throws {
        write(dst + "/extra.txt", "x")
        let (plan, s, d) = makePlan()
        let (snap, _) = run(plan, s, d)
        XCTAssertFalse(exists(dst + "/extra.txt"))
        XCTAssertEqual(snap.deleted, 1)
    }

    func testCopiedFilesAreVerifiedAndStamped() throws {
        write(src + "/f.txt", "hello")
        chmod(src + "/f.txt", 0o640)
        let (plan, s, d) = makePlan()
        let (snap, ok) = run(plan, s, d)
        XCTAssertTrue(ok)
        XCTAssertEqual(snap.filesCopied, 1)
        XCTAssertEqual(snap.verified, 1)
        var a = stat(), b = stat()
        lstat(src + "/f.txt", &a); lstat(dst + "/f.txt", &b)
        XCTAssertEqual(a.st_mtimespec, b.st_mtimespec)
        XCTAssertEqual(b.st_mode & 0o7777, 0o640)
    }
}
