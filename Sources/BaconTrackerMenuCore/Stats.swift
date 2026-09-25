import Foundation

/// Parses GET /api/stats from tracker-dashboard. Tolerant of older servers:
/// a missing `tracker` flag means the project has a board.
public enum Stats {
    public static func parse(_ data: Data) -> [ProjectInfo]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return json.compactMap { dict -> ProjectInfo? in
            guard let name = dict["name"] as? String,
                  let ns = dict["namespace"] as? String else { return nil }
            return ProjectInfo(
                name: name,
                slug: dict["slug"] as? String ?? DashboardReader.slug(from: name),
                namespace: ns,
                nextTask: (dict["next_task"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                started: dict["started"] as? Int ?? 0,
                done: dict["done"] as? Int ?? 0,
                backlog: dict["backlog"] as? Int ?? 0,
                icebox: dict["icebox"] as? Int ?? 0,
                hasTracker: dict["tracker"] as? Bool ?? true
            )
        }
    }
}
