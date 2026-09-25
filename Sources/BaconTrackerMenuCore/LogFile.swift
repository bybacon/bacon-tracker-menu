import Foundation

/// The server log: one current file plus one previous generation, so it can
/// never grow without bound.
public enum LogFile {
    public static let maxBytes = 1_000_000

    /// Moves the log aside to `<path>.1` once it passes `maxBytes`.
    public static func rotateIfNeeded(path: String, maxBytes: Int = maxBytes) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes else { return }
        let previous = path + ".1"
        try? fm.removeItem(atPath: previous)
        try? fm.moveItem(atPath: path, toPath: previous)
    }

    /// The last non-empty line, for an error message. Reads only the tail.
    public static func lastLine(path: String, tailBytes: UInt64 = 4096) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let end = handle.seekToEndOfFile()
        handle.seek(toFileOffset: end > tailBytes ? end - tailBytes : 0)
        let data = handle.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
            .map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 }
    }
}
