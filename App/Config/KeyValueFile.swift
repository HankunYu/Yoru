import Foundation

/// A `key=value` config file (mpv.conf, script-opts) that can be edited one option at a
/// time. Only the lines for the keys that are set are rewritten; comments, ordering,
/// unknown options and profile sections are preserved exactly.
struct KeyValueFile {
    let url: URL
    private var lines: [String]

    init(url: URL) {
        self.url = url
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The top-level value of `key`, or nil if the file does not set it. A bare `key`
    /// reads as "yes" and `no-key` as "no", as in mpv.conf.
    func value(for key: String) -> String? {
        var result: String?
        for index in topLevelRange {
            guard let entry = Self.parse(lines[index]) else { continue }
            if entry.key == key {
                result = entry.value
            } else if entry.key == "no-\(key)", entry.isBare {
                result = "no"
            }
        }
        return result
    }

    /// Sets `key` at the top level, replacing its existing line or adding one. Passing nil
    /// removes the option so the built-in default applies.
    mutating func set(_ key: String, to value: String?) {
        let matches = topLevelRange.filter { index in
            guard let entry = Self.parse(lines[index]) else { return false }
            return entry.key == key || (entry.key == "no-\(key)" && entry.isBare)
        }
        // Later lines win in mpv, so the last one is the effective one; drop the rest.
        for index in matches.dropLast().reversed() {
            lines.remove(at: index)
        }
        let target = matches.last.map { $0 - (matches.count - 1) }
        switch (target, value) {
        case (let index?, let value?):
            lines[index] = "\(key)=\(value)"
        case (let index?, nil):
            lines.remove(at: index)
        case (nil, let value?):
            insertTopLevel("\(key)=\(value)")
        case (nil, nil):
            break
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("Saving \(url.lastPathComponent, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Private

    /// Lines before the first `[profile]` header; options after it belong to a profile.
    private var topLevelRange: Range<Int> {
        let end = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        return 0..<end
    }

    private mutating func insertTopLevel(_ line: String) {
        var index = topLevelRange.upperBound
        // Keep blank lines that separate the top level from the first profile below the new line.
        while index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            index -= 1
        }
        lines.insert(line, at: index)
    }

    private static func parse(_ line: String) -> (key: String, value: String, isBare: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[") else { return nil }
        guard let separator = trimmed.firstIndex(of: "=") else {
            return (trimmed, "yes", true)
        }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        var value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value, false)
    }
}
