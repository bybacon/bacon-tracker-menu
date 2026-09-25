import XCTest
@testable import BaconTrackerMenuCore

final class LaunchTests: XCTestCase {
    func testGemInstallRunsTrackerDashboardFromThePath() {
        let plan = Launch.plan(script: nil, dashboard: "/d/dash board.md", port: 4567, shell: "/bin/zsh",
                               fileExists: { _ in false })
        XCTAssertEqual(plan.shell, "/bin/zsh")
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["-i", "-l", "-c"])
        XCTAssertTrue(plan.arguments[3].hasPrefix("exec tracker-dashboard"))
        // Paths travel as positional parameters, never inside the command string.
        XCTAssertFalse(plan.arguments[3].contains("dash board"))
        XCTAssertEqual(Array(plan.arguments.suffix(4)), ["", "/d/dash board.md", "4567", ""])
    }

    func testCheckoutScriptRunsThroughBundlerFromTheCheckout() {
        let plan = Launch.plan(script: "/src/bacon-tracker/bin/tracker-dashboard", dashboard: "/d.md", port: 4600,
                               shell: "/bin/zsh", fileExists: { $0 == "/src/bacon-tracker/Gemfile" })
        XCTAssertTrue(plan.arguments[3].contains("exec bundle exec ruby"))
        XCTAssertEqual(plan.arguments.last, "/src/bacon-tracker")
    }

    func testAnyOtherScriptRunsAsIs() {
        let plan = Launch.plan(script: "/opt/bin/tracker-dashboard", dashboard: "/d.md", port: 4567,
                               shell: "/bin/bash", fileExists: { _ in false })
        XCTAssertTrue(plan.arguments[3].hasPrefix(#"exec "$1""#))
        XCTAssertEqual(plan.arguments[5], "/opt/bin/tracker-dashboard")
    }

    func testShellIsTheUsersZshOrBashElseZsh() {
        XCTAssertEqual(Launch.shell(environment: ["SHELL": "/opt/homebrew/bin/bash"], isExecutable: { _ in true }),
                       "/opt/homebrew/bin/bash")
        XCTAssertEqual(Launch.shell(environment: ["SHELL": "/usr/local/bin/fish"], isExecutable: { _ in true }),
                       "/bin/zsh")
        XCTAssertEqual(Launch.shell(environment: [:]), "/bin/zsh")
    }

    func testExitReasonsNameTheCause() {
        XCTAssertTrue(Launch.exitReason(status: 127, lastLogLine: nil, usingPath: true).contains("gem install bacon-tracker"))
        XCTAssertEqual(Launch.exitReason(status: 1, lastLogLine: "Could not locate Gemfile", usingPath: false),
                       "Server exited (status 1): Could not locate Gemfile")
    }
}

final class PortOwnerTests: XCTestCase {
    func testRecognisesItsOwnRenamedPumaByRecordedPid() {
        let puma = "puma 8.0.2 (tcp://localhost:4567) [bacon-tracker]"
        XCTAssertTrue(PortOwner.isOurs(pid: 42, command: puma, recordedPid: 42))
        XCTAssertFalse(PortOwner.isOurs(pid: 42, command: puma, recordedPid: 7))
        XCTAssertFalse(PortOwner.isOurs(pid: 42, command: puma, recordedPid: nil))
    }

    func testNeverClaimsAnUnrelatedProcessEvenWithAReusedPid() {
        XCTAssertFalse(PortOwner.isOurs(pid: 42, command: "/usr/bin/python3 -m http.server 4567", recordedPid: 42))
    }

    func testRecognisesItsOwnTrackerDashboardByRecordedPid() {
        let command = "/x/bin/tracker-dashboard --dashboard /x/dashboard.md --port 4567"
        XCTAssertTrue(PortOwner.isOurs(pid: 1, command: command, recordedPid: 1))
    }

    func testLeavesATrackerDashboardItDidNotStartAlone() {
        let command = "ruby /x/bin/tracker-dashboard --port 4567"
        XCTAssertFalse(PortOwner.isOurs(pid: 1, command: command, recordedPid: nil))
        XCTAssertFalse(PortOwner.isOurs(pid: 1, command: command, recordedPid: 2))
    }

    func testPidRecordRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("server.pid")
        let record = PidRecord(url: url)
        XCTAssertNil(record.read())
        record.write(1234)
        XCTAssertEqual(record.read(), 1234)
        record.clear()
        XCTAssertNil(record.read())
    }
}

