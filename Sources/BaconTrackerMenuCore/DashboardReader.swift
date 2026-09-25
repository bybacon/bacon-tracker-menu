import Foundation

public struct ProjectInfo: Equatable {
    public let name: String
    public let slug: String
    public let namespace: String
    public let nextTask: String?
    public let started: Int
    public let done: Int
    public let backlog: Int
    public let icebox: Int
    /// False for a docs-only project: it has no board, so it opens on its docs.
    public let hasTracker: Bool

    public init(name: String, slug: String, namespace: String, nextTask: String?,
                started: Int = 0, done: Int = 0, backlog: Int = 0, icebox: Int = 0,
                hasTracker: Bool = true) {
        self.name = name
        self.slug = slug
        self.namespace = namespace
        self.nextTask = nextTask
        self.started = started
        self.done = done
        self.backlog = backlog
        self.icebox = icebox
        self.hasTracker = hasTracker
    }

    /// Board path on the dashboard server, or the docs surface when there is no tracker.
    public var urlPath: String {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return hasTracker ? "/projects/\(encoded)" : "/projects/\(encoded)/docs"
    }
}

/// Reads dashboard.md directly - the fallback the menu shows before the
/// server answers /api/stats. Mirrors bacon-tracker's Dashboard parser:
/// `path:` is the project directory, `tracker:` optionally overrides where the
/// stories live, and the older form where `path:` points at the tracker
/// directory itself is still recognised.
public struct DashboardReader {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func load() -> [ProjectInfo] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var entries: [(name: String, attrs: [String: String])] = []
        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                entries.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [:]))
            } else if !entries.isEmpty, let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                // Keys are single words, as in the Ruby parser - prose with a colon is not an attribute.
                if !val.isEmpty, key.range(of: #"^\w+$"#, options: .regularExpression) != nil {
                    entries[entries.count - 1].attrs[key] = val
                }
            }
        }

        var seen: [String: Int] = [:]
        return entries.compactMap { entry -> ProjectInfo? in
            guard entry.attrs["path"] != nil else { return nil }
            var info = build(name: entry.name, attrs: entry.attrs)
            guard !info.namespace.isEmpty else { return nil }
            // The server suffixes colliding slugs the same way, so a fallback
            // link still reaches the right board.
            let n = (seen[info.slug] ?? 0) + 1
            seen[info.slug] = n
            if n > 1 {
                info = ProjectInfo(name: info.name, slug: "\(info.slug)-\(n)", namespace: info.namespace,
                                   nextTask: info.nextTask, hasTracker: info.hasTracker)
            }
            return info
        }
    }

    private func build(name: String, attrs: [String: String]) -> ProjectInfo {
        let base = (path as NSString).deletingLastPathComponent
        let projectPath = resolve(attrs["path"] ?? "", relativeTo: base)
        let trackerRoot = trackerRoot(projectPath: projectPath, override: attrs["tracker"])
        let slug = DashboardReader.slug(from: name)
        let ns = attrs["namespace"] ?? slug.uppercased().replacingOccurrences(of: "-", with: "_")
        let hasTracker = FileManager.default.fileExists(atPath: trackerRoot)
        return ProjectInfo(name: name, slug: slug, namespace: ns,
                           nextTask: DashboardReader.nextTask(trackerRoot: trackerRoot, namespace: ns),
                           hasTracker: hasTracker)
    }

    /// Same precedence as the gem: an explicit `tracker:` wins; a `path:` that
    /// already holds backlog.md or .next-id IS the tracker (the older form);
    /// otherwise the tracker is `<path>/tracker`.
    func trackerRoot(projectPath: String, override: String?) -> String {
        if let override { return resolve(override, relativeTo: projectPath) }
        let fm = FileManager.default
        let legacy = ["backlog.md", ".next-id"].contains {
            fm.fileExists(atPath: (projectPath as NSString).appendingPathComponent($0))
        }
        return legacy ? projectPath : (projectPath as NSString).appendingPathComponent("tracker")
    }

    private func resolve(_ value: String, relativeTo base: String) -> String {
        let expanded = (value as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
        return (full as NSString).standardizingPath
    }

    public static func slug(from name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The first backlog entry ("- NS-001 title"), title only.
    static func nextTask(trackerRoot: String, namespace: String) -> String? {
        let backlogPath = (trackerRoot as NSString).appendingPathComponent("backlog.md")
        guard let content = try? String(contentsOfFile: backlogPath, encoding: .utf8) else { return nil }
        let pattern = "^\\s*-\\s+\(NSRegularExpression.escapedPattern(for: namespace))-\\d+\\s+"
        guard let line = content.components(separatedBy: .newlines)
            .first(where: { $0.range(of: pattern, options: .regularExpression) != nil })
        else { return nil }
        let title = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
