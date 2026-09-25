import Foundation

/// How the server process is started.
///
/// The server runs through the user's own shell as an interactive login
/// shell, so whatever sets up Ruby in their dotfiles - rbenv, asdf, mise,
/// chruby, rvm, a Homebrew PATH - applies exactly as it does in a terminal.
/// The app never guesses where Ruby lives.
///
/// Arguments reach the shell as positional parameters, never spliced into
/// the command string, so no path needs quoting. `exec` keeps one process:
/// the pid the app launches is the pid that listens, which is what lets it
/// recognise its own server later.
public struct LaunchPlan: Equatable {
    public let shell: String
    public let arguments: [String]
}

public enum Launch {
    /// The user's login shell when it is one we know how to drive, else zsh.
    public static func shell(environment: [String: String],
                             isExecutable: (String) -> Bool = FileManager.default.isExecutableFile) -> String {
        if let shell = environment["SHELL"],
           ["zsh", "bash"].contains((shell as NSString).lastPathComponent),
           isExecutable(shell) {
            return shell
        }
        return "/bin/zsh"
    }

    /// - Parameter script: nil runs `tracker-dashboard` from the shell's PATH,
    ///   which is where `gem install bacon-tracker` puts it. A script inside a
    ///   bacon-tracker checkout (a Gemfile beside its bin/) runs with
    ///   `bundle exec` from that checkout; any other script runs as is.
    public static func plan(script: String?, dashboard: String, port: Int, shell: String,
                            fileExists: (String) -> Bool = FileManager.default.fileExists) -> LaunchPlan {
        var checkout = ""
        let command: String
        if let script {
            let root = URL(fileURLWithPath: script).deletingLastPathComponent().deletingLastPathComponent().path
            if fileExists((root as NSString).appendingPathComponent("Gemfile")) {
                checkout = root
                command = #"cd "$4" && exec bundle exec ruby "$1" --dashboard "$2" --port "$3""#
            } else {
                command = #"exec "$1" --dashboard "$2" --port "$3""#
            }
        } else {
            command = #"exec tracker-dashboard --dashboard "$2" --port "$3""#
        }
        // $0 is a label; $1...$4 are script, dashboard, port, checkout.
        return LaunchPlan(shell: shell,
                          arguments: ["-i", "-l", "-c", command, "bacon-tracker-menu",
                                      script ?? "", dashboard, String(port), checkout])
    }

    /// A readable reason for a server that exited on its own.
    public static func exitReason(status: Int32, lastLogLine: String?, usingPath: Bool) -> String {
        if status == 127 {
            return usingPath
                ? "tracker-dashboard was not found on your shell's PATH. Run `gem install bacon-tracker`, or choose the script in this menu."
                : "The tracker-dashboard script could not be run. Check the script path in this menu."
        }
        let detail = lastLogLine.map { ": \($0)" } ?? ""
        return "Server exited (status \(status))\(detail)"
    }
}
