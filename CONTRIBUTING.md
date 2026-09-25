# Contributing to BaconTrackerMenu

## Development setup

```bash
git clone https://github.com/bybacon/bacon-tracker-menu
cd bacon-tracker-menu
swift build
swift test
make app            # BaconTrackerMenu.app in this directory, to try changes by hand
```

Requires macOS 13 or later and Xcode 15 or later (Swift 5.9+). CI builds, tests and assembles the app on the latest macOS runner. To try the app end to end you also need [bacon-tracker](https://github.com/bybacon/bacon-tracker) and a `dashboard.md`.

## Working on a change

- **Branch first.** Create a feature branch off `main`.
- **Tests are the documentation.** Add or update tests for any behaviour change. `swift test` must be green.
- **Keep the split.** Anything that can be decided without AppKit or a live process belongs in `Sources/BaconTrackerMenuCore`, where it is unit tested: the launch command, `dashboard.md`, the stats payload, port ownership, the log. `Sources/BaconTrackerMenu` is only the menu and process management.
- **Never touch a process the app did not start.** Port handling replaces only the server whose pid the app recorded.
- **Follow bacon-tracker.** The app reads `dashboard.md` and `/api/stats` the way the gem writes them. A change to either format starts in [bacon-tracker](https://github.com/bybacon/bacon-tracker).
- **Match the surrounding style.** Simplicity over cleverness.

## Submitting

Open a pull request against `main` with a clear description of the change and why; the pull request template walks you through it.

## Reporting bugs / requesting features

Open a [GitHub issue](https://github.com/bybacon/bacon-tracker-menu/issues). For security issues, see [SECURITY.md](SECURITY.md) instead. Problems with the board or dashboard pages themselves belong to [bacon-tracker](https://github.com/bybacon/bacon-tracker/issues).
