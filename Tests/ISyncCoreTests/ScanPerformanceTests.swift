import XCTest
@testable import ISyncCore

/// Measures the scanner against the implementation isync shipped before the optimisation work
/// (`readdir` + `fstatat`, one directory at a time) and prints the speedup.
///
/// This runs on a freshly written tree, so the metadata is in the page cache: it measures the
/// syscall and CPU cost only. On a real volume — where metadata has to be fetched — the gain is
/// larger, because the parallel workers also overlap the waiting. Run with:
///
///     swift test --filter ScanPerformanceTests
///
final class ScanPerformanceTests: XCTestCase {
    static var root: String!
    static var entryCount = 0

    /// One tree, built once, reused by every measurement so they are comparable.
    override class func setUp() {
        root = NSTemporaryDirectory() + "isync-perf-" + UUID().uuidString
        let fm = FileManager.default
        // ~11k entries shaped like a real project tree: wide at the top, deep in places.
        for a in 0..<20 {
            for b in 0..<10 {
                for c in 0..<2 {
                    let dir = root + "/top\(a)/mid\(b)/leaf\(c)"
                    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    for d in 0..<24 {
                        try? Data(repeating: UInt8(d), count: 64).write(to: URL(fileURLWithPath: dir + "/f\(d).bin"))
                    }
                    try? fm.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "f0.bin")
                }
            }
        }
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Best of `runs` — the minimum is the least noisy estimate of real cost.
    func time(bulk: Bool, jobs: Int, runs: Int = 5) -> (seconds: Double, entries: Int) {
        var best = Double.infinity
        var count = 0
        for _ in 0..<runs {
            if bulk { unsetenv("ISYNC_NO_BULK") } else { setenv("ISYNC_NO_BULK", "1", 1) }
            var o = ScanOptions()
            o.jobs = jobs
            let scanner = Scanner(options: o)
            let t0 = Date()
            let tree = scanner.scan(root: Self.root, foldKeys: true)
            best = min(best, Date().timeIntervalSince(t0))
            count = tree.count
            unsetenv("ISYNC_NO_BULK")
        }
        return (best, count)
    }

    func testScanSpeedupOverThePreviousImplementation() {
        let before = time(bulk: false, jobs: 1)   // what isync did before this work
        let bulkOnly = time(bulk: true, jobs: 1)  // + getattrlistbulk
        let after = time(bulk: true, jobs: 8)     // + parallel directory reads
        Self.entryCount = before.entries

        XCTAssertEqual(bulkOnly.entries, before.entries)
        XCTAssertEqual(after.entries, before.entries)

        // Note: never use %s here — it expects a C string, and handing it a Swift String
        // reads past the end of memory. Pad the label in Swift instead.
        func row(_ label: String, _ r: (seconds: Double, entries: Int)) -> String {
            let padded = label.padding(toLength: max(label.count, 46), withPad: " ", startingAt: 0)
            return padded + String(format: "%7.1f ms  %9.0f entries/s  %5.2fx",
                                   r.seconds * 1000, Double(r.entries) / r.seconds, before.seconds / r.seconds)
        }
        print("""

        Scan of \(before.entries) entries — best of 5, warm page cache
        \(row("before  (readdir+fstatat, 1 directory at a time)", before))
        \(row("+ getattrlistbulk", bulkOnly))
        \(row("+ parallel directory reads (--scan-jobs 8)", after))

        """)

        // Guard against regression. Deliberately loose: CI machines are noisy, and the point is
        // to catch a real reversal, not a few percent of jitter.
        XCTAssertLessThan(after.seconds, before.seconds,
                          "the optimised scan is no longer faster than the original implementation")
        XCTAssertGreaterThan(before.seconds / after.seconds, 1.5,
                             "expected at least 1.5x; got \(String(format: "%.2f", before.seconds / after.seconds))x")
    }

    func testParallelScalingIsReported() {
        let serial = time(bulk: true, jobs: 1)
        var lines: [String] = []
        for jobs in [1, 2, 4, 8] {
            let r = time(bulk: true, jobs: jobs)
            XCTAssertEqual(r.entries, serial.entries, "jobs=\(jobs) scanned a different number of entries")
            lines.append("  --scan-jobs \(jobs)" + String(repeating: " ", count: 4 - String(jobs).count)
                         + String(format: "%7.1f ms  %5.2fx", r.seconds * 1000, serial.seconds / r.seconds))
        }
        print("\nParallel scaling, \(serial.entries) entries:\n" + lines.joined(separator: "\n") + "\n")
    }
}
