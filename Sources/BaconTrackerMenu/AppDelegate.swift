import Cocoa
import BaconTrackerMenuCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var menuBarItem: NSStatusItem!
    private var server: ServerManager!
    private var reader: DashboardReader!

    /// One menu instance, rebuilt in place - so stats that arrive while it is
    /// open update what the user is looking at instead of the next opening.
    private let menu = NSMenu()

    // Cached from /api/stats, kept warm by a timer while the server runs.
    private var cachedProjects: [ProjectInfo]?
    private var statsFetchTask: URLSessionDataTask?
    private var statsFetchGeneration = 0  // guards against stale completions racing cancel()
    private var refreshTimer: Timer?
    private static let refreshInterval: TimeInterval = 30

    private static let defaultPort = 4567

    // Dot colors for project status - opaque so they read on both light and dark menu backgrounds.
    private static let dotColorActive = NSColor(red: 0.369, green: 0.549, blue: 0.416, alpha: 1.0)
    private static let dotColorRose   = NSColor(red: 0.753, green: 0.510, blue: 0.635, alpha: 1.0)
    private static let dotColorIcebox = NSColor(red: 0.68,  green: 0.57,  blue: 0.63,  alpha: 1.0)
    private static let dotColorMuted  = NSColor.secondaryLabelColor

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuBarItem.button?.image = icon(running: false)
        menu.delegate = self
        menuBarItem.menu = menu

        loadDashboard(path: savedDashboardPath)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    // MARK: - Setup

    private func loadDashboard(path: String) {
        statsFetchTask?.cancel()
        statsFetchTask = nil
        server?.onStateChange = nil
        server?.stop()
        cachedProjects = nil

        reader = DashboardReader(path: path)
        server = ServerManager(dashboardPath: path, port: port, scriptPath: savedScriptPath)
        server.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.serverStateChanged() }
        }

        UserDefaults.standard.set(path, forKey: "dashboardPath")
        server.start()
        serverStateChanged()
    }

    private func serverStateChanged() {
        refreshIcon()
        refreshTimer?.invalidate()
        refreshTimer = nil
        if server.isRunning {
            fetchStats()  // rebuilds the menu when the response arrives
            refreshTimer = Timer.scheduledTimer(withTimeInterval: AppDelegate.refreshInterval, repeats: true) {
                [weak self] _ in self?.fetchStats()
            }
        } else {
            cachedProjects = nil
        }
        buildMenu()
    }

    // MARK: - Stats

    private func fetchStats() {
        guard server.isRunning,
              let url = URL(string: "http://localhost:\(port)/api/stats") else { return }
        statsFetchTask?.cancel()
        statsFetchGeneration &+= 1
        let gen = statsFetchGeneration
        statsFetchTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard error == nil, let data, let projects = Stats.parse(data) else { return }
            DispatchQueue.main.async {
                guard let self, self.statsFetchGeneration == gen else { return }
                self.statsFetchTask = nil
                self.cachedProjects = projects
                self.buildMenu()
            }
        }
        statsFetchTask?.resume()
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        buildMenu()   // from the warm cache, immediately
        fetchStats()  // and fresher numbers as soon as they arrive
    }

    private func buildMenu() {
        menu.removeAllItems()

        switch server.state {
        case .running:
            let status = NSMenuItem(title: "Running on port \(port)", action: nil, keyEquivalent: "")
            status.isEnabled = false
            status.attributedTitle = runningStatusTitle(port: port)
            menu.addItem(status)
        case .starting:
            addDisabled("Starting on port \(port)…", to: menu)
        case .stopped:
            addDisabled("Server stopped", to: menu)
            if let err = server.lastError { addError(err, to: menu) }
        }
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Dashboard",
                                  action: server.isRunning ? #selector(openDashboard) : nil,
                                  keyEquivalent: "o")
        openItem.target = self
        openItem.isEnabled = server.isRunning
        menu.addItem(openItem)

        // Per-project items - live stats when available, dashboard.md as fallback.
        let projects = cachedProjects ?? reader.load()
        if !projects.isEmpty {
            menu.addItem(.separator())
            projects.forEach { menu.addItem(projectMenuItem(for: $0)) }
        }

        menu.addItem(.separator())
        if server.state == .stopped {
            addAction("Start Server", #selector(startServer))
        } else {
            addAction("Stop Server", #selector(stopServer))
        }

        menu.addItem(.separator())
        addAction("Choose dashboard.md…", #selector(chooseDashboard))
        let serverLabel = savedScriptPath.map { "Server: …/\(URL(fileURLWithPath: $0).lastPathComponent) (custom)…" }
            ?? "Server: tracker-dashboard from PATH…"
        addAction(serverLabel, #selector(chooseScript))
        if savedScriptPath != nil {
            addAction("Use tracker-dashboard from PATH", #selector(useScriptFromPath))
        }
        addAction("Port: \(port)…", #selector(choosePort))
        addAction("Open Log", #selector(openLog))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Bacon Tracker Menu",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Menu item helpers

    private func runningStatusTitle(port: Int) -> NSAttributedString {
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: AppDelegate.dotColorActive,
            .font: NSFont.menuFont(ofSize: 9)
        ]))
        attr.append(NSAttributedString(string: "Running on port \(port)", attributes: [
            .font: NSFont.menuFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        return attr
    }

    private func projectMenuItem(for proj: ProjectInfo) -> NSMenuItem {
        let item = NSMenuItem(title: proj.name,
                              action: server.isRunning ? #selector(openProject(_:)) : nil,
                              keyEquivalent: "")
        item.target = self
        item.representedObject = proj.urlPath
        item.isEnabled = server.isRunning

        // Dot color encodes urgency. nextTask covers the dashboard.md fallback,
        // where the counts are always zero.
        let dotColor: NSColor
        if proj.started > 0 {
            dotColor = AppDelegate.dotColorActive          // green - in-flight work
        } else if proj.backlog > 0 || proj.nextTask != nil {
            dotColor = AppDelegate.dotColorRose            // rose - committed / queued
        } else if proj.icebox > 0 {
            dotColor = AppDelegate.dotColorIcebox          // muted rose - parked ideas
        } else {
            dotColor = AppDelegate.dotColorMuted           // secondary - empty or docs only
        }

        let meta: String?
        if !proj.hasTracker        { meta = "docs" }
        else if proj.started > 0   { meta = "\(proj.started) started" }
        else if proj.backlog > 0   { meta = "\(proj.backlog) backlog" }
        else if proj.icebox > 0    { meta = "\(proj.icebox) icebox" }
        else if proj.done > 0      { meta = "\(proj.done) done" }
        else                       { meta = nil }

        let full = NSMutableAttributedString()
        full.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: dotColor,
            .font: NSFont.menuFont(ofSize: 0)
        ]))
        full.append(NSAttributedString(string: proj.name, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        if let meta {
            full.append(NSAttributedString(string: "  \(meta)", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        item.attributedTitle = full

        if let next = proj.nextTask, !next.isEmpty {
            item.toolTip = "Next: \(next)"
        }
        return item
    }

    private func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    /// Errors can be long; the menu shows the start and the tooltip the rest.
    private func addError(_ message: String, to menu: NSMenu) {
        let short = message.count > 70 ? String(message.prefix(70)) + "…" : message
        let item = NSMenuItem(title: "⚠ \(short)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = message
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        open(path: "")
    }

    @objc private func openProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        open(path: path)
    }

    @objc private func startServer() {
        server.start()
    }

    @objc private func stopServer() {
        server.stop()
    }

    @objc private func chooseDashboard() {
        let panel = NSOpenPanel()
        panel.title = "Select dashboard.md"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadDashboard(path: url.path)
    }

    @objc private func chooseScript() {
        let panel = NSOpenPanel()
        panel.title = "Select tracker-dashboard"
        panel.message = "Only needed for a bacon-tracker checkout. A gem install is found on your PATH."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let existing = savedScriptPath {
            panel.directoryURL = URL(fileURLWithPath: existing).deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "scriptPath")
        loadDashboard(path: savedDashboardPath)
    }

    @objc private func useScriptFromPath() {
        UserDefaults.standard.removeObject(forKey: "scriptPath")
        loadDashboard(path: savedDashboardPath)
    }

    @objc private func choosePort() {
        let alert = NSAlert()
        alert.messageText = "Server port"
        alert.informativeText = "The port tracker-dashboard listens on (1024-65535)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = String(port)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
              (1024...65535).contains(value) else {
            let invalid = NSAlert()
            invalid.messageText = "“\(field.stringValue)” is not a port between 1024 and 65535."
            invalid.runModal()
            return
        }
        UserDefaults.standard.set(value, forKey: "port")
        loadDashboard(path: savedDashboardPath)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: ServerManager.logPath))
    }

    // MARK: - Helpers

    private func open(path: String) {
        guard let url = URL(string: "http://localhost:\(port)\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshIcon() {
        menuBarItem.button?.image = icon(running: server.isRunning)
    }

    private func icon(running: Bool) -> NSImage? {
        let img = NSImage(systemSymbolName: running ? "carrot.fill" : "carrot",
                          accessibilityDescription: "Bacon Tracker Menu")
        img?.isTemplate = true
        return img
    }

    private var port: Int {
        let saved = UserDefaults.standard.integer(forKey: "port")
        return (1024...65535).contains(saved) ? saved : AppDelegate.defaultPort
    }

    private var savedDashboardPath: String {
        UserDefaults.standard.string(forKey: "dashboardPath") ?? defaultDashboardPath
    }

    /// nil = tracker-dashboard from the login shell's PATH.
    private var savedScriptPath: String? {
        UserDefaults.standard.string(forKey: "scriptPath")
    }

    private var defaultDashboardPath: String {
        let home = NSHomeDirectory() as NSString
        let candidates = [home.appendingPathComponent("dashboard.md"),
                          home.appendingPathComponent(".bacon/dashboard.md")]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }
}
