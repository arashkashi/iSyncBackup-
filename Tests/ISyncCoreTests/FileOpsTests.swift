import XCTest
import CryptoKit
@testable import ISyncCore

final class FileOpsTests: XCTestCase {
    var dir: String!
    var buffer: UnsafeMutableRawPointer!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "isync-fileops-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        buffer = UnsafeMutableRawPointer.allocate(byteCount: FileOps.chunkSize, alignment: 4096)
    }

    override func tearDownWithError() throws {
        buffer.deallocate()
        try? FileManager.default.removeItem(atPath: dir)
    }

    func write(_ name: String, _ bytes: [UInt8]) -> String {
        let p = dir + "/" + name
        FileManager.default.createFile(atPath: p, contents: Data(bytes))
        return p
    }

    func scanned(_ path: String) -> Entry {
        var st = stat()
        lstat(path, &st)
        return Entry(relPath: (path as NSString).lastPathComponent, kind: .file, size: Int64(st.st_size), mtime: st.st_mtimespec,
                     mode: st.st_mode & 0o7777, flags: st.st_flags, dev: st.st_dev, ino: st.st_ino, nlink: st.st_nlink, linkTarget: nil)
    }

    func mtime(_ path: String) -> timespec { var st = stat(); lstat(path, &st); return st.st_mtimespec }
    func mode(_ path: String) -> mode_t { var st = stat(); lstat(path, &st); return st.st_mode & 0o7777 }

    func testCopyThenFinalizeReproducesContentAndMetadata() throws {
        let payload = (0..<(5 * 1024 * 1024 + 123)).map { UInt8(truncatingIfNeeded: $0 &* 31) } // > one chunk
        let src = write("src.bin", payload)
        chmod(src, 0o640)
        var t = [timespec(tv_sec: 1_600_000_000, tv_nsec: 123_456_789), timespec(tv_sec: 1_600_000_000, tv_nsec: 123_456_789)]
        utimensat(AT_FDCWD, src, &t, 0)
        let entry = scanned(src)
        let dst = dir + "/dst.bin"

        let (digest, bytes) = try FileOps.copyData(from: src, to: dst, existing: nil, buffer: buffer, cancelled: { false }) { _, _ in }
        XCTAssertEqual(bytes, Int64(payload.count))
        XCTAssertEqual(digest, SHA256.hash(data: Data(payload)))
        // Between the passes the file is complete but deliberately NOT stamped: fresh mtime, 0600.
        XCTAssertNotEqual(mtime(dst), entry.mtime)
        XCTAssertEqual(mode(dst), 0o600)

        let r = try FileOps.finalizeCopy(src: src, dst: dst, entry: entry, expected: digest, expectedBytes: bytes,
                                         verify: true, fsync: true, buffer: buffer, cancelled: { false }) { _ in }
        XCTAssertTrue(r.verified)
        XCTAssertFalse(r.sourceChanged)
        XCTAssertEqual(mtime(dst), entry.mtime, "nanosecond-exact mtime")
        XCTAssertEqual(mode(dst), 0o640)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dst)), Data(payload))
    }

    func testVerificationFailureRemovesDestination() throws {
        let src = write("s", Array("hello world".utf8))
        let entry = scanned(src)
        let dst = dir + "/d"
        let (digest, bytes) = try FileOps.copyData(from: src, to: dst, existing: nil, buffer: buffer, cancelled: { false }) { _, _ in }
        // Simulate the drive returning wrong bytes.
        try Data("hello wor1d".utf8).write(to: URL(fileURLWithPath: dst))
        XCTAssertThrowsError(try FileOps.finalizeCopy(src: src, dst: dst, entry: entry, expected: digest, expectedBytes: bytes,
                                                      verify: true, fsync: false, buffer: buffer, cancelled: { false }) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst), "a copy that failed verification must not survive")
    }

    func testSourceChangedMidRunIsReportedAndScannedMtimeIsStamped() throws {
        let src = write("s", Array("version one".utf8))
        let entry = scanned(src)
        let dst = dir + "/d"
        let (digest, bytes) = try FileOps.copyData(from: src, to: dst, existing: nil, buffer: buffer, cancelled: { false }) { _, _ in }

        // Source changes after it was copied but before the finalize pass, same size, new mtime.
        try Data("version two".utf8).write(to: URL(fileURLWithPath: src))
        var later = [timespec(tv_sec: entry.mtime.tv_sec + 100, tv_nsec: 0), timespec(tv_sec: entry.mtime.tv_sec + 100, tv_nsec: 0)]
        utimensat(AT_FDCWD, src, &later, 0)

        let r = try FileOps.finalizeCopy(src: src, dst: dst, entry: entry, expected: digest, expectedBytes: bytes,
                                         verify: true, fsync: false, buffer: buffer, cancelled: { false }) { _ in }
        XCTAssertTrue(r.sourceChanged)
        XCTAssertEqual(mtime(dst), entry.mtime, "destination carries the mtime of the content it actually holds")
        XCTAssertNotEqual(mtime(dst), mtime(src), "so the next run sees a mismatch and re-checks it")
        XCTAssertEqual(try String(contentsOfFile: dst), "version one")
    }

    func testCopyDataReplacesExistingAtomicallyAndLeavesNoTemp() throws {
        let src = write("s", Array("new".utf8))
        let dst = write("d", Array("old".utf8))
        let existing = scanned(dst)
        _ = try FileOps.copyData(from: src, to: dst, existing: existing, buffer: buffer, cancelled: { false }) { _, _ in }
        XCTAssertEqual(try String(contentsOfFile: dst), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix(".isync-tmp-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testCancellationLeavesOldFileAndNoTemp() throws {
        let src = write("s", [UInt8](repeating: 7, count: 3 * FileOps.chunkSize))
        let dst = write("d", Array("old".utf8))
        var calls = 0
        XCTAssertThrowsError(try FileOps.copyData(from: src, to: dst, existing: nil, buffer: buffer,
                                                  cancelled: { calls += 1; return calls > 1 }) { _, _ in }) { error in
            XCTAssertTrue(error is CancelledError)
        }
        XCTAssertEqual(try String(contentsOfFile: dst), "old", "old content untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix(".isync-tmp-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMissingSourceIsAnError() {
        XCTAssertThrowsError(try FileOps.copyData(from: dir + "/nope", to: dir + "/d", existing: nil, buffer: buffer, cancelled: { false }) { _, _ in })
    }
}
