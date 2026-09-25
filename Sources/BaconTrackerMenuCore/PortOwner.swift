import Foundation

/// Decides whether a process listening on the app's port is a server this app
/// may replace. Puma renames its process ("puma 8.0.2 (tcp://localhost:4567)
/// [dir]"), so the command line alone cannot say it is a tracker-dashboard.
/// The app records the pid it launched; a listener with that pid that still
/// looks like a Ruby server is ours. Anything else is never touched - not even
/// a tracker-dashboard the user started in a terminal.
public enum PortOwner {
    public static func isOurs(pid: Int32, command: String, recordedPid: Int32?) -> Bool {
        guard let recordedPid, recordedPid == pid else { return false }
        let lower = command.lowercased()
        return lower.hasPrefix("puma") || lower.contains("ruby") || lower.contains("tracker-dashboard")
    }
}

/// The pid of the last server this app started, kept across launches so a
/// server orphaned by a crash can be recognised and replaced.
public struct PidRecord {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func write(_ pid: Int32) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? "\(pid)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
