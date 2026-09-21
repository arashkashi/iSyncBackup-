import Foundation

/// Minimal ANSI terminal driver: a redrawn live status block at the bottom, with ordinary log
/// lines scrolling above it. Writes to stderr so stdout stays clean for piping. Falls back to
/// plain line output when stderr is not a TTY.
final class Terminal {
    let isTTY: Bool
    let color: Bool
    private let lock = NSLock()
    private var liveLines = 0
    private var timer: DispatchSourceTimer?
    private var renderer: (() -> [String])?
    private let queue = DispatchQueue(label: "isync.terminal")

    init(color: Bool) {
        isTTY = isatty(STDERR_FILENO) == 1
        self.color = color && isTTY
    }

    var width: Int {
        var ws = winsize()
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
        return 80
    }

    private func raw(_ s: String) {
        FileHandle.standardError.write(s.data(using: .utf8)!)
    }

    /// Print a permanent line (above the live block if one is showing).
    func log(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if liveLines > 0 {
            raw("\u{1B}[\(liveLines)A\u{1B}[0J" + line + "\n")
            liveLines = 0
            if let r = renderer { drawLocked(r()) }
        } else {
            raw(line + "\n")
        }
    }

    func startLive(_ render: @escaping () -> [String]) {
        guard isTTY else { return }
        lock.lock()
        renderer = render
        raw("\u{1B}[?25l") // hide cursor
        lock.unlock()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.frame() }
        t.resume()
        timer = t
    }

    private func frame() {
        lock.lock(); defer { lock.unlock() }
        guard let r = renderer else { return }
        drawLocked(r())
    }

    private func drawLocked(_ lines: [String]) {
        var s = ""
        if liveLines > 0 { s += "\u{1B}[\(liveLines)A" }
        s += "\u{1B}[0J"
        for l in lines { s += l + "\n" }
        raw(s)
        liveLines = lines.count
    }

    /// Stop redrawing and erase the live block.
    func stopLive() {
        timer?.cancel()
        timer = nil
        lock.lock(); defer { lock.unlock() }
        renderer = nil
        if liveLines > 0 {
            raw("\u{1B}[\(liveLines)A\u{1B}[0J")
            liveLines = 0
        }
        if isTTY { raw("\u{1B}[?25h") } // show cursor
    }

    // MARK: styling

    private func wrap(_ s: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    func bold(_ s: String) -> String { wrap(s, "1") }
    func dim(_ s: String) -> String { wrap(s, "2") }
    func green(_ s: String) -> String { wrap(s, "32") }
    func red(_ s: String) -> String { wrap(s, "31") }
    func yellow(_ s: String) -> String { wrap(s, "33") }
    func cyan(_ s: String) -> String { wrap(s, "36") }
}

enum Format {
    static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f
    }()

    static func count(_ n: Int) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func bytes(_ b: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(b)
        var u = 0
        while v >= 1000 && u < units.count - 1 { v /= 1000; u += 1 }
        return u == 0 ? "\(b) B" : String(format: v < 10 ? "%.2f %@" : (v < 100 ? "%.1f %@" : "%.0f %@"), v, units[u])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond > 0 ? bytes(Int64(bytesPerSecond)) + "/s" : "—"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Shorten a path in the middle so it fits in `width` columns.
    static func fit(_ s: String, _ width: Int) -> String {
        guard width > 5 else { return "" }
        let chars = Array(s)
        if chars.count <= width { return s }
        let keep = width - 1
        let head = keep / 2
        let tail = keep - head
        return String(chars[0..<head]) + "…" + String(chars[(chars.count - tail)...])
    }

    static func bar(fraction: Double, width: Int) -> String {
        let w = max(4, width)
        let f = min(1, max(0, fraction.isFinite ? fraction : 0))
        let filled = Int((Double(w) * f).rounded(.down))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: w - filled)
    }
}

/// Throughput over a sliding window.
final class RateMeter {
    private var samples: [(t: Double, v: Int64)] = []
    private let window: Double
    init(window: Double = 5) { self.window = window }

    func add(_ v: Int64) {
        let now = Date().timeIntervalSinceReferenceDate
        samples.append((now, v))
        while samples.count > 2, now - samples[0].t > window { samples.removeFirst() }
    }

    var rate: Double {
        guard let first = samples.first, let last = samples.last, last.t > first.t else { return 0 }
        return Double(last.v - first.v) / (last.t - first.t)
    }
}
