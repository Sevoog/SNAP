# Contributing to SNAP

Thanks for your interest in SNAP. Contributions are welcome — bug reports, fixes, and new tools alike. SNAP is maintained in spare time, so replies may take a few days.

## Before you start

- **Bugs:** open an issue with your macOS version, what you did, what you expected, and what happened. Screenshots help; please use Demo Mode (below) so they don't show your network details.
- **Bigger changes** (a new tool, a redesign, a new dependency): open an issue first so we can agree on the approach before you spend time on it.
- **Security issues:** don't open a public issue. See [SECURITY.md](SECURITY.md).

## Building

Requirements: macOS 14 or later and a recent Xcode.

```bash
git clone https://github.com/Sevoog/SNAP.git
cd SNAP
open SNAP.xcodeproj    # ⌘R to run, ⌘U to run the tests
```

Or from the command line:

```bash
xcodebuild -project SNAP.xcodeproj -scheme SNAP test
```

**Demo Mode** swaps your real network details (hostname, MAC address, public IP, Wi-Fi name, ISP) for placeholders. Use it for any screenshot or recording you share: launch with the `-demoMode` argument, or set `SNAP_DEMO_MODE=1`. It doesn't replace the list of nearby networks in the Wi-Fi Analyzer, so keep that view out of shared screenshots.

## Guidelines

- **No third-party dependencies.** SNAP uses only Apple's frameworks. If you think a dependency is truly needed, raise it in an issue first.
- **Match the surrounding code:** its naming, comment style, and structure. Views use the `NS` color tokens and observe `ThemeManager.shared` so theme changes apply everywhere.
- **Keep the build clean.** No new compiler warnings, and all tests pass. Add tests for logic that can be tested without the UI.
- **Privacy is a feature.** If your change contacts a new host or service, or stores new data, add it to the Privacy & Security section of [README.md](README.md). No analytics or telemetry.
- **Update the CHANGELOG.** Add a short entry under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md).

## Contributor License Agreement

Before your first pull request can be merged, you'll need to sign the [Contributor License Agreement](CLA.md). The CLA Assistant bot will prompt you on the pull request; you sign by posting a comment. It takes a minute and covers all your future contributions.

**Why a CLA?** SNAP is licensed under the GPL v3, and may also be offered under other licenses, including commercial ones, for organizations that can't use GPL software. The CLA lets the maintainer include your contribution in those versions too. You keep the copyright in your work, and anything released under the GPL stays available under the GPL.

## License

By contributing, you agree that your contributions are licensed under the [GNU GPL v3](LICENSE) and the terms of the [CLA](CLA.md).
