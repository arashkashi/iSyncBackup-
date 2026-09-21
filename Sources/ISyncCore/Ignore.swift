import Foundation

/// Exclusion rules. Patterns use shell glob syntax (`fnmatch(3)`):
///   - A pattern without "/" matches the file/directory *name* anywhere in the tree (`*.tmp`, `.DS_Store`).
///   - A pattern containing "/" matches the full path relative to the root (`Library/Caches/*`).
///     A leading "/" is stripped; it just documents that the pattern is root-anchored.
///   - A trailing "/" restricts the pattern to directories.
/// Excluding a directory excludes its whole subtree.
public struct IgnoreRules {
    /// macOS volume housekeeping that should never be part of a backup.
    public static let defaultPatterns: [String] = [
        ".DS_Store",
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        ".PKInstallSandboxManager",
        ".PKInstallSandboxManager-SystemSoftware",
        ".com.apple.timemachine.donotpresent",
        ".MobileBackups",
    ]

    /// Our own temp/state names. Always excluded so a crashed run's leftovers are never mirrored.
    public static let internalPatterns: [String] = [
        ".isync-tmp-*",
        ".isync",
    ]

    struct Rule {
        let pattern: String
        let fullPath: Bool
        let dirOnly: Bool
    }

    private var rules: [Rule] = []

    public init(patterns: [String] = []) {
        for p in patterns { add(p) }
    }

    public mutating func add(_ raw: String) {
        var p = raw.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !p.hasPrefix("#") else { return }
        var dirOnly = false
        if p.hasSuffix("/") { dirOnly = true; p.removeLast() }
        if p.hasPrefix("/") { p.removeFirst() }
        guard !p.isEmpty else { return }
        rules.append(Rule(pattern: p, fullPath: p.contains("/"), dirOnly: dirOnly))
    }

    public mutating func add(contentsOf patterns: [String]) {
        for p in patterns { add(p) }
    }

    /// Load a `.isyncignore`-style file: one pattern per line, `#` comments, blank lines ignored.
    public mutating func load(file path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            add(String(line))
        }
    }

    public var isEmpty: Bool { rules.isEmpty }
    public var count: Int { rules.count }

    public func matches(relPath: String, name: String, isDirectory: Bool) -> Bool {
        for r in rules {
            if r.dirOnly && !isDirectory { continue }
            let subject = r.fullPath ? relPath : name
            if fnmatch(r.pattern, subject, 0) == 0 { return true }
        }
        return false
    }
}