final class LogFileTests: XCTestCase {
    func testRotatesPastTheLimitAndKeepsOneGeneration() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".log"
        try String(repeating: "x", count: 20).write(toFile: path, atomically: true, encoding: .utf8)
        LogFile.rotateIfNeeded(path: path, maxBytes: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".1"))
    }

    func testLastLineSkipsBlankLines() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".log"
        try "booting\nCould not locate Gemfile\n\n  \n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(LogFile.lastLine(path: path), "Could not locate Gemfile")
        XCTAssertNil(LogFile.lastLine(path: path + ".missing"))
    }
}

final class StatsTests: XCTestCase {
    func testParsesADashboardPayloadIncludingDocsOnlyProjects() throws {
        let json = #"""
        [{"name":"My App","slug":"my-app","namespace":"APP","started":1,"backlog":2,"icebox":0,"done":5,
          "next_task":"login page","tracker":true},
         {"name":"Handbook","slug":"handbook","namespace":"HB","next_task":null,"tracker":false}]
        """#
        let projects = try XCTUnwrap(Stats.parse(Data(json.utf8)))
        XCTAssertEqual(projects[0], ProjectInfo(name: "My App", slug: "my-app", namespace: "APP", nextTask: "login page",
                                                started: 1, done: 5, backlog: 2, icebox: 0, hasTracker: true))
        XCTAssertEqual(projects[0].urlPath, "/projects/my-app")
        XCTAssertFalse(projects[1].hasTracker)
        XCTAssertEqual(projects[1].urlPath, "/projects/handbook/docs")
    }

    func testAnOlderServerWithoutTheTrackerFlagMeansABoard() throws {
        let projects = try XCTUnwrap(Stats.parse(Data(#"[{"name":"A","namespace":"A"}]"#.utf8)))
        XCTAssertTrue(projects[0].hasTracker)
        XCTAssertEqual(projects[0].slug, "a")
    }

    func testRejectsAnErrorObject() {
        XCTAssertNil(Stats.parse(Data(#"{"error":"Internal Server Error"}"#.utf8)))
    }
}

final class DashboardReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testProjectDirectoryFormReadsTheBacklogInsideTracker() throws {
        try write("app/tracker/backlog.md", "# Backlog (see APP-099)\n\n- APP-001 First story\n")
        try write("dashboard.md", "## My App\npath: ./app\nnamespace: APP\n")
        let projects = DashboardReader(path: root.appendingPathComponent("dashboard.md").path).load()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].nextTask, "First story")  // the heading mentioning an id is skipped
        XCTAssertTrue(projects[0].hasTracker)
    }

    func testOlderFormWherePathIsTheTrackerStillWorks() throws {
        try write("app/tracker/backlog.md", "- APP-002 Legacy\n")
        try write("dashboard.md", "## App\npath: \(root.path)/app/tracker\nnamespace: APP\n")
        XCTAssertEqual(DashboardReader(path: root.appendingPathComponent("dashboard.md").path).load()[0].nextTask, "Legacy")
    }

    func testExplicitTrackerKeyWins() throws {
        try write("stories/backlog.md", "- APP-003 Elsewhere\n")
        try write("dashboard.md", "## App\npath: ./app\ntracker: ../stories\nnamespace: APP\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
        XCTAssertEqual(DashboardReader(path: root.appendingPathComponent("dashboard.md").path).load()[0].nextTask, "Elsewhere")
    }

    func testDocsOnlyProjectHasNoTracker() throws {
        try write("handbook/docs/index.md", "# Hi\n")
        try write("dashboard.md", "## Handbook\npath: ./handbook\nnamespace: HB\n")
        let project = DashboardReader(path: root.appendingPathComponent("dashboard.md").path).load()[0]
        XCTAssertFalse(project.hasTracker)
        XCTAssertEqual(project.urlPath, "/projects/handbook/docs")
    }

    func testMatchesTheServersSlugsAndNamespaceDefaults() throws {
        try write("dashboard.md", """
            ## My App
            path: ./a
            namespace: A

            ## My App
            path: ./b
            namespace: B

            ## Side-Project
            path: ./c

            ## Skipped, no path
            namespace: X
            """)
        let projects = DashboardReader(path: root.appendingPathComponent("dashboard.md").path).load()
        XCTAssertEqual(projects.map(\.slug), ["my-app", "my-app-2", "side-project"])
        XCTAssertEqual(projects[2].namespace, "SIDE_PROJECT")
    }
}
