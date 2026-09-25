# Changelog

All notable changes to this project will be documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-09-25

First public release, alongside bacon-tracker 1.0.0.

### Added

- A menu bar app that starts `tracker-dashboard` for a `dashboard.md`, stops it on quit, and lists every project one click from its board.
- Runs the server through your login shell, so any Ruby setup works: rbenv, asdf, mise, chruby, rvm or Homebrew.
- Finds a gem-installed `tracker-dashboard` on your PATH, or runs `bin/tracker-dashboard` from a bacon-tracker checkout with `bundle exec`.
- Starting, Running and Stopped states. The server only counts as running once it answers, and the menu says why it stopped, including "tracker-dashboard not found".
- A workload dot and count per project, with the next backlog item on hover. Docs-only projects open on their docs.
- A configurable port, an Open Log item, and log rotation at 1 MB.
- A server left running after a crash is recognised and replaced on the next launch. A process the app did not start is never stopped.
