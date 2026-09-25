import Darwin
import Foundation
import BaconTrackerMenuCore

/// Starts, watches and stops one tracker-dashboard process.
///
/// A launched process is `starting` until it answers /api/stats; only then is
/// it `running`. A process that exits on its own leaves a `lastError` naming
/// why, so the menu never shows a silent "stopped".
final class ServerManager {
    enum State { case stopped, starting, running }

    private(set) var state: State = .stopped
    private(set) var lastError: String?
    var onStateChange: (() -> Void)?

    var isRunning: Bool { state == .running }

    let dashboardPath: String
    let port: Int
    /// nil runs tracker-dashboard from the login shell's PATH (a gem install).
    let scriptPath: String?

    private var process: Process?
    private var readinessTimer: Timer?
    private var readinessDeadline = Date()
    private let pidRecord = PidRecord(url: ServerManager.supportDirectory.appendingPathComponent("server.pid"))

    /// A cold login shell plus Ruby and Puma boot; generous on purpose.
    static let startupTimeout: TimeInterval = 45

    init(dashboardPath: String, port: Int, scriptPath: String?) {
        self.dashboardPath = dashboardPath
        self.port = port
        self.scriptPath = scriptPath
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() {
        guard state == .stopped else { return }
        lastError = nil

        guard FileManager.default.fileExists(atPath: dashboardPath) else {
            return fail("dashboard.md not found at \(dashboardPath). Choose one in this menu, or run tracker-init.")
        }
        if let script = scriptPath, !FileManager.default.fileExists(atPath: script) {
            return fail("Script not found at \(script). Choose it again, or use tracker-dashboard from your PATH.")
        }
        guard reclaimPort() else { return }

        let plan = Launch.plan(script: scriptPath, dashboard: dashboardPath, port: port,
                               shell: Launch.shell(environment: ProcessInfo.processInfo.environment))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: plan.shell)
        proc.arguments = plan.arguments
        proc.standardInput = FileHandle.nullDevice

        let logPath = ServerManager.logPath
        LogFile.rotateIfNeeded(path: logPath)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let log = FileHandle(forWritingAtPath: logPath) {
            log.seekToEndOfFile()
            log.write(Data("\n--- \(Date()) starting on port \(port) ---\n".utf8))
            proc.standardOutput = log
            proc.standardError = log
        }

        proc.terminationHandler = { [weak self] exited in
            DispatchQueue.main.async { self?.processExited(exited) }
        }

        do {
            try proc.run()
        } catch {
            return fail("Could not start \(plan.shell): \(error.localizedDescription)")
        }
        process = proc
        pidRecord.write(proc.processIdentifier)
        state = .starting
        onStateChange?()
        beginReadinessCheck()
    }

    func stop() {
        stopReadinessCheck()
        if let proc = process {
            // An intended stop is not a crash - detach the handler first.
            proc.terminationHandler = nil
            proc.terminate()
            // Until `exec` runs, the pid is an interactive shell still reading
            // dotfiles, and interactive shells ignore SIGTERM. Puma exits on
            // SIGTERM well within this grace period.
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }
        process = nil
        guard state != .stopped else { return }
        state = .stopped
        onStateChange?()
    }

    private func processExited(_ proc: Process) {
        guard proc === process else { return }  // an older process, already replaced
        process = nil
        pidRecord.clear()
        stopReadinessCheck()
        state = .stopped
        lastError = Launch.exitReason(status: proc.terminationStatus,
                                      lastLogLine: LogFile.lastLine(path: ServerManager.logPath),
                                      usingPath: scriptPath == nil)
        NSLog("BaconTrackerMenu: %@", lastError ?? "")
        onStateChange?()
    }

    private func fail(_ message: String) {
        NSLog("BaconTrackerMenu: %@", message)
        lastError = message
        state = .stopped
        onStateChange?()
    }

    // MARK: - Readiness

    private func beginReadinessCheck() {
        stopReadinessCheck()
        readinessDeadline = Date().addingTimeInterval(ServerManager.startupTimeout)
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.probe()
        }
    }

    private func stopReadinessCheck() {
        readinessTimer?.invalidate()
        readinessTimer = nil
    }

    private func probe() {
        guard state == .starting, let proc = process else { return stopReadinessCheck() }
        if Date() > readinessDeadline {
            stop()
            return fail("The server did not answer within \(Int(ServerManager.startupTimeout)) seconds. See the log.")
        }
        guard let url = URL(string: "http://localhost:\(port)/api/stats") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            DispatchQueue.main.async {
                guard let self, self.state == .starting, self.process === proc else { return }
                self.stopReadinessCheck()
                self.state = .running
                self.onStateChange?()
            }
        }.resume()
    }

    // MARK: - Port

    /// Free the port if a server this app started is still listening on it -
    /// typically one orphaned by a crash. Never touches an unrelated process:
    /// that is reported instead. Returns true when the port is free to bind.
    private func reclaimPort() -> Bool {
        let pids = listeners()
        guard !pids.isEmpty else { return true }

        let recorded = pidRecord.read()
        for pid in pids {
            let command = run("/bin/ps", ["-o", "command=", "-p", String(pid)])
            if command.isEmpty { continue }  // exited between lsof and ps
            guard PortOwner.isOurs(pid: pid, command: command, recordedPid: recorded) else {
                fail("Port \(port) is in use by another process (pid \(pid): \(command)). Stop it or choose another port.")
                return false
            }
            kill(pid, SIGTERM)
        }
        for _ in 0..<20 where !listeners().isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for pid in listeners() {
            let command = run("/bin/ps", ["-o", "command=", "-p", String(pid)])
            if PortOwner.isOurs(pid: pid, command: command, recordedPid: recorded) { kill(pid, SIGKILL) }
        }
        pidRecord.clear()
        return true
    }

    private func listeners() -> [Int32] {
        run("/usr/sbin/lsof", ["-ti", "tcp:\(port)", "-sTCP:LISTEN"])
            .split(separator: "\n").compactMap { Int32($0) }
    }

    /// Run a short command (no shell) and return its trimmed stdout, "" on failure.
    private func run(_ executable: String, _ arguments: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Paths

    static var logPath: String {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BaconTrackerMenu")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bacon-tracker-menu.log").path
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BaconTrackerMenu")
    }
}
