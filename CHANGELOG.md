# SNAP Changelog
All notable changes to SNAP — Sev's Network Analysis Platform

---

## [Unreleased]

### Fixed: hard-to-read text in the menu bar popover

Captions, labels, section headers, the peak readouts, the sample notes, text field placeholders, and the version number were drawn in faint white or black (15 to 30% opacity), which measured under 3:1 contrast in every theme. They now use the theme's text colors, checked against the surface they sit on, so every piece of text reaches at least 4.5:1 in all 12 themes. Accent-colored text (the rates, Online, Open SNAP, badges) keeps its color but is deepened where a theme's accent was too faint, such as Nord's blue. Icons reach at least 3:1, and the Ping and DNS fields and buttons have a crisp one-point outline (a half-point one looked smeared on non-Retina displays). The smallest captions and badges are also a size larger (9 pt instead of 8 pt).

### SNMP: seven views, Watch live, and a Status Board tile

The SNMP tab now has a menu of views, grouped Device, Ports, and Advanced.

- **Health.** Printer toner and ink levels, UPS battery charge and minutes left, and storage and CPU on NAS boxes and servers, each with a one-line verdict such as "Black toner at 8%: replace it soon" or "On mains power. Battery 100%, about 42 min of runtime". Uses the standard Printer, UPS, and Host Resources MIBs, with APC's own MIB as a fallback for UPSes.
- **Inventory.** Models and serial numbers of the chassis, modules, power supplies, and fans (ENTITY-MIB), with a Copy button on each serial and Copy All Serials. Printers, UPSes, and Synology NAS boxes fall back to their own MIBs.
- **Interfaces, rebuilt.** Port names and the labels admins type, correct speeds, error counts, when each port last changed ("3 min ago"), and a Physical ports only filter, with a one-line summary above the table. **Watch live** polls the ports shown every 2 to 30 s and adds live in and out traffic, % of link, a trend line, and a chart for the selected port.
- **Neighbors.** What's plugged into each port, from LLDP and Cisco's CDP: the neighbor's name, its port, what kind of device it is, and its address, with a Query button to hop to that switch.
- **Where Is It?** Type an IP or MAC address and get the switch port it's on. SNAP finds the MAC address in the device's ARP table or your Mac's, looks it up in the switch's MAC table, and tells you when the port leads to another switch instead, with a button to keep looking there.
- **Remember.** An opt-in checkbox keeps a host's community string in your Keychain and fills it in next time. Unticking it forgets that host; Options has Forget All.
- **Status Board: SNMP Watch tile.** Pin a device from System Info, or a port from Interfaces, with Show on Status Board. The tile shows its status, uptime, and, for a port, live traffic with % of link. It asks the device every 10 s only while the board shows it, using its own saved copy of the community string.

### SNMP: easier to use, and several fixes

New:

- **How to use SNMP.** Before your first query, the SNMP tab explains what SNMP is, how to turn it on in a device, what the community string is, and what each mode shows. It also says plainly that SNAP only reads and never changes device settings.
- **"No answer" explained.** When a device doesn't reply, a card explains the usual reason (with v1 and v2c, a wrong community string looks exactly like SNMP being off) and lists what to check, including this Mac's address as the device sees it, with a Send to Ping button. Other errors get plain-language explanations too, including a device that stops answering partway through.
- **Options:** SNMP version (Auto, v2c, or v1), timeout, retries, and row limit. Auto asks over v2c and, if there's no answer, once more over v1, for older devices that only speak v1.
- **Query with SNMP** from any host's right-click menu, `snmp HOST` in the ⌘K palette, and a recent-hosts menu next to the Host field. Only hosts are saved, never the community string.

Fixed:

- A device that repeated or reordered its replies could crash SNAP in the SNMP tab, Fingerprint, or Bulk Discovery. Walks now stop when a device goes out of order, as `snmpwalk` does.
- Stop didn't stop. A stopped query kept running and could later show its result, or a "timed out" error, over the next query.
- After a failed query, the previous device's results stayed on screen, and Copy and Export labeled results with whatever was in the Host field at that moment. Results now show which device they came from and when, and exports use that.
- Copy and Export included the community string, and so did Fingerprint's log. They now say only "default (public)" or "custom (not shown)".
- Ports of 10 Gbps and faster showed as "4 Gbps", and 2.5 Gbps ports as "2 Gbps". Speeds now come from ifHighSpeed when needed and show a decimal where it matters.
- Ports turned off in the device's settings showed as a red "down". They now read "disabled".
- The In and Out columns are now Total in and Total out (bytes since the device's counter last reset) and use 64-bit counters when the device has them, so they no longer wrap at 4.29 GB.
- Text with Windows-style line breaks (common in Cisco descriptions) or trailing null bytes (common on printers) showed as hex.
- Walking a single value such as `sysName.0` returned 0 rows. It now returns the value. A walk that finds nothing says so, and so does a walk cut short by the row limit.
- When a device rejects GETBULK or says a reply is too big, walks now carry on with smaller requests or GETNEXT instead of failing.
- On v1 devices, System Info no longer fails outright when one value is missing.

### New: iPerf3 results, explained

Speed Test's iPerf3 mode still shows iperf3's output exactly as iperf3 prints it, and now adds:

- **Summary cards:** throughput (what actually arrived), data moved, retransmits, and steadiness (how much the speed swung from second to second). Data moved is in decimal GB like the rest of SNAP; iperf3 counts in binary GBytes, so the card also shows iperf3's own figure.
- **A plain-language verdict** that compares the result with your Mac's link: which connection reaches the server (Ethernet or Wi-Fi), its speed, and whether something slower in the path holds the result back, for example "Capped near 1 Gbps" on a Mac with a 10 Gbps port. It also calls out retransmits and an unsteady connection.
- **A per-second chart**, with your Mac's link speed as a dashed line when it's on the same scale.
- **How to read this:** a key to iperf3's columns (Interval, Transfer, Bitrate, Retr, Cwnd, sender and receiver, `[SUM]`).
- **Direction:** Upload (this Mac sends), Download (the server sends, `-R`), or Both, one after the other.
- **Streams:** 1, 2, 4, or 8 parallel connections (`-P`). One connection sometimes can't fill a fast link.
- **Duration:** 5, 10, 20, 30, or 60 seconds (`-t`). It was always 10.
- **Recent LAN tests:** the last 100 iPerf3 results are saved. They're kept apart from internet speed tests, so they don't show up in that history or on the Status Board's Speed Test tile.
- The internet test's Size picker no longer shows in iPerf3 mode, where it never applied.

To find the connection and its speed, SNAP runs `route -n get <server>`, then reads the link speed from `ifconfig` for Ethernet or the current transmit rate from macOS for Wi-Fi.

### Fixed: Speed Test's iPerf3 mode couldn't find iperf3

SNAP looked for `iperf3` only with `which`, using the app's own PATH. An app opened from Finder gets just `/usr/bin:/bin:/usr/sbin:/sbin`, so it missed Homebrew installs (`/opt/homebrew/bin` on Apple silicon, `/usr/local/bin` on Intel) and reported "iperf3 not found" even when Terminal could run it. It now checks those folders, MacPorts (`/opt/local/bin`), and `/usr/bin` first, then `which`; the not-found message lists where it looked. Found on Intel Macs.

### Fixed: duplicate Copy and Export buttons in Speed Test's iPerf3 mode

After a test, the top bar showed Copy and Export for the internet speed test results even in iPerf3 mode, next to the iPerf3 row's own Copy and Export for the iperf3 output. The top set now appears only for internet tests.

### Fixed: byte units differed between screens

Some screens counted 1 KB as 1,024 bytes and others as 1,000, so the same traffic could read differently. The Bandwidth tab (rates, totals, and its chart axis), the Dashboard's Bandwidth card, Interface Stats, Network Info, SNMP, and a Dashboard card's size readout used 1,024; the menu bar, the Status Board, and Speed Test used 1,000. All now use **1,000** (1 KB = 1,000 bytes, 1 MB = 1,000,000), matching Speed Test's megabits and macOS's own byte counts. Each readout keeps its decimal places. Speed Test itself is unchanged: it reports megabits per second (Mbps).

---

## [1.5.5] - 2026-10-06

**First open-source release, two e-ink themes, and fixes.** SNAP is now published under the GNU GPL v3. Two new themes, E-ink and Color e-ink, join the picker. Plain-HTTP requests to public hosts are no longer blocked, the window title and toolbar follow the tab on screen, and the minimum macOS is pinned to 14.0.

### Added: E-ink and Color e-ink themes

Two light themes in a new **E-ink** group in the theme picker and the Appearance menu ([Themes.swift](SNAP/Themes.swift)):

- **E-ink**: paper and ink. Because it's grayscale, the Dashboard and sidebar show state with shape instead of color: the selected sidebar item is inverted; status dots are filled (up), ringed (degraded), or hollow (down); latency and route chips are inverted, outlined, or dashed; a Favorite that's down gets a dashed border and a struck-through "timeout"; card badges are inverted (Live), outlined (Functional), or dashed (Launcher); the Bandwidth card draws RX as a solid line over hatching and TX as a dashed line, with a small legend; Wi-Fi bars are filled or outlined.
- **Color e-ink**: the same paper with muted pigments (sage, slate, brick, ochre, plum), and the same shapes drawn in those colors.
- Elsewhere (the Status Board, the menu bar, and the individual tools) both themes use their palette only, so some red-versus-green states read as two shades of the same tone.
- Logo tiles drew a hard-coded near-black icon on the accent color, which vanished on the e-ink themes' dark accent. The new `Theme.onAmber` fixes all 7 places (sidebar rail, About window, Quick Tour, menu bar, Status Board). Every other theme looks the same as before.

### Fixed: the Status Board's CPU row showed only "%"

The System tile passed the literal "%" as the CPU row's value text, so no number appeared. It now shows the rounded percentage, like the Memory and Battery rows.

### Fixed: the Quick Tour said 38 tools

SNAP has 35 tools plus the Dashboard. Corrected on the Quick Tour's first and third slides and in the README. The Quick Tour's themes slide also now says 12 themes and lists the new E-ink group, instead of "10 ship in v1.5.0".

### Fixed: narrow windows cut off the sidebar and squeezed toolbars

The window can be as narrow as 900 pt, which leaves 650 pt for the tool next to the icon rail and sidebar. Five tools needed more than that (Port Scan 870 pt, SNMP 800, WiFi Analyzer 682, Ping 678, UniFi 669). A tool that's too wide pushed the whole window's layout sideways, so the sidebar lost its left edge. Others fit only by squeezing labels until they broke one or two letters per line ("Ope / n only", "Ra / ng / e", "Eth / ern / et"), and some side panels were cut off.

- **The tool area now clips its own content** ([ContentView.swift](SNAP/ContentView.swift)), so no tool can push the icon rail and sidebar off the window again.
- **Toolbars wrap instead of overflowing.** Port Scan, Ping, SNMP, UniFi, WiFi Analyzer, Interface Stats, Network Map, Connections, MTU Discovery, Packet Capture, Lookup, Bulk Discovery, and Fingerprint keep their one-row toolbar when there's room and switch to two rows when the window is narrow (`ViewThatFits`). Labels, toggles, filter chips, and buttons no longer wrap mid-word or truncate (Lookup's server picker showed "1.", Packet Capture's button "Ca…").
- **Side panels fit.** Minimum widths that added up to more than 650 pt are lowered: Network Map's device grid (520 pt, now down to 340 when narrow), Packet Capture's packet table (550 to 420), and DNS Benchmark's results (520 to 400). Their tables scroll sideways when narrow. At normal window sizes the splits are the same as before.
- Checked by rendering all 36 tools at the narrowest and the default window size: every tool fits at 650 pt, and the wide layouts are unchanged.

### Changed: About panel text is easier to read

The About panel's subtitle, version, detail rows, and fine print used the theme's faintest grays, and its blue links were hard to read on some themes (2.5:1 contrast on Nord). Everything now uses the theme's primary text color, at least 8.7:1 in every theme; the links are underlined instead of blue, and the fine print is a size larger.

### Changed: Help menu, About window, and sidebar

- **Help → SNAP Help** (⌘?) opens the project's GitHub page instead of macOS's "Help isn't available for SNAP".
- **About window** (SNAP → About SNAP): says "Sev's Network Analysis Platform for macOS"; drops the line "Inspired by the classic macOS Network Analysis Platform", which named a product that never existed; no longer breaks the license sentence after "and comes"; and has clickable links to the source code on GitHub and to sevag.ai. The About panel (the version badge at the bottom of the sidebar) also links to sevag.ai.
- **Sidebar:** the title reads "Sev's Network Analysis Platform" without the version, which the footer already shows. The footer's ping time and version were drawn in each theme's faintest gray and nearly vanished, especially on Daylight. They now use the secondary and primary text colors, slightly larger, with the version in a small badge.

### Changed: README

- **Privacy & Security rewritten from the code** into a complete inventory, then fact-checked against the code line by line. It now covers what the old version missed or got wrong, including: the Status Board monitors keep running until you quit once the board has been opened (public IP every 10 min, DNS timing every 10 s, `nettop` every 4 s); the Bandwidth monitor's `ipinfo.io` lookup happens on **Start**, not on opening the tab; BGP/ASN lookups go to Google Public DNS (`8.8.8.8`) and on to Team Cymru; Fingerprint resolves through Cloudflare (`1.1.1.1`); Bulk Discovery's TCP sweep, port probes, and SNMP; Apple Maps tiles in GeoIP Lookup and Visual Trace; the Session Report's `api.ipify.org` lookups; ARP Table's Sweep /24 and reverse DNS; Routing Hello's multicast groups; the default User-Agent; and the web cache and cookie files macOS keeps for SNAP (now part of the removal steps).
- Added an **Install** section: downloading the release zip, opening an app that isn't notarized (System Settings → Privacy & Security → Open Anyway), permissions on first launch, checking the SHA-256, and uninstalling.
- Removed the Roadmap section. It listed a "v2.0 Pro" and a "Lite" (App Store) edition, and v1.5 features that never shipped.
- Added a Buy Me a Coffee link, plus `.github/FUNDING.yml` for GitHub's Sponsor button.
- Added the v1.5.5 notes.

### Changed — SNAP is now open source (GPL-3.0)

SNAP's source is now published under the **GNU General Public License v3.0** (`GPL-3.0-only`), replacing the previous proprietary license.

- **[LICENSE](LICENSE)** is the official GPL-3.0 text from gnu.org, unmodified.
- **Every Swift file** (76) now carries a copyright line naming Sevag Bardakjian and `// SPDX-License-Identifier: GPL-3.0-only`. The 52 that said "All rights reserved" switched to it, and the 24 that had no copyright line got one.
- **Attribution term ([NOTICE.md](NOTICE.md)).** As GPL v3 section 7(b) allows, anyone who shares SNAP or a work based on it must keep the copyright notices naming Sevag Bardakjian, and a modified version must show "Based on SNAP by Sevag Bardakjian" with a link to this repository in its About window. Every Swift file's header points to it, as section 7 requires.
- **In the app:** the About window and About alert show the GPL's required notices: the copyright, that SNAP comes with no warranty, that it may be redistributed under the GPL, and where to find the source and license. The app's copyright string says the same.
- **Contributions require signing the [Contributor License Agreement](CLA.md).** It lets SNAP also be offered under other licenses (dual licensing), while contributors keep their copyright and every GPL release stays GPL. A GitHub Action (CLA Assistant Lite, pinned to the commit behind v2.6.1) asks for signatures on pull requests and records them on the `cla-signatures` branch.
- New **[CONTRIBUTING.md](CONTRIBUTING.md)** (building, guidelines, the CLA) and **[SECURITY.md](SECURITY.md)** (private vulnerability reporting).

### Fixed — minimum macOS is now pinned to 14.0 (it silently depended on the Xcode version)

The project-level setting said macOS 13.0, but the SNAP app and test targets overrode it with `$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)`, a value each Xcode release picks for itself. Two consequences:

- **Builds made with Xcode 27 — including v1.5.3 and v1.5.4 — actually require macOS 14.0**, not the 13.0 the README, the About window, and these notes claimed.
- **Xcode 26.2 picks a minimum below macOS 12**, so the same project failed to compile there (on an Intel Mac running Sequoia) with errors like "'dismiss' is only available in macOS 12.0 or newer" for `dismiss`, `KeyPathComparator`, `GraphicsContext`, `FocusState`, and `ProposedViewSize`. Nothing on that Mac was outdated; the project was asking it to build for an older macOS than SNAP supports.

Changes:

- `MACOSX_DEPLOYMENT_TARGET` is **14.0** at the project level and for both targets, so every Xcode builds the same app. No change for Xcode 27 builds, which already resolved to 14.0.
- Docs corrected to **macOS 14.0 or later**: README Requirements, and the v1.5.3 / v1.5.4 notes (corrected in place below).
- The About window and the About alert now read the minimum from the built app (`LSMinimumSystemVersion`) instead of hard-coding "13", so they can't drift again.
- Now possible as a follow-up: the 22 `onChange(of:perform:)` deprecation warnings, and the macOS 13 fallbacks (`EmptyStateView`, the GeoIP and Visual Trace map fallbacks), exist only for macOS 13 and can be removed.


### Fixed: hidden tabs set the window title and toolbar

Since 1.5.4, tabs stay alive in the background after you leave them, and SwiftUI kept reading their window titles and toolbar items. The first opened tab in sidebar order won the title, so after visiting Network Info the Dashboard, and every tab after it, was titled "Network Info" and showed Network Info's Refresh, Copy, and Export buttons.

- Tabs now set their title with `tabNavigationTitle(_:)` ([ContentView.swift](SNAP/ContentView.swift)): the tab on screen shows its own title, and hidden tabs report the on-screen tab's title instead of theirs, so they all agree. The 35 titles live in one place, `SNAPTab.windowTitle`; the Dashboard is "SNAP".
- Network Info's toolbar buttons only exist while Network Info is on screen.
- Checked with a small SwiftUI test app built the same way: before, the title stayed "Network Info" on the Dashboard and on Ping; after, it follows the tab on screen.

### Fixed: plain-HTTP requests to the internet were blocked

`Info.plist` set both `NSAllowsArbitraryLoads` and `NSAllowsLocalNetworking`. When the local-networking key is present, macOS ignores `NSAllowsArbitraryLoads`, so App Transport Security stayed on for every public host and refused plain-HTTP requests before sending them (error -1022). Only local hosts and `captive.apple.com` got through. Removing `NSAllowsLocalNetworking` fixes it; arbitrary loads already cover local hosts. Confirmed with two minimal test apps, one with each setting. What works again:

- **Dashboard GeoIP card** (`ip-api.com` over HTTP) never returned a result.
- **Network Health**: the Microsoft, Google and Firefox captive-portal checks failed on every network, and the transparent-proxy checks showed warnings.
- **HTTP Probe and Fingerprint** couldn't reach public `http://` URLs.

---

## [1.5.4] — 2026-10-05

**Persistent tabs, a Daylight theme repair, and real scan ranges.** Tabs now keep running and keep their state when you switch away; the Daylight theme renders correctly everywhere; and the Network Map and Bulk Discovery scan any range instead of a single /24. Build, Release build, and all 124 tests pass clean. Requires **macOS 14.0** (this entry originally said 13.0 — see [1.5.5]).

### Added — tabs keep running and keep their state

Switching tabs used to **destroy** the tool you left: a running ping, traceroute, port scan, speed test, packet capture, or Network Map scan was stopped, and its inputs and results were gone when you came back. Every tab you open now stays alive in the background ([ContentView.swift](SNAP/ContentView.swift) `detailView`). The selected tab is shown; the others are hidden, not destroyed.

- **Work you started keeps going**: Ping, Traceroute, Visual Trace, MTR, Port Scan, Speed Test, Packet Capture, Syslog, Routing Hello, Bulk Discovery, Network Map scans, Interface Stats "Live", Connections auto-refresh, and the Dashboard's tool cards. It runs until it finishes or you stop it. Closing the main window still stops everything.
- **Hidden tabs are disabled**, so their keyboard shortcuts can't fire from another tab (e.g. Return in Ping won't trigger the Network Map's Scan).
- **Automatic background work pauses while hidden**, via a new `onTabVisibilityChange(shown:hidden:)` modifier fed by an `isActiveTab` environment value:
  - The Dashboard's 30 s connection refresh, Wi-Fi card, and live bandwidth card.
  - **Wi-Fi Analyzer "Live"**: it stays on, but its 5 s scans pause while hidden, because each scan briefly takes the radio off-channel and would skew a ping or speed test running in another tab.
- **Info tabs refresh when you return**, as opening them always did: Network Info, ARP Table, DHCP Leases, Connections (unless auto-refresh is on), and Interface Stats. The Network Map deliberately doesn't, since reloading would overwrite a newer scan with the saved one.
- **Bandwidth and Bonjour keep running** once opened. They're monitors with their own Stop control (Bandwidth) or negligible cost (Bonjour), so their history survives a tab switch. README § Privacy now documents what Bandwidth sends while running (four TCP connections to 1.1.1.1:80 every 3 s, a DNS lookup every 10 s), which the earlier audit had missed.
- Verified in a UI test: send `8.8.8.8` to Ping, switch to Subnet Calculator (only Subnet is visible), switch back, and Ping still shows `8.8.8.8`.

### Fixed — Daylight theme rendered system controls dark

The app forced dark mode (`.preferredColorScheme(.dark)` plus a `darkAqua` window override on the menu bar popover) for **every** theme. Under Daylight, macOS's own controls kept their dark look: tables (Interface Stats, Packet Capture), list columns (Bonjour, Multi-Host), text fields and editors (HTTP Probe, Subnet Calculator), and `.secondary` labels rendered light gray on a light background, which is near-invisible.

- `Theme.isLight` (true for Daylight) now drives the appearance: `NSApp.appearance` is set at launch and on every theme switch (`ThemeManager.applyAppearance()`), covering the main window, sheets, alerts, menus, and the detached Status Board. The main window and About sheet use the theme's `colorScheme`.
- **Menu bar popover**: its backgrounds already followed the theme, but its ~44 text and hairline colors were fixed white, so under Daylight it was white text on a light background. It now uses an `ink(_:)` helper (white on dark themes, unchanged; black on Daylight), and its window appearance follows the theme.
- Sidebar hover highlights and Bandwidth dividers that were fixed white tints now use the theme's text color, so they show on Daylight.
- Verified by rendering Bonjour, Wake-on-LAN, Subnet Calculator, HTTP Probe, Interface Stats, Packet Capture, Multi-Host, and the menu bar popover under Daylight: all readable, no dark controls.

### Fixed — Network Map could only scan a single /24

The Network Map scanned exactly **.1–.254 under a three-octet prefix**, one /24 per comma-separated entry. Three consequences:
- **Prefill ignored the subnet mask.** It took the first three octets of the first Ethernet/Wi-Fi interface with an address, which isn't necessarily the one carrying traffic. On a `10.0.0.0/16` network it scanned ~0.4 % of the hosts. On a /26 it overshot into neighboring subnets.
- **CIDR input was silently truncated.** Typing `10.0.0.0/16` became `10.0.0` and scanned 10.0.0.1–254, with no warning.
- **The UI said ".1 – .254"** regardless of what you typed.

Now, via a new shared parser, `ScanRange` ([ScanRange.swift](SNAP/ScanRange.swift)):

- **Any CIDR up to a /16** (65,534 hosts). Host bits are ignored (`192.168.1.50/24` = the /24), and /31 and /32 follow RFC 3021.
- **Custom ranges**: `10.0.0.50-10.0.3.200`, or last-octet shorthand `192.168.1.100-150`. En and em dashes and surrounding spaces are accepted.
- **Single hosts** (`192.168.1.20`), and the classic forms still work (`192.168.1`, `192.168.1.x`, `192.168.1.*`). Entries can be separated by commas or newlines, mixed freely, and overlaps are counted once.
- **Prefilled from the real subnet** of the Ethernet/Wi-Fi interface carrying the default route, using its actual netmask. Networks larger than a /16 are narrowed to the /16 containing this Mac.
- **A live host count** replaces the fixed ".1 – .254" label. Invalid input shows "Invalid range", with the reason on hover, and disables Scan.
- **Big scans ask first.** Above 1,024 addresses (bigger than a /22), an alert shows the count and a time estimate, notes that monitoring tools will see the probes, and offers **Scan All**, **Scan <your /24> Only** (when your /24 is inside the range), or **Cancel**. The estimate is calibrated by measurement: 32 pings to dead addresses take ~1.06 s per batch, alongside the UniFi unicast sweep at 1.5 s per 48. That's ~19 s for a /24 and ~38 min for a /16.
- Size is checked **before** anything is enumerated, so even `0.0.0.0/0` fails instantly instead of hanging. Parsing a /16 takes ~4 µs (it runs on every redraw for the live count); expanding it takes ~7 ms, once per scan.

**Bulk Discovery** now uses the same parser, so both tools accept identical input; its old `expandCIDR` and a duplicate interface-detection helper are removed. It keeps its own **8,192-address** limit, since it port-scans and SNMP-probes each host. Its label previously claimed "Max /22 (1024 hosts)" while the code allowed 8,192; the label now matches the code.

**Behavior change:** a bare address like `192.168.1.0` now means that one host. Before, the Network Map widened it to its /24 and Bulk Discovery rejected it. The live host count makes this visible as you type.

**Tests:** the 19 range tests from `NetworkMapModelTests` (12) and `ParserTests` (7) moved into the new `ScanRangeTests` with the same inputs. Together with the new cases there are 21 tests, covering ranges, dedupe, limits, the /0 guard, netmask-based prefill, and the time estimates.

### Fixed — "View" label wrapping in the Network Map toolbar

The Grid / List / Visual picker sat in a fixed 220 pt frame, and its natural width (label + segments) measures **exactly 220.0 pt**, leaving zero slack. Any fraction-of-a-point shift, such as the device count changing width when toggling **Online only** ("168 of 168" vs "30 of 168"), wrapped the "View" label onto two lines. The picker now sizes to its content. The range field gives up width first on narrow windows, and the toolbar's status texts stay on one line. The **Subnet Calculator's** "Input Mode" picker had the same pattern and was worse: it needs 283 pt but was given 240, so it's fixed the same way.

### Changed — README

- Removed the in-app-purchase mention from the roadmap's Lite entry.

### Known / deliberately unaddressed

- **22 `onChange(of:perform:)` deprecation warnings**, up from 20 in 1.5.3: two new sites in `ContentView` for persistent tabs (recording opened tabs, and the tab-visibility modifier). These were kept on the assumption that SNAP targets macOS 13.0; it actually requires 14.0 (see [1.5.5]), so the newer API is usable.

---

## [1.5.3] — 2026-09-30

**macOS 27 / Xcode 27 compatibility pass, five behavioral fixes, UniFi certificate pinning, and public-release prep.** Mostly a warning cleanup surfaced by building against the macOS 27 SDK with Swift 6.4. On top of that: five behavioral fixes (the board's "Run Now" button, the Dashboard over-polling ipinfo.io, a System Health score that could read "Excellent" on a bad connection, hard-coded values in the Status Board Wi-Fi tile, and a menu bar status dot that judged a single ping), a security hardening of the UniFi login, and the licensing and privacy documentation needed before SNAP is shared publicly. Build, Release build, and all 122 tests (90 existing + 32 new) pass clean. Requires **macOS 14.0** (this entry originally said 13.0 — see [1.5.5]).

### Security — UniFi login uses certificate pinning (trust on first use)

The UniFi client used `PermissiveTLS`, which accepts **any** certificate, on the connection that carries the controller's admin username, password, and 2FA code. On a network where someone can intercept traffic (ARP spoofing on a client site, for example), they could have collected UniFi admin credentials. Now ([UniFiControllerView.swift](SNAP/UniFiControllerView.swift)):

- **Publicly-trusted certificates** pass normal validation and are never pinned.
- **Anything else** (UniFi's default self-signed certificate) must match a SHA-256 fingerprint the user approved. On first contact, SNAP shows the certificate's subject and fingerprint in a sheet and asks. **Trust & Connect** pins it and logs in. Trust is never the default action, so Return can't approve a certificate by accident.
- **A changed certificate** is refused with a red "Controller certificate changed" sheet showing both fingerprints. Re-trusting is an explicit **Trust New Certificate**.
- **Refusal happens inside the TLS handshake** (`UniFiPinningDelegate` cancels the server-trust challenge), so the login request, and the credentials in it, are never written to the connection. Verified against a public self-signed test server and a real UDM: first contact is blocked, the correct pin gets HTTP 200, and a wrong pin is blocked.
- **Plain-HTTP controller URLs are refused.** Credentials are never sent unencrypted.
- The credential bar shows **Certificate pinned** (fingerprint on hover) with a **Forget** link. Pins are stored in UserDefaults under `unifi.certPins`, keyed by host:port. They're fingerprints, not secrets.
- `PermissiveTLS` remains for the Network Map's read-only HTTP banner grabs, which send no credentials.

### Fixed — Dashboard over-polled ipinfo.io (~2,900 requests/day)

The Dashboard's Connection Summary card refreshes every 30 s, and each refresh repeated **all three** public lookups: `api.ipify.org`, `api6.ipify.org`, and `ipinfo.io/json`. That's ~2,900 ipinfo requests a day with the Dashboard open, well past ipinfo's free anonymous allowance. It's the likely reason ipinfo rate-limited this Mac and broke Visual Trace's hop geolocation back in v1.5.1. Now ([ConnectionSummaryCard.swift](SNAP/ConnectionSummaryCard.swift)):

- **Public IP (ipify)** is re-checked when the card first opens, every 10 min, whenever the local network changes (interface, local address, gateway, SSID, or VPN state), and on a manual **Refresh**. A network change clears the old address, so the previous network's IP is never shown for the new one.
- **ISP / ASN / city (ipinfo)** is fetched once per public IP and kept for 24 h. The request now names the address (`ipinfo.io/<ip>/json`) so each cache entry describes exactly one IP. A failure, including ipinfo's rate-limit response, is never cached and retries after 5 min instead of every 30 s.
- The cache (`PublicInfoCache`) lives outside the card, because the card's model is recreated on every tab switch and a per-card cache would re-fetch on each Dashboard visit.
- **Latency pings are unchanged**: 1.1.1.1 and the gateway every 30 s, since those feed the live readouts.
- Net effect for a full day with the Dashboard open: **144 ipify checks and 1 ipinfo lookup, down from 2,880 each**, asserted by `PublicLookupPolicyTests` (8 tests). With ipinfo failing all day, retries are capped at 288.

### Fixed — System Health could read "Excellent" on a bad connection

The Status Board's System Health score ignored jitter and Wi-Fi signal, charged only 0.5 points per 1 % of packet loss, and applied a 40 ms internet-scale latency cutoff to *gateway* pings, which normally answer in 1–5 ms. The Gateway Latency tile's label had the opposite flaw: it classified only the **single latest ping**. So an unscrubbed v1.5.2 screenshot showed **98 "Excellent"** beside a 50 ms average, **63.7 ms jitter**, Wi-Fi quality 37, and a "Healthy · gateway" label from one 5 ms ping.

Both tiles, and the menu bar dot (below), now use one shared model, `ConnectionHealth` ([StatusBoardMonitors.swift](SNAP/StatusBoardMonitors.swift)), so they can't contradict each other:

- **Gateway-scale costs** over the 5-minute ping window. Latency costs nothing up to 10 ms, then 0.5 pt/ms (capped at 30). Jitter costs nothing up to 5 ms, then 1 pt/ms (capped at 25). Loss is 3 pts per % (capped at 80). Wi-Fi quality below 60 costs 0.5 pt per point (capped at 20), and only while Wi-Fi carries the default route. Each alert in the last hour costs 4 pts (capped at 20).
- **Calibrated together**: each gateway factor alone crosses from "Healthy" to "Slow" / "Unstable" exactly where the score drops from 90 (Excellent) to 89 (Good). Costs are rounded to 0.1 before comparing; otherwise one lost ping in 30 (3.333…% × 3 = 10.000000000000002) would tip Healthy/90 into Slow/89.
- **The summary names what's wrong**, worst first: e.g. "Jitter 64 ms · Latency 50 ms · Weak Wi‑Fi". It says "Latency stable · No packet loss" only when that's true.
- **Gateway label** gains **Unstable** (jitter or loss dominant, as opposed to Slow) and **Not responding** (every ping timed out, previously just "Degraded").
- **No more "Excellent" with no data**: before the first sample the tile shows "—" and "Measuring".
- Score colors now match the grades: green for Good and above, amber for Fair, red below.
- The Wi-Fi tile's quality ring uses the same RSSI mapping as the score.
- The screenshots' own numbers are now regression tests: 98 → **43 "Degraded"** and the marketing shot → **55 "Fair"**, both with a "Degraded" gateway (`ConnectionHealthTests`, 14 tests).

### Fixed — Status Board Wi-Fi tile showed hard-coded values

Four of the six detail cells in the Wi-Fi tile were mockup placeholders that were never wired to data, carried over from the v1.5.2 POC. **TX Rate** was always "1441", **Security** always "WPA3", **Noise** always "−95", **MCS** always "—", and **SNR** was computed as RSSI + 95 (assuming that fixed noise floor). Only RSSI and the quality ring were real. A v1.5.2 screenshot shows it: the Dashboard reported a real 288 Mbps while the Status Board said 1441. Now ([StatusBoardView.swift](SNAP/StatusBoardView.swift) `StatusBoardWiFi`, [StatusBoardTiles.swift](SNAP/StatusBoardTiles.swift) `SBWiFiTile`):

- **Every cell is a live CoreWLAN reading**, or "—" when unavailable: RSSI, **SNR** (RSSI minus measured noise), **TX Rate** in Mbps, **Security**, **Noise**, and **PHY**.
- **MCS is replaced by PHY** (Wi-Fi 4 / 5 / 6 / 6E / 7). CoreWLAN doesn't expose the MCS index. Wi-Fi 7 and the OWE security modes are matched by raw value, so SNAP still builds on SDKs that predate their Swift names.
- **Colors mean something**: SNR is green at ≥ 25 dB, amber at 15–25, and red below. Security is red for Open or WEP networks.
- **Security names are shared with the Dashboard** (`CWSecurity.snapLabel`), replacing the Dashboard's inline copy, so the two can't disagree. OWE networks now show "OWE" instead of "Unknown".
- When not associated, the tile says "Not associated" instead of "Hidden".
- Verified live on a Wi-Fi 6E / WPA3 network: TX Rate read 432 Mbps (the old tile said 1441). Noise and security happened to match the placeholders on that particular network, which is why they looked plausible.

### Fixed — menu bar status dot judged a single ping

The menu bar dot was green whenever the *latest* gateway ping was under 40 ms, and turned red on any single dropped ping. It ignored jitter and loss entirely and flapped on one lost packet. It now uses the shared `ConnectionHealth` model over the same 5-minute window as the Status Board, so **the dot, the Gateway Latency tile, and the System Health tile always agree** ([MenuBarView.swift](SNAP/MenuBarView.swift)):

- **Green** when healthy, **amber** when slow or unstable, **red** when degraded or not responding. `MenuBarMonitor` now publishes the `gatewayState`, and the Gateway tile reads that same value.
- **Outages are still caught quickly**: two timeouts in a row (≈ 20 s) mean "Router not responding" right away, whatever the rest of the window says. A single dropped ping no longer turns the dot red.
- **Recovery is honest**: after an outage the dot stays amber while the lost pings are still in the window (up to ~5 min), then returns to green.
- **The tooltip explains the color**, e.g. "SNAP · Gateway unstable · Jitter 20 ms · No packet loss (5 ms gw)".
- `LatencyStats` gained `trailingTimeouts` and an `init(history:)`, so tests can replay real ping sequences. They replay a full outage-and-recovery timeline (green → one drop stays green → two drops red → recovery amber → green) and a spiky gateway that the old rule showed green because its latest ping was 3 ms.

### Changed — credited to Sevag Bardakjian

SNAP is published under Sevag Bardakjian's name; "Bardak Labs" was never a legal entity. Updated file headers (11 files), the About window (the "Studio" row is removed), the footer of exported session reports, `NSHumanReadableCopyright` (now `© 2025–2026`), the privacy manifest comment, and the README. Internal UserDefaults/Keychain keys (`com.bardaklabs.snap.*`) are **unchanged**: renaming them would silently reset existing settings and saved UniFi passwords.

### Added — LICENSE and Privacy & Security documentation

- **[LICENSE](LICENSE)**: proprietary, all rights reserved. The compiled app is free to use; the source code may not be copied, modified, or redistributed. It also includes a no-warranty clause and a responsible-use clause for the scanning tools, and it reserves the option to change the license in future versions.
- **README § Privacy & Security**, based on an audit of the source: every host contacted automatically (with its interval) versus only on demand, local-network scanning behavior, system tools launched, permissions requested and why, everything stored on disk (with removal steps), and why SNAP is unsandboxed and allows plain HTTP.
- **Corrected the privacy manifest comment**, which claimed only user-invoked queries leave the Mac. Connectivity checks, public-IP/ISP lookups, and gateway pings run automatically while their views are open.

### Fixed — Status Board "Run Now" did nothing

The Speed Test tile's **Run Now** button shipped in v1.5.2 wired to `ToolHandoff.goto(.speedTest)`, which only switches `ContentView`'s `selectedTab`. But the Status Board is an `.overlay` on top of `ContentView` ([ContentView.swift](SNAP/ContentView.swift)) — so the tab changed *underneath a board that was still covering it* and nothing visibly happened. The label promised a test run; the code only navigated. Four parts to the fix:

- **An autostart sentinel.** The speed-test logic lives entirely inside `SpeedTestView` as `@State` + private methods, so there's no model a tile can drive directly — which is why v1.5.2 settled for "navigate." Added `ToolHandoff.autostartToken` ([ToolHandoff.swift](SNAP/ToolHandoff.swift)), a reserved handoff value meaning *navigate here and immediately start*, as opposed to the usual *navigate here and pre-fill this host*. The destination view recognizes it and kicks off the test itself.

- **Board dismissal is now mode-aware** ([StatusBoardTiles.swift](SNAP/StatusBoardTiles.swift) `SBSpeedTestTile.runSpeedTest()`). An in-window board is covering the very tab being navigated to, so it has to come down first. A *detached* board lives in its own `NSWindow` on (usually) a second monitor, so it stays up and only the main window is driven. Previously this was unconditional, which is the same bug class as the v1.5.1 detached-board Exit button.

- **`ConsumeHandoffModifier` no longer relies on `.onAppear` alone** ([ToolHandoff.swift](SNAP/ToolHandoff.swift)). Because the board overlays rather than replaces the tab, a view that was already selected never unmounts — so if you were *already* on the Speed Test tab, `.onAppear` never fired and the handoff sat unconsumed forever. The modifier now carries an `@ObservedObject` on `ToolHandoff` and also reacts to `pending` changing, keeping `.onAppear` for the fresh-mount case (`onChange` deliberately doesn't fire on first appearance). The missing `@ObservedObject` is the same SwiftUI view-diffing trap as the v1.5.0 theme-propagation bugs: without it the modifier's body is never re-evaluated, so `onChange` can't observe anything. **This fixes every handoff, not just Speed Test** — right-clicking a host and choosing "Send to Ping" while already sitting on the Ping tab was silently broken in exactly the same way.

- **Autostart forces the internet pane** ([SpeedTestView.swift](SNAP/SpeedTestView.swift)). `SpeedTestView` has two panes (`provider == .iperf` vs. the HTTP providers) and only the internet test writes to the `SpeedTestHistoryStore` the tile graphs. Left on the iPerf3 pane, autostart would have run the HTTP test *behind* a pane that never displays its progress — a second silent no-op. Now flips back to Cloudflare first. Also guards against restarting a test already mid-flight.

### Fixed — Swift 6 concurrency warnings (14 → 0)

Swift 6.4's stricter actor-isolation checking flagged main-actor-isolated members being reached from nonisolated contexts in the v1.5.2 Status Board monitors. Two distinct causes, two distinct fixes:

- **Pure-computation statics inside `@MainActor` classes.** A `@MainActor` annotation on a class also isolates its `static` members — including helpers that touch no actor state and are *deliberately* called off the main thread. Marked `nonisolated`: `DNSLatencyMonitor.dnsPing(server:)`, `TopTalkersMonitor.runNettop()`, `TopTalkersMonitor.parse(output:)` ([StatusBoardMonitors.swift](SNAP/StatusBoardMonitors.swift)), and `FavoritesManager.ping(host:)` ([FavoritesManager.swift](SNAP/FavoritesManager.swift)). These spawn subprocesses, run DNS queries, or parse strings — annotation-only change, zero runtime difference.

- **`Timer` / `asyncAfter` callbacks invoking MainActor methods.** Timer closures are nonisolated even when scheduled on `RunLoop.main`, so the compiler can't prove main-thread execution. Wrapped four call sites in `Task { @MainActor in … }`, matching the pattern already used by `FavoritesManager.startTimer()`: `DNSLatencyMonitor.probe()`, `SystemStatsMonitor.readAll()`, `TopTalkersMonitor.sample()`, `PublicIPMonitor.refresh()`. These callbacks now hop through the actor scheduler rather than running synchronously inside the timer fire — functionally identical for all four (low-frequency pollers at 3 s / 4 s / 10 s / 600 s), but a real if tiny semantic change rather than pure annotation.

### Fixed — missing `Combine` import (4 → 0)

`SidebarFooter` in [ContentView.swift](SNAP/ContentView.swift) exposes a `Timer.publish(every:on:in:).autoconnect()` stored property, whose type (`Publishers.Autoconnect`) comes from Combine — which the file never imported. Swift 6.4 warns that the type isn't visible in the declaring file. Added the explicit `import Combine`.

### Fixed — `ViewBuilder` limited-availability warning (2 → 0)

[GeoIPView.swift](SNAP/GeoIPView.swift)'s `mapPane(_:)` had an `if #available(macOS 14, *)` as its *entire* function body, so the macOS-14-only `GeoIPMapView` type leaked directly into the function's opaque `some View` return signature. The compiler warned the resulting `_ConditionalContent` metadata may not be instantiable on macOS 13 ("this code may crash on earlier versions of the OS").

Fixed by type-erasing both branches through `AnyView` and extracting the Ventura fallback into its own `legacyMapPane(_:)`. An initial attempt to wrap the `#available` in a `Group` — matching the pattern `VisualTraceRouteView` uses for `TraceMapView` — made things *worse*, relocating the warning into `Group`'s builder and adding four new `TupleContent` availability warnings; `AnyView` erasure is the correct fix here because this is a standalone builder function rather than an inline branch in a larger hierarchy.

### Known / deliberately unaddressed

- **20 `onChange(of:perform:)` deprecation warnings** across 11 files: `AlertManager` (3), `SubnetCalculatorView` (3), `BandwidthMonitorView` (2), `CommandPalette` (2), `InfoView` (2), `PortScanView` (2), `VisualTraceRouteView` (2), and one each in `ContentView`, `StatusBoardTiles`, `SyslogReceiverView`, and `ToolHandoff`. The replacement two-or-zero-parameter `onChange` is **macOS 14+**, and SNAP's deployment target is macOS 13.0 (with deliberate `#available(macOS 14, *)` map fallbacks in GeoIP and Visual Trace backing that up). Deprecated is not removed — the old API still works identically. Left as-is rather than bumping the deployment target or introducing a compatibility shim. Revisit if Apple ever actually removes the API, or whenever macOS 13 support is dropped. **Correction:** builds actually required macOS 14.0, not 13.0 (see [1.5.5]), so the replacement API was usable all along.

  Two corrections to what an earlier draft of this entry claimed: the count is **20 sites across 11 files, not 13 across 10**. A clean build emits 40 of these lines because each site is logged twice (two compile passes), and the original figure came from miscounting that output. The `ToolHandoff` site is new in this release — it's the `onChange` added by the "Run Now" fix above, and it's unavoidable at deployment target 13.0 for the same reason as the other 19.

### Toolchain note

If `xcodebuild` fails with *"tool 'xcodebuild' requires Xcode, but active developer directory is a command line tools instance"* after a macOS major upgrade, the installer reset `xcode-select`. Fix: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. Xcode GUI builds are unaffected; only command-line tooling reads that setting.

---

## [1.5.2] — 2026-06-30

**Status Board rework.** The board's visual language got a full pass — richer tiles with area-fill sparklines, ring gauges, timelines, and stat rows — and grew from 6 tile types to 9. Header gained a theme picker (no more leaving the board to switch themes) and a compact Public IP chip. Three new POC-approved-and-shipped tile categories.

### Added — three new tile types

- **DNS Latency** ([StatusBoardMonitors.swift](SNAP/StatusBoardMonitors.swift) `DNSLatencyMonitor`). Round-trip UDP/53 timing to the configured resolver list — System (first entry from `DNSInfo.systemResolvers()`), Cloudflare (1.1.1.1), Google (8.8.8.8), Quad9 (9.9.9.9). Re-probes every 10 s via the existing `DNSWire` querier. Bar chart per resolver, color-coded (green ≤30 ms · amber ≤80 · red beyond or timeouts). Reveals things like a slow ISP resolver at a glance.

- **System** — Mac uptime + CPU load + memory pressure + battery. `SystemStatsMonitor` reads uptime via `sysctl(KERN_BOOTTIME)`, CPU via `host_statistics(HOST_CPU_LOAD_INFO)`, memory via `host_statistics64(HOST_VM_INFO64)` + `host_page_size`, battery via `IOPSCopyPowerSourcesInfo`. Refreshes every 3 s. All native — no shell-outs.

- **Top Talkers** — per-process bandwidth via `nettop -P -x -k pid,command,bytes_in,bytes_out -L 2 -s 1`. Top 5 by total throughput with dual RX/TX bars. Some macOS installs may need Full Disk Access for nettop to enumerate all processes — the tile shows a friendly note when the output is empty despite nettop returning cleanly.

### Added — Status Board chrome

- **Theme picker in the header** — the existing `ThemePicker` from `Themes.swift` now lives in the Status Board's edit controls alongside Add Tile / Edit, so you can flip themes without leaving the board. Nord, Cyberpunk, Matrix, whatever — instant.

- **Public IP chip in the header sub-line** — new `PublicIPMonitor` fetches once from `ipwho.is` on open, refreshes every 10 min. Renders as a compact chip (`🇺🇸 203.0.113.42 · Example ISP · AS64500`) next to the date. Right-click gives you the full host menu. Doesn't burn a tile slot. Considered a full tile in POC, minimized here on user feedback.

### Enhanced — six existing tiles

- **Bandwidth** — dual area sparklines instead of stacked half-cells, session peak markers for RX/TX, and a new footer row showing session totals (Session ↓ / Session ↑ / Uptime / Interface). Session totals accumulate from `bwMonitor.rxHistory` sample rates × sample interval.

- **Wi-Fi** — replaced the single big RSSI number with a **quality ring** (0–100 derived from RSSI: −40 dBm ≈ 100, −85 ≈ 0) + a 6-cell detail grid (RSSI / SNR / TX Rate / Security / Noise / MCS). Much more information at the same glance-cost.

- **Gateway Latency** — ring gauge around the current ping value (fills as latency approaches 200 ms), area sparkline of the last 30 samples, and a five-cell stat row (Min / Avg / Max / Jitter / Loss). Added `latencyHistory: [Double?]` + `latencyStats` on `MenuBarMonitor` so the tile has real min/max/jitter/loss data instead of stubs. Timeouts stored as `nil` in history so loss % is computed correctly.

- **System Health** (the "useless" tile from user feedback) — full reimagining. **Composite health score 0–100** in a ring gauge (100 minus penalties for high latency, packet loss, and recent alerts). A grade word (Excellent / Good / Fair / Degraded / Poor), a one-line description ("Latency stable · No packet loss"), and a "CLEAN FOR 3h 12m" stat that gives context even when nothing's wrong. Below: a **4-hour activity timeline** (48 five-minute buckets) colored by max severity in each bucket — you can see when things went bumpy even at a glance.

- **Speed Test** — history sparkline of recent download speeds (last 20 tests, reversed), timestamp of last test, "↑ N% vs 7-day avg" comparison line, and an inline **Run Now** button that routes via `ToolHandoff.shared.goto(.speedTest)` — no more leaving the board.

- **Favorites** — kept the v1.5.1 layout (segments, uptime %, sparkline, hover-reveal ✕) unchanged; visual language matches the rest of the tile grid now.

### Added — reusable components

New in [StatusBoardTiles.swift](SNAP/StatusBoardTiles.swift):
- **`RingGauge`** — trimmed circle stroke driven by a `progress: Double` (0…1) with color + linewidth control. Used by Wi-Fi, Gateway Latency, and System Health.
- **`AreaSparkline`** — line + area-fill sparkline. Handles `[Double?]` (nil samples break the line, useful for ping loss visualization). Used by Bandwidth, Gateway Latency, Speed Test.
- **`StatusPill`** — colored inline pill for the tile-header "LIVE" indicator.
- **`ByteFormat`** — shared byte-count formatter (`rate(_:)` for per-second, `size(_:)` for cumulative).

### Deferred (called out honestly, not lost)

- **Weather chip** — WeatherKit needs a paid Developer Program entitlement; picking an alternate free API (Open-Meteo, etc.) requires an API decision. Skipped for v1.5.2, revisit if you want a lifestyle indicator.
- **Multi-board picker + saved layouts** — full feature (Home / Debug / Ambient / Client Demo). v1.5.3+.
- **Snapshot to PNG** — feature-scale. v1.5.3+.
- **Auto-cycle boards** — depends on multi-board.
- **Interface breakdown chips under Bandwidth** — space in the tile got claimed by the session-totals row; kept the "Interface" cell in that row instead.

---

## [1.5.1] — 2026-06-30

Post-launch polish + fixes on top of v1.5.0. Substantial expansion of Status Board features (customizable tiles, drag-reorder, detach-to-window), right-click coverage across every host-bearing surface in the app, adaptive Favorites cadence with RTT sparklines, tool handoff plumbing, `dig` shell-out cleanup, a "Why this classification?" popover on Network Map devices, plus a service-fix pass for Visual Trace and GeoIP.

### Added — power-user combo (⌘K, Status Board, Favorites, right-click, history, tilt, heartbeat)

Seven features bundled into one batch, each small on its own but bigger together — SNAP starts to feel like an integrated environment instead of a collection of tools.

- **⌘K Command Palette** ([CommandPalette.swift](SNAP/CommandPalette.swift)). Spotlight-style modal, opens via `⌘K` from anywhere. Categorized list of every tool (NAV), every theme (THEME), and the common actions (ACTION). Smart inline parsing: type `ping 1.1.1.1`, `lookup github.com`, `trace 8.8.8.8`, `scan 192.168.1.1`, `whois apple.com`, `geo 8.8.8.8`, `bgp 8.8.8.8`, or `http https://…` and a "Run" action appears at the top — Enter jumps to the destination tab with the host pre-filled.

- **Status Board / kiosk mode** ([StatusBoardView.swift](SNAP/StatusBoardView.swift)). Fullscreen ambient overlay you can throw on a spare monitor. Giant bandwidth numbers + sparkline, big Wi-Fi RSSI gauge with band/channel, alerts panel, live clock + version. Trigger via the new "Status Board" toolbar button or `⌘⇧B`. Esc to exit.

- **Pinned hosts (Favorites)** ([FavoritesManager.swift](SNAP/FavoritesManager.swift)). Up to 10 favorite hosts (router, work VPN, public DNS, whatever) persist to UserDefaults and get re-pinged every 30 s. A horizontally-scrollable Favorites strip appears above the Dashboard grid when you have any — click any row to Ping with the host pre-filled, right-click for the full host menu. Add via the "+ Add" popover or the new "Add to Favorites" context menu action.

- **Smart right-click on hosts** ([HostContextMenu.swift](SNAP/HostContextMenu.swift)). New `.hostMenu(host, selectedTab:)` modifier wraps any host display with a context menu: Copy, Send to Ping / Traceroute / Port Scan / Lookup / Whois, Find in Network Map, Add to / Remove from Favorites. Applied to Favorites strip rows in v1; will expand to ConnectionSummary, Network Map, and result tables in a follow-up.

- **Per-tool input history** ([ToolHandoff.swift](SNAP/ToolHandoff.swift) `ToolHistory` + `HistoryMenuButton`). Each functional tool keeps up to 10 recent inputs (`com.bardaklabs.snap.history.v1.*`). A clock-icon menu next to every Ping / Lookup / Traceroute / Port Scan / Whois / GeoIP / BGP / HTTP input — both on the dashboard cards and the full tool views — lets you re-run any recent value with one click. "Clear history" inside the menu.

- ~~**3D card tilt on hover**~~ — **dropped from v1.5.0**. Initial wiring on the dashboard grid broke hit-testing for nested TextFields and buttons (the combination of `.onContinuousHover` + `.rotation3DEffect` swallows mouse-down events on macOS). The `CardTilt.swift` file was removed entirely. Will revisit with an `NSEvent.addLocalMonitorForEvents` approach in a later release.

- **Menu bar heartbeat** ([MenuBarView.swift](SNAP/MenuBarView.swift) + [SNAPApp.swift](SNAP/SNAPApp.swift)). `MenuBarMonitor` gained a `health` state derived from a periodic gateway ping (every 10 s) and the existing path monitor — `.good` / `.warn` / `.bad` / `.offline` / `.unknown`. The `MenuBarExtra` label is now a custom view (network icon + colored dot) so you can glance at the menu bar to see whether the connection is healthy. Hover for a tooltip with current latency.

- **Tool handoff** ([ToolHandoff.swift](SNAP/ToolHandoff.swift)). Cross-cutting plumbing for the above. `ToolHandoff.shared.send(value, to: .ping, selectedTab:)` stages a value, switches tabs, and the destination view consumes it via `.consumeHandoff(for: .ping) { host = $0 }`. Wired into 8 full tool views: Ping, Lookup, Whois, Traceroute, Port Scan, GeoIP, BGP/ASN, HTTP Probe.

### Added — host context menu extended + Status Board detachable

Two post-combo refinements that close out the deferred items from the combo batch.

- **Smart right-click coverage extended.** The `.hostMenu(host)` modifier now wraps host displays in four more places: **Network Map** (DeviceCard's IP row + ListView's IP table column), **ConnectionSummary hero card** (Public v4 / Public v6 / Gateway / Internet rows — the `row(label:monoText:)` helper grew an `isHost: true` flag), **ARP Table** (IP column), and **DHCP Leases** (Client IP / DHCP Server / Router rows via a new `kvHost` helper). Every right-click offers the same Copy / Send to Ping / Traceroute / Port Scan / Lookup / Whois / Find in Map / Add to Favorites menu. ToolHandoff refactored along the way — `send(_:to:)` no longer needs a `Binding<SNAPTab>` parameter; navigation routes through a `@Published requestedTab` that ContentView observes and clears, so chrome views can attach `.hostMenu` without plumbing the tab selection through every layer.

- **Status Board detach-to-window.** New `StatusBoardWindowController` ([StatusBoardWindow.swift](SNAP/StatusBoardWindow.swift)) spawns a separate `NSWindow` containing the same `StatusBoardView`. If a secondary screen is connected, the window opens there and toggles fullscreen automatically — the "throw it on a spare monitor" workflow. Otherwise the window opens centered on the main screen at 1200×800. A new "Detach to window" button in the in-window overlay's bottom-right kicks it off; closing the window via the red traffic-light dot flips state back. `StatusBoardManager` gained `isDetached` published state and `detach()` / `attach()` / `detachedWindowDidClose()` methods to coordinate. The `⌘⇧B` shortcut and the existing toolbar button still toggle the in-window mode unchanged.

### Added — Status Board customizable tiles + right-click coverage round 2

Builds on the earlier Status Board + host-menu work.

- **Status Board tiles are now customizable.** New `StatusBoardLayout` singleton + `StatusTileKind` catalog ([StatusBoardTiles.swift](SNAP/StatusBoardTiles.swift)) replaces the hardcoded 3-panel layout. Six tile types ship: **Bandwidth**, **Wi-Fi**, **Alerts** (the originals), plus **Favorites** (pinned hosts with live status), **Gateway Latency** (the value driving the menu bar heartbeat, rendered big), and **Latest Speed Test**. Toolbar adds **+ Add Tile** (sheet listing the catalog with already-pinned items dimmed) and **Edit Mode** (dashed-amber borders, red ✕ to remove). Layout persists to UserDefaults per user. Default = the original three.

- **Status Board logo.** Header switched from the `scope` SF Symbol to the real `NSApp.applicationIconImage` (same pattern as the Onboarding tour's Welcome slide).

- **Smart right-click — second pass.** `.hostMenu` extended to four more high-traffic surfaces: **Traceroute** hop rows (the IP cell), **DNS Lookup** answer rows (the Value column), **Connections** table (both Local Address and Remote Address columns), and **Bonjour** discovered services (each IP in the Addresses detail section). Every right-click offers the same Copy / Send to Ping/Traceroute/Port Scan/Lookup/Whois / Find in Map / Add to Favorites menu.

- **Smart right-click — third (mop-up) pass.** Four more surfaces wired: **Multi-Host Compare** (host name cell), **Bulk Discovery** (IP column — TableColumn switched to the closure form since the table isn't sortable), **Fingerprint** (IPv4 Address / IPv6 Address / Reverse DNS rows via a new `fingerprintRow` helper that conditionally attaches the menu by key), and **Visual Traceroute** (hop IP labels, skipping when the value is `*` or empty). With this pass, every result surface in SNAP that has a meaningful per-row host now supports the host context menu. Two views are intentionally NOT wired: **PingView** (per-result rows are seq+RTT, no per-row host) and **WhoisView** (raw text output — would need parsing).

### Added — Status Board tile reordering + per-favorite remove

- **Drag-to-reorder tiles in Edit Mode.** Mirrors the Dashboard pattern. `StatusBoardLayout` gained `move(_:to:)`, plus a new `StatusTileReorderDropDelegate` and a `.tileDraggableWhenEditing` view modifier that only attaches `.onDrag` / `.onDrop` when Edit Mode is on (so clicks pass through cleanly otherwise). Source tile fades to 40% opacity during drag, grid rearranges live as the dragged tile hovers over targets, and the new order persists to UserDefaults.
- **Per-favorite remove from the Status Board.** Each row in the Favorites tile now shows a small red ✕ button on the right when the cursor hovers it (invisible at rest so the layout stays clean). Click to remove that favorite. Right-click "Remove from Favorites" via the host menu still works as a second path.

### Added — Favorites RTT sparklines + adaptive ping cadence

Following user feedback on the Status Board Favorites tile.

- **RTT sparkline per row.** `FavoritesManager` gained a rolling 30-sample history of successful ping RTTs per favorite (timeouts excluded so the chart isn't distorted by zero-spikes). Each row in the Status Board's Favorites tile now renders a 70×22pt `MiniSparkline` between the label/IP block and the current RTT value, colored to match the host's health state.
- **IP visible alongside label.** Each row shows the favorite's host (small monospaced, dimmed) directly under the label so you can identify devices at a glance without hovering.
- **Adaptive ping cadence.** `FavoritesManager.setRefreshMode(active:)` swaps the timer between 10 s (Status Board visible) and 30 s (idle). `StatusBoardManager` calls this from `didSet` observers on `isPresented` and `isDetached`, so opening or detaching the board tightens cadence to keep the sparklines feeling live, and closing both modes relaxes it so we don't burn pings when nobody's looking.
- **Right-click on rows.** Each Favorites-tile row now has a `.hostMenu` attached, matching every other host-bearing surface in the app.

### Added — "Why this classification?" popover on Network Map

Every device in the Network Map's card view now has a small **ⓘ** button in the top-right corner (only shown when the device has discovery signals). Click it for a popover listing every signal that voted on the device's identity: mDNS service hits, SSDP responses, NetBIOS names, HTTP banner grabs, MAC OUI vendor matches, UBNT discovery, reverse DNS, etc. — each with the raw value the model saw. Footer shows the final role the merger picked. Useful when the model picks a surprising label and you want to trust (or refute) it. The signals were already collected by `DeviceIdentifier`; this is purely a UI surface on existing data. Implementation: new `SignalsPopover` view in [NetworkMapView.swift](SNAP/NetworkMapView.swift).

### Refactored — `dig` → DNSWire (shell-out cleanup, complete)

Migrated the last three `/usr/bin/dig` callers in [FingerprintView.swift](SNAP/FingerprintView.swift) (A-record resolve, AAAA-record resolve, reverse-DNS via `dig -x`) over to the native UDP/53 `DNSWire` querier introduced in earlier releases. Reverse-DNS builds the `in-addr.arpa` name and queries PTR directly. Net effect: SNAP no longer shells out to `dig` anywhere. The remaining shell-outs are `ping`, `traceroute`, and `arp` — `ping`/`traceroute` likely stay (raw sockets need entitlements); `arp` migration is queued as the last cleanup item.

### Fixed — three regressions found during user testing

- **Right-click menus didn't actually open** on most of the surfaces I'd "wired" them onto. `.contextMenu` only triggers when the click lands inside the view's hit area, and on plain `Text` views the hit area is just the rendered glyphs — clicking the empty space around the text registered nothing, so the menu never appeared. Fixed by adding `.contentShape(Rectangle())` inside `HostContextMenu` so the full bounds of any wrapped view become hit-testable. The menu now fires across the entire row regardless of where exactly the cursor sits.
- **Status Board "Exit · Esc" button did nothing in the detached window.** Both the button and the Esc keyboard shortcut were unconditionally setting `mgr.isPresented = false` (which only controls the in-window overlay) — in the detached window context, that flag was already false and clearing it again did nothing. Fixed with a new `dismissBoard()` helper that closes the `NSWindow` via `StatusBoardWindowController.shared.close()` when `mgr.isDetached`, then clears the overlay flag.
- **Favorites tile in the Status Board had no way to add favorites.** The empty-state text said "add via the Dashboard's Favorites strip or right-click any IP" — which also wasn't working because of bug #1. Added a "+ Add favorite" button directly in the Favorites tile (both in the empty state and below the populated list) with an inline popover for label + host entry. Add from anywhere now.

### Fixed — Visual Trace map + GeoIP hostname lookups

Two external-service failures reported during user testing.

- **Visual Trace hops never plotted on the map.** The per-hop geolocation call was querying `https://ipinfo.io/{ip}/json`, but ipinfo.io has been aggressively rate-limiting anonymous (no-token) requests. Every lookup silently returned nothing (the `catch {}` swallowed errors), so no coordinates ever attached to hops and the map stayed empty regardless of how many public IPs the traceroute captured. An intermediate attempt on `ip-api.com` also failed silently in the field. Final fix: migrated `VisualTraceRouteView.geolocate(hop:)` to **`https://ipwho.is/{ip}`** — the same service the GeoIP Lookup tab has been hitting reliably. HTTPS (no ATS concerns), NSNumber-safe number parsing so integer coordinates like `39` parse correctly (previously `as? Double` could silently fail if the API returned a whole number), and the `catch {}` block now `NSLog`s failures instead of swallowing them so future issues surface in Console.app.
- **Nation flag next to each hop's location.** `GeoHop` gained `countryCode: String` populated from ipwho.is's `country_code` field. The existing `flagEmoji(for:)` helper (which expected an ISO 2-letter code but was being passed the country *name* — always returning empty) now receives the right input. Flag rendered inline with the city/country line (🇺🇸 Pasadena, United States) rather than next to the IP.
- **GeoIP Lookup returned "404 not found" on hostnames.** The error message was actually coming from `ipwho.is`'s own JSON response — their hostname-resolution path is flaky, particularly on CDN-fronted `.com` domains (`porsche-leipzig.com` was the reproducer). Their IP-lookup path works reliably. Fixed by **pre-resolving hostnames to an IP via `getaddrinfo` in the app** before hitting their API. `GeoIPView.lookup(query:)` now branches: numeric input → straight to `ipwho.is`; hostname → `getaddrinfo` on a background queue → send the resolved IP to `ipwho.is`. Added `looksLikeIP` (uses `AI_NUMERICHOST`) and `resolveIPv4` helpers.

---

## [1.5.0] — 2026-06-26

### Added — customizable Dashboard

The Dashboard is no longer a fixed 2×2 grid of canned panels. The Connection Summary hero stays anchored at the top; everything below it is a user-customizable LazyVGrid of pinned tool cards. Layout is persisted to UserDefaults per user.

Three card buckets, each visually tagged:

- **Functional** (10) — full mini form + results inline: Ping, DNS Lookup, Port Scan, Subnet Calc, BGP/ASN, **Traceroute**, **GeoIP**, **Whois**, **HTTP Probe**, **Wake-on-LAN**.
- **Live** (3) — auto-refreshing summary with a pulsing green dot: Bandwidth, Wi-Fi, Recent Alerts.
- **Launcher** (11) — tile that opens the full tab: Network Map, Packet Capture, Bulk Discovery, UniFi, Speed Test, Connections, **SSL/TLS**, **MTU Discovery**, **MTR**, **Syslog**, **SNMP**.

**24 cards total** across the catalog — most of the SNAP tool surface is one click away from the Dashboard.

Toolbar gains: **+ Add Tools** (categorized modal with type tags), **Edit Mode** (dashed-border state + red ✕ to remove), **Reset Layout** (restores defaults), and **drag-to-reorder** inside Edit Mode — the grid rearranges live as you hover the dragged card over targets, and the new order persists to UserDefaults. Removed the broken `DashPanel` chrome + four hardcoded panel helpers (~280 LOC). New file: [DashboardCards.swift](SNAP/DashboardCards.swift) — `DashboardLayout` (persistence + reorder), `DashCardChrome`, `AddToolsSheet`, `DashCardBody` router, 14 custom card structs (the functional + live ones plus Speed Test), shared `LauncherCardBody` for the simple launchers, and `CardReorderDropDelegate`.

### Added — Themes

App-wide color theming. Pick a theme from the new picker in the Dashboard toolbar or under **View → Theme** in the menu bar; the choice persists across launches.

Ten themes ship in v1.5.0:

- **Built-in** — Midnight (default), Daylight (light mode)
- **Developer** — Nord, Solarized Dark, Tokyo Night, Dracula
- **Themed** — Matrix, Cyberpunk, DeeX (Deus Ex: Human Revolution / Sarif Industries gold-on-black), Synthwave '84

How it works: every view in SNAP already reads colors through a central `NS` palette. v1.5.0 changes `NS.X` from a static constant to a computed property that forwards to `ThemeManager.shared.current.X` — so changing the active theme cascades into every view that already used `NS`, no per-view changes needed. New file: [Themes.swift](SNAP/Themes.swift) defines the `Theme` struct, `ThemeManager` singleton, the 10-theme catalog, and the `ThemePicker` view.

### Refactored — DeviceIdentifier god-file split

`DeviceIdentifier.swift` had grown to 1351 lines covering identity types, role classification, the orchestrator, and four distinct multicast/broadcast discovery probes. Split into three focused files (no behavior change, no test changes):

- **[DeviceIdentity.swift](SNAP/DeviceIdentity.swift)** (478 lines) — `DeviceRole`, `DeviceGroup`, `IdentitySignal`, `DeviceIdentity` struct, and the string-pattern → role classification heuristics.
- **[DeviceIdentifier.swift](SNAP/DeviceIdentifier.swift)** (193 lines, trimmed) — the orchestrator + simple per-device probes (Reverse DNS, HTTP banner grab, `PermissiveTLS` URLSession delegate).
- **[DiscoveryProbes.swift](SNAP/DiscoveryProbes.swift)** (708 lines) — the LAN-sweep probes: NetBIOS Node Status (UDP/137), SSDP M-SEARCH, UBNT broadcast + wire parser + unicast, mDNS collector.

The largest file in this group went from 1351 → 708 lines (a 48% drop). The orchestrator is now a quick read.

### Added — first-launch Quick Tour

A 5-slide welcome modal that opens automatically on first launch (gated by a UserDefaults flag) and is re-openable from **Help → Quick Tour…** anytime. Helps new users discover the customizable Dashboard, the 38-tool sidebar, and the theme picker before they're staring at an unfamiliar surface.

Slides cover: welcome + app stats, the customizable Dashboard, the sidebar tool catalog organized by category, the 10 themes with sample swatches, and a Pro Tips card listing the keyboard shortcuts that matter (⌘⇧R session report, ⌘⇧E per-tool export, Edit Mode drag-to-reorder, Help → Quick Tour re-trigger). Uses `NSApp.applicationIconImage` for the welcome slide so a future per-theme icon swap would Just Work. New file: [OnboardingView.swift](SNAP/OnboardingView.swift) — `OnboardingManager` singleton, modal sheet with per-slide visuals, all theme-aware.

### Fixed

- **Locale-formatting bug** in the new Dashboard cards. SwiftUI's `Text("\(int)")` treats the literal as `LocalizedStringKey`, which applies thousands separators to integer interpolations (port 8080 rendered as "8,080", AS15169 as "AS15,169"). All integer-rendering sites in [DashboardCards.swift](SNAP/DashboardCards.swift) now use `Text(verbatim:)`.

- **Pulse dot overlap** in live-card headers. The pulsing green dot was rendered as a ZStack overlay in the top-right corner, where it stacked on top of the "LIVE" type tag. Moved inline 5 pt to the left of the tag.

- **Theme propagation gaps.** SwiftUI doesn't know `NS.X` depends on `ThemeManager` — every view that uses `NS` needs an explicit observer dependency for its body to re-evaluate on theme switch. Three flavors of this bug found and fixed:
  - **Cached colors in `MenuBarView`** — the popover stored `private let bg0 = NS.bg0`, freezing values at first init. Converted to computed properties.
  - **Top-level chrome** (`IconRail`, `DarkSidebar`, `SidebarFooter`, `DashboardView`) had stored bindings that didn't change on theme switch, so SwiftUI skipped body re-evaluation. Each now declares `@ObservedObject private var themeMgr = ThemeManager.shared`.
  - **The 14 dashboard cards** (`ConnectionSummaryCard`, `DashCardChrome`, `PingDashCard`, the rest) had the same diff-skip issue — they would appear to "catch up" 10-15 seconds after a theme switch when an unrelated timer or hover triggered re-render. Each card now observes `ThemeManager` directly, so theme changes repaint the entire Dashboard instantly.

- **Duplicate "View" menu** in the macOS menu bar. `CommandMenu("View")` collided with AppKit's auto-injected View menu and produced two of them. Renamed to `CommandMenu("Appearance")` — the Theme submenu now lives under its own dedicated menu (`Appearance → [theme list]`).

### Known limitations (themes)

- **System materials and the macOS sidebar** (`NSVisualEffectView`, `.regularMaterial`, `.sidebar`) blend with the desktop and don't fully respect a custom theme. The Daylight theme in particular still shows dark system chrome on the standard sidebar — full light-mode bleed-through needs `NSAppearance` set to `.aqua`. Deferred to a follow-up.
- **A handful of view-internal hardcoded `Color(...)` literals** (most notably WiFi Analyzer's per-SSID palette) intentionally bypass the theme to keep distinct chart series differentiable. Acceptable for v1; flagged for review if any feel off in specific themes.

---

## [1.4.5] — 2026-06-10

### Fixed — crash & hang patch (no new features)

Stability pass driven by a full-codebase review.

- **Pipe deadlocks.** Three `Process` call sites waited for child exit *before* draining the pipe — a permanent deadlock once output exceeds the ~64 KB pipe buffer. The worst (Connections' 3-second `netstat` auto-refresh) could pile up blocked tasks until the whole app's async machinery stalled. All now drain to EOF first, matching `Shell.run`: [ConnectionTableView.swift](SNAP/ConnectionTableView.swift), [NetworkUtilities.swift](SNAP/NetworkUtilities.swift) (`ifconfig -a`), [BulkDiscoveryView.swift](SNAP/BulkDiscoveryView.swift) (`arp -an`). Auto-refresh also guards against overlapping ticks now.
- **Input-validation traps.** Reversed port ranges (`8080-80`) crashed Port Scan; `0.0.0.0`/`255.255.255.255` at /32 crashed Subnet Calc on every keystroke; >63-byte DNS labels trapped the query builder (now a clear "Invalid hostname" error); oversized SNMP OID arcs overflowed the BER encoder (X.690 arc rules enforced, `iso.` prefix now correctly maps to arc 1 instead of being dropped). Subnet Calc is also RFC-3021-correct now: /31 → 2 usable hosts, /32 → host route.
- **NULL `ifa_addr` guards (×12).** Every `getifaddrs` walk dereferenced `ifa_addr` unchecked; it is legitimately NULL on some PPP/tunnel pseudo-interfaces — including in the menu-bar sampler that runs every second and the VPN-detection loop that specifically iterates tunnels.
- **Syslog receive loop** no longer busy-spins a core at 100% when a flow dies — errors now stop the re-arm. **Port Scan** no longer leaks an `NWConnection` per closed port (tens of thousands on a full-range scan).

### Fixed — lifecycle pass

Switching tools recreates the view; running work used to be orphaned with no handle left to stop it.

- **Teardown on tab switch** for Ping, Traceroute, Visual Trace, Packet Capture (`tcpdump` kept sniffing), Syslog (leaked the bound UDP socket), Routing Hello (multicast joins never left), WiFi Analyzer (live mode kept hitting the radio every 5 s *forever* — run loops retain repeating timers), Port Scan, and Bulk Discovery. `deinit` backstops added where models own sockets/timers.
- **Speed test Stop actually stops.** The Cloudflare download is cancellation-aware (Stop used to silently finish the in-flight 25 MB chunk and clobber the "Stopped" status); stopping mid-upload no longer flips to "Complete" and **no longer saves a partial result to history**. iperf3 now runs via `terminationHandler` instead of blocking a cooperative-pool thread for the full 10 s run — and Stop genuinely terminates it.
- **Bandwidth latency sampler**: fixed an unsynchronized cross-thread mutation of the sample arrays and a leak of one `NWConnection` per 3-second sample for connections stuck in `.preparing`; timeouts now count as packet loss.
- **Stale-run interleaving.** A stopped ping/traceroute/capture could still flush buffered lines into a *new* run's table (the scrambled-chart bug — out-of-order seq values made `LineMark` double back across the plot). Runs now carry a generation token; callbacks from a superseded run are dropped.

### Removed

- **The global Export sheet (⌘⇧E)** — it had no data source wired and always exported an empty header file. Per-tool export (toolbar Copy/TXT/CSV/JSON) and the ⌘⇧R session report are the working paths and are unchanged. `ExportManager.swift` deleted.

### Changed

- **Version strings single-sourced** from `MARKETING_VERSION` via a new `AppInfo.version` ([SNAPApp.swift](SNAP/SNAPApp.swift)) — the menu bar and session reports had been shipping a stale hardcoded "v1.2.4" since two releases back.
- New regression tests: subnet /32 at address-space edges, RFC 3021 expectations, SNMP OID arc validation + encoder overflow safety.

---

## [1.4.4] — 2026-05-24

### Changed — shell-out → native APIs (tech-debt, no new features)

First incremental pass at replacing CLI subprocess spawns with native system APIs — removes CLI output-format fragility, kills the main-thread/process overhead, and moves toward a future sandboxable Lite build.

- **Default route via `SCDynamicStore`.** New `RouteInfo` helper ([NetworkUtilities.swift](SNAP/NetworkUtilities.swift)) reads the default gateway + primary interface from `State:/Network/Global/IPv4` instead of parsing `netstat -rn -f inet`. Replaced **7 `netstat` call sites → 1** (the lone remaining `netstat` is the TCP socket list in Connections): NetworkInfoProvider, ARP Table, Device Identifier, Connection Summary (×2), Session Report, and the Menu Bar widget (which also dropped its `/sbin/route -n get default` spawn).
- **System DNS resolvers via `SCDynamicStore`.** New `DNSInfo` helper reads `State:/Network/Global/DNS` `ServerAddresses` instead of parsing `scutil --dns` — eliminated both `scutil` sites (Connection Summary, Session Report).
- **Reverse/A-record resolution via `getaddrinfo`.** Multi-Host Compare's DNS check no longer shells out to `/usr/bin/host`.
- **Banner grab via `NWConnection`.** Fingerprint's service-banner probe replaced the `/usr/bin/nc` spawn with a native TCP connect + receive (also fixed a non-Sendable capture in the WiFi scanner along the way).

Net: subprocess command types dropped from 12 → 8; the highest-traffic offender (`netstat` gateway parsing, the memory-flagged one) is effectively gone.

### Still shelling out (deferred to later passes)

- `ping` (×9) and `traceroute` (×3) — require raw ICMP / TTL socket rewrites; highest effort, deferred.
- `arp` (×4) — readable via `sysctl NET_RT_FLAGS`; medium effort, next candidate.
- `dig` (×3) — can route through the existing `DNSWire`; medium effort.
- `ipconfig` (×2, DHCP lease) and `ifconfig` (×1, media/duplex via `SIOCGIFMEDIA`) — no clean public-API equivalent; **kept**.
- `whois` (×1) and the `netstat` TCP socket list (×1) — kept for now.

---

## [1.4.3] — 2026-05-24

### Technical-debt cleanup (no new features)

- **Fixed — `Shell.run` deadlock.** [NetworkUtilities.swift](SNAP/NetworkUtilities.swift) called `waitUntilExit()` *before* reading the pipe, so any command emitting more than the ~64 KB pipe buffer could hang the helper indefinitely. It now drains the pipe to EOF first, then waits, and a 60-second watchdog terminates runaway children. Protects all subprocess call sites.
- **Fixed — SwiftUI publish-during-update warning + main-thread stall.** `NetworkInfoProvider.refresh()` ran blocking `ifconfig` / `netstat` shell-outs and set `@Published` properties synchronously; since `init()` calls `refresh()`, this executed during `InfoView`'s update pass — triggering "Publishing changes from within view updates" (and cascading the same warning onto the bandwidth monitor's async publishes) plus a UI stall. Work now runs off-main with results published back on the main queue. A follow-up audit hardened two more spots in the same class: the WiFi scanner no longer round-trips through `DispatchQueue.main.sync` (and no longer captures a non-Sendable `CWInterface` across the concurrency boundary), and `BulkDiscoveryModel.init()` now defers its default-CIDR publish off the view-creation pass.
- **Changed — UI design tokens.** Migrated raw `Color(red:…)` literals to the shared `NS.*` tokens across ~18 view files (down from 18 → 3 files, the remainder being the intentional WiFi color palette + logo). Exact-value matches, so zero visual change — single source of truth for the palette and the older tabs now match the newer ones.
- **Added — export consistency.** Standard TXT/CSV/JSON `ToolActionBar` added to 12 more tabs: Ping, Lookup, Whois, Traceroute, Visual Trace, Port Scan, HTTP Probe, SSL/TLS, Fingerprint, Connections, Multi-Host, GeoIP. (Bonjour, Subnet Calc, Wake-on-LAN, Packet Capture, and the live Bandwidth monitor are intentionally excluded — no exportable results or own export path.)
- **Added — parser tests** (72 → 86). New [ParserTests.swift](SNAPTests/ParserTests.swift) covers CIDR expansion, ARP-cache parsing (`parseARP` made internal to enable it), and WiFi band/channel/sub-band helpers — the parsing logic most likely to silently break on an OS update.

### Deferred (higher-risk, for a future pass)

- **Shell-out → native APIs** — 24 `Shell.run` call sites remain (gateway via `netstat`, ARP via `arp`, ping/dig/traceroute). Each is a behavior-changing rewrite; will be done incrementally, gateway-first via `SCDynamicStore`.
- **God-file decomposition** — DeviceIdentifier (1352), NetworkMapView (1298), WiFiAnalyzerView (1151), ContentView (1127), BandwidthMonitorView (954) still mix model + view; extract models in isolated commits.

---

## [1.4.2] — 2026-05-24

### Changed — WiFi Analyzer full revamp

[WiFiAnalyzerView.swift](SNAP/WiFiAnalyzerView.swift) rebuilt from the ground up into a professional, root-free analyzer modeled on WiFi Explorer: Scanner (the sandboxed App Store build) — everything achievable through public CoreWLAN, no privileged helper, no raw 802.11 frame capture.

New layout: a **sortable networks table** on top + a **tabbed graph panel** below (resizable `VSplitView`), with persistent per-network color-coding tying every view together.

- **Networks table** — color swatch, signal bar + dBm, SSID, vendor (via the IEEE OUI registry), BSSID, band, channel, width, mode (802.11 a/b/g/n/ac/ax), generation (Wi-Fi 4/5/6/6E), security (WPA3 SAE / WPA2-Ent / Open, color-coded), country code, warning flags. Click any column header to sort; band filter + live search in the toolbar.
- **Network Details** tab — full per-network breakdown in three columns (Radio / Signal / Security & Identity).
- **Signal Strength** tab — RSSI-over-time with smooth bezier curves, signal-quality background zones, gradient area-fill on the selected network, end-of-line dots, plus a **detail strip** (Current / Average / Min-Max / Jitter σ / SNR / Quality / Trend) computed from the sampled history.
- **2.4 GHz / 5 GHz / 6 GHz** tabs — spectrum envelopes drawn as **real channel-width boxes** (a 160 MHz AP visibly dwarfs a 20 MHz one) over their actual frequency span, with a per-network detail strip (Channel / Center / Width / Span / Co-channel / Overlap / Mode / RSSI).
- **Channels** tab — every channel per band, grouped by sub-band (U-NII-1/2A/2C/3, U-NII-5/6/7/8) with **DFS** tags, AP color-dots, per-channel signal meter, recommended-channel highlight, and a **click-through popover** with co-channel contention, overlapping-AP interference analysis, frequency span, and DFS / 2.4 GHz guidance.
- **Live mode** — throttle-safe auto-rescan (~5 s, respecting macOS's scan rate limit) with per-BSSID RSSI history.
- **Export** — TXT / CSV / JSON via the standard `ToolActionBar`, respecting the active band filter + search.

**CoreWLAN honesty notes:** for *scanned* APs we surface everything public CoreWLAN exposes. Max PHY rate, spatial streams, channel utilization, and PMF flag require raw Information Element access (unavailable to sandboxed/root-free apps), so those are omitted or inferred (PMF inferred from WPA3). 802.11be isn't reported by current public CoreWLAN, so the generation ceiling is Wi-Fi 6/6E.

---

## [1.4.1] — 2026-05-12

### Fixed — UniFi authentication against modern UniFi OS controllers

The UniFi integration shipped in 1.4.0 couldn't actually complete a session against UDM / UDM-Pro / Cloud Key Gen2+ firmware. Three sequential bugs, now fixed:

- **HTTP 403 on login** — UniFi OS's NGINX proxy enforces `Origin` / `Referer` checks on the auth endpoints and rejects requests lacking them before validating credentials. We now send `Origin`, `Referer`, and a real `User-Agent` on every request (`stamp(_:)`).
- **"Not authenticated" (401) on the first API call after a successful login** — modern UniFi OS stopped returning the CSRF token as an `X-CSRF-Token` header and started embedding it inside the JWT in the `TOKEN` cookie. CSRF is now extracted three ways (response header → standalone `csrf_token` cookie → `csrfToken` claim decoded from the JWT). Session cookies are also captured manually and injected via an explicit `Cookie` header on every follow-up request, bypassing URLSession's cookie jar (which was silently dropping the `TOKEN` cookie under the default accept policy).
- **Opaque error messages** — login/device-list failures now surface the controller's actual `api.err.*` / `meta.msg` body (e.g. `api.err.Invalid`, `api.err.NoPermission`, account-lockout hints) instead of a generic "login failed" / "Not authenticated".

### Added — UniFi 2FA support

(Folded in under 1.4.0 without a version bump; recorded here.) Optional 2FA field in the credential bar — sends `token` + `ubic_2fa_token` on the initial login. Detects MFA-required responses (HTTP 499 / 401 + body hints) and prompts for the code. Single-use; never persisted. Push-to-phone and WebAuthn unsupported.

### Changed

- `.textContentType` hints (`.username` / `.password` / `.oneTimeCode`) on the UniFi credential fields.

### Fixed — Swift 6 concurrency warnings

Cleared four build warnings introduced in 1.4.0:
- `BGPLookupView` — `resolver` static marked `nonisolated` (was main-actor-isolated, accessed from `Task.detached`).
- `BulkDiscoveryView` — removed an unnecessary `NSLock` used from an async context (the guarded array is only mutated from a serial `for await`); converted the TCP-probe `finish` local function to a `@Sendable` closure with an `@unchecked Sendable` box.

---

## [1.4.0] — 2026-05-12

### Added — Cross-VLAN visibility + asset inventory

This release fills the "what's on this network?" picture that v1.3 only partially answered. Three new discovery surfaces, all with column-aligned CSV/JSON inventory exports so a spreadsheet can correlate across them.

### Added — BGP/ASN Lookup (`Tools › BGP/ASN`)

A new lookup tool — [BGPLookupView.swift](SNAP/BGPLookupView.swift). Uses Team Cymru's DNS-based ASN service (no HTTP API, no rate limits, no key). Two TXT queries:

- `<reversed-ip>.origin.asn.cymru.com` → ASN, prefix, country, registry, allocation date
- `AS<n>.asn.cymru.com` → AS organization name

Accepts IPv4, IPv6, or a bare ASN (`AS15169` / `15169`). Reuses existing [DNSWire.swift](SNAP/DNSWire.swift) for UDP/53 transport.

### Added — UniFi Controller integration (`Advanced › UniFi`)

[UniFiControllerView.swift](SNAP/UniFiControllerView.swift) — finally closes the v1.2.2 LAN-probe ceiling. SNAP can now see UniFi gear across VLANs the host can't reach, by asking the controller directly:

- Supports both the modern API shape (UDM/UDM-Pro/Cloud Key Gen2+ / self-hosted Network application v6+): `POST /api/auth/login` → CSRF token + `GET /proxy/network/api/s/<site>/stat/device`
- And the legacy controller shape: `POST /api/login` + `GET /api/s/<site>/stat/device`
- **2FA support** — TOTP / SMS codes via an optional "2FA" field in the credential bar. Sends `token` + `ubic_2fa_token` (both shapes accepted across UniFi versions) on the initial login when present. Detects MFA-required responses (HTTP 499 from UniFi OS; HTTP 401 + body hints from Network app) and surfaces a clear prompt to enter the code and retry. The 2FA code is single-use and **never persisted**. Push-to-phone approval and hardware-key WebAuthn aren't supported (would need a polling endpoint or browser flow respectively).
- Self-signed certs accepted (UniFi controllers ship them by default) via the existing `PermissiveTLS` URLSessionDelegate
- Credentials saved to the **macOS Keychain** via `SecItem*` APIs (service `com.bardaklabs.snap.unifi`) — username + password only; the 2FA code is intentionally excluded
- Device table: type icon → role (UAP→AP, USW→switch, UDM/UXG→router, UVC→camera), name, model, MAC, IP, connection state (Connected / Disconnected / Adopting / Provisioning / Upgrading / Heartbeat-missed / Isolated / …), firmware version, uptime
- Session re-auth on 401; manual refresh; disconnect + clear

### Added — Bulk Subnet Discovery (`Advanced › Bulk Discovery`)

[BulkDiscoveryView.swift](SNAP/BulkDiscoveryView.swift) — "Network Map but exhaustive": enter a CIDR, get a complete inventory.

Two-phase pipeline:
1. **Aliveness sweep** — concurrent TCP-connect to common mgmt ports (80, 22, 443, 8443, 161, 445, 23). First ready/refused = alive (many enterprise gateways ignore ICMP but accept TCP). 64-way concurrency, ~1.5s for a /24.
2. **Per-host probes** — 12-way concurrent pipeline per live host:
   - Reverse DNS (`getnameinfo`)
   - Port scan against the Network Equipment preset (22, 23, 80, 161, 443, 514, 830, 902, 4443, 8443, 9100)
   - SNMP v2c GET of `sysDescr` / `sysObjectID` / `sysName` (community editable, default `public`, 1.5s timeout, 0 retries to keep total scan time bounded)
   - MAC + vendor + role from the system ARP cache + OUI registry

Hard cap of 1024 hosts (/22) to keep scans focused.

### Added — Asset inventory export (Network Map, UniFi, Bulk Discovery)

All three discovery surfaces (Network Map + UniFi + Bulk Discovery) now export to a column-aligned CSV/JSON schema:

```csv
ip, mac, hostname, vendor, model, role, open_ports, status, ping_ms, last_seen
```

Open the three CSVs side-by-side in a spreadsheet to cross-reference what each source saw. [NetworkMapView.swift](SNAP/NetworkMapView.swift) gained inventory exports via `exportInventoryText / CSV / JSON`; previously it only persisted to UserDefaults.

### Added — Privacy Manifest

[PrivacyInfo.xcprivacy](SNAP/PrivacyInfo.xcprivacy) shipped as a bundled resource. Declares:

- `NSPrivacyTracking` = **false** — SNAP does no cross-app/site tracking
- `NSPrivacyTrackingDomains` = empty — no tracking endpoints
- `NSPrivacyCollectedDataTypes` = empty — nothing user-identifying leaves the Mac
- `NSPrivacyAccessedAPITypes` — two required-reason API declarations:
  - `NSPrivacyAccessedAPICategoryUserDefaults` / reason `CA92.1` — in-app preferences (alert thresholds, speed-test history, last network-map scan, UniFi controller URL)
  - `NSPrivacyAccessedAPICategoryFileTimestamp` / reason `C617.1` — `.modificationDate` of `/var/db/dhcpclient_leases/` files, used to display "lease acquired N minutes ago" in DHCP Leases and Connection Summary

Required for the planned App Store Lite variant; future-proofing for direct distribution as Apple's notarization rules tighten.

### Tests

72 baseline tests still passing. No new test targets in this release — the three new discovery surfaces are exercised through their real network paths, not unit-testable in isolation without network mocks.

### Deferred (carried forward to v1.5)

- **HTTP/2+3 inspector**
- **TLS fingerprinting / cert chain extraction on mgmt portals**
- **DNSSEC validation**
- **SNMPv3** (USM auth+priv crypto)
- **SNMP trap receiver** (UDP/162)
- **Sparkle auto-update** — table stakes for direct distribution
- **netstat / Shell.run tech debt** — `SCDynamicStore` for default gateway, `readabilityHandler` for `Shell.run`; BulkDiscovery currently shells out to `arp -an` for the ARP cache read for the same reason

---

## [1.3.0] — 2026-05-12

### Added — Enterprise release

This release shifts SNAP from a SOHO / prosumer tool to something credible in enterprise environments (Cisco / Juniper / Arista / Aruba / Palo Alto / Fortinet / HPE / Mikrotik / Meraki / etc.).

**Full IEEE OUI registry** ([oui_registry.txt](SNAP/oui_registry.txt), ~970 KB / 39,403 entries). The hand-curated ~300-entry map still wins for consumer brands (it carries role hints); enterprise vendor lookups now hit the bundled MA-L registry. Loaded lazily on a background queue at app start. Includes 1,349 Cisco OUIs, 362 HP/HPE/Aruba, 208 Juniper, 94 Extreme, 55 Meraki, 52 Arista, 39 Palo Alto, 26 Fortinet, and so on.

**Vendor-pattern role inference** in [OUIDatabase.swift](SNAP/OUIDatabase.swift). When a MAC hits the registry-only path, we map the vendor string to a `DeviceRole` — "Palo Alto Networks" → `.firewall`, "Arista Networks" → `.networkSwitch`, "F5 Networks" → `.loadBalancer`, "Routerboard.com" → `.router`, "Aruba" → `.accessPoint`, etc. Cisco leans `.networkSwitch` unless the string mentions Meraki / wireless.

**New `DeviceRole` cases** for enterprise gear: `.networkSwitch`, `.firewall`, `.loadBalancer`, `.wirelessCtrl`, `.serverHardware`. Wired into the Visual Map constellation and icon system.

### Added — SNMP Query Tool (`Advanced › SNMP`)

A read-only SNMP v2c client written from scratch — [SNMPClient.swift](SNAP/SNMPClient.swift) (~600 lines) + [SNMPView.swift](SNAP/SNMPView.swift). No dependencies; ASN.1 BER encoder/decoder, full message round-trip.

Three modes:
- **System Info** — single GET for sysDescr / sysObjectID / sysUpTime / sysContact / sysName / sysLocation. When `sysObjectID` matches a known enterprise number, a vendor + role + model banner appears above the varbinds. [SysObjectIDDatabase](SNAP/SNMPClient.swift) currently maps Cisco, Cisco Meraki, Juniper, Arista, Extreme, HP/HPE, Aruba, H3C, Palo Alto, Fortinet, Check Point, SonicWall, WatchGuard, Sophos, F5, A10, Citrix NetScaler, MikroTik, Ubiquiti, Ruckus, Microsoft, Linux net-snmp, VMware ESXi, Synology, QNAP, NetApp, Polycom, Avaya.
- **Interfaces** — bulk-walks `ifDescr` + `ifSpeed` + `ifOperStatus` + `ifInOctets` + `ifOutOctets` concurrently, joined on the row index. Live table with status color + sortable columns.
- **Custom OID Walk** — bulk-walks an arbitrary OID up to 1024 rows / 25 reps per round-trip; shows OID / type / value.

Defaults to community `public`. Editable community + port fields. Per-query timeout 3s, one retry.

**Note:** SNMPv3 (USM auth+priv crypto) and SET requests are intentionally out of scope for this release.

### Added — Routing / FHRP Listener (`Advanced › Routing Hello`)

Passive multicast UDP listener — [RoutingHelloView.swift](SNAP/RoutingHelloView.swift). Joins three multicast groups concurrently and decodes the frames:
- **HSRPv1** on `224.0.0.2:1985` — 20-byte fixed header per RFC 2281
- **HSRPv2** on `224.0.0.102:1985` — TLV format, scans for the Group State TLV
- **GLBP** on `224.0.0.102:3222` — TLV format, picks Hello-TLV for priority/state

Deduplicated by `(protocol, source IP, group)`, last-seen timestamp updated on every hello. Speakers table with priority / state (Active / Standby / Listen / Speak / etc.) / virtual IP.

A clearly-labelled limitations footer documents what is **not** detected without raw-socket privileges (OSPF, EIGRP, VRRP, PIM, IS-IS — all raw IP protocols). SNAP remains sandboxless + root-free.

### Added — Syslog Receiver (`Monitoring › Syslog`)

UDP syslog listener — [SyslogReceiverView.swift](SNAP/SyslogReceiverView.swift). Defaults to port 5140 (unprivileged); use 514 if running with root. Parses both RFC 3164 (BSD format — `<PRI>Mmm dd HH:MM:SS host tag: msg`) and RFC 5424 (`<PRI>V ISOTS host app procid msgid sd msg`).

- Live table: time / severity / facility / source IP / tag / message
- Severity filter (min severity to show), facility filter, host/source substring filter
- Auto-scroll toggle, Pause, Clear, Stop
- 5,000-row retention cap to keep memory bounded for long sessions
- Color-coded severity badges (emerg/alert/crit/err in red, warn in amber, notice in blue, info/debug in muted text)
- Export to text via the standard `ToolActionBar`

### Changed — Fingerprint tab upgraded with enterprise probes

[FingerprintView.swift](SNAP/FingerprintView.swift) now runs an optional SNMP probe (toggle + editable community) alongside the existing DNS / HTTP / SSH / FTP / SMTP banner grabs. A new **vendor classifier** fuses every signal — SNMP `sysObjectID`, SNMP `sysDescr`, SSH banner, HTTP Server header, reverse DNS — into a single best-guess `vendor · model · (role)` verdict shown in an amber banner at the top of the results, with the reasons it landed there. Recognises ~45 enterprise vendor patterns (Palo Alto, Fortinet, SonicWall, Check Point, Juniper, Arista, NX-OS, IOS-XE, Aruba, HP JetDirect, MikroTik / RouterOS, Ubiquiti / UniFi / EdgeOS, Ruckus, Extreme, Brocade, F5 BIG-IP, NetScaler, Polycom, Yealink, Avaya, Synology, QNAP, …).

### Changed — Port Scan presets

[PortScanView.swift](SNAP/PortScanView.swift) gains a preset menu next to the port-range field: **Custom**, **Common (1-1024)**, **Web**, **Databases**, **Network Equipment**, **Windows / AD**, **Mac / Apple**. The Network Equipment preset hits the enterprise mgmt-plane port set: 22, 23, 80, 161, 162, 443, 514, 830, 902, 1812/1813 (RADIUS), 3389, 4443, 8443, 9100, plus TACACS+ (49) and a couple of common alt-SSH spots. The existing service-name dictionary is extended with NETCONF / WinRM / vSphere / JetDirect / HTTPS-Mgmt.

### Tests

25 new tests added (now 72 total, all passing):
- [SNMPTests](SNAPTests/SNMPTests.swift) — ASN.1 BER encoding round-trip (integers, OIDs including large sub-IDs > 127), full SNMP message encode/decode for mixed value types, `SysObjectIDDatabase` longest-prefix lookup
- [SyslogParserTests](SNAPTests/SyslogParserTests.swift) — RFC 3164 + RFC 5424 happy paths, unparseable input falls back to "everything is message"
- [OUIEnterpriseTests](SNAPTests/OUIEnterpriseTests.swift) — vendor-pattern → role inference for Palo Alto, Fortinet, F5, Arista, Juniper, Aruba, MikroTik, Cisco

### Deferred

- **SNMPv3** (USM auth+priv crypto). v2c first; v3 next.
- **SNMP traps** (UDP/162) — can fold into the Syslog UI if there's demand.
- **LLDP / CDP listeners** — require raw-socket / BPF access; SNAP is intentionally sandboxless + root-free.
- **NetFlow / sFlow / IPFIX collector** — separate feature, future release.
- **TLS cert CN/SAN extraction** on mgmt portals — non-trivial TLS plumbing; deferred in favor of SNMP + banner-based fingerprinting which covers the same ground for most enterprise gear.
- **Cert expiry monitor on mgmt portals**, **asset inventory export**, **snapshot diff over time** — call out at the bottom of `v1.3 deferred` for v1.4 planning.

---

## [1.2.4] — 2026-05-12

### Added — Connection Summary hero card

A new [ConnectionSummaryCard](SNAP/ConnectionSummaryCard.swift) answers *"what's my internet right now?"* without any clicking. Now appears at the top of both Network Info and Dashboard:
- Active interface with media-type icon + "Active route" pill
- Wi-Fi SSID (when applicable) prominent in the header
- Hostname + MAC trailing
- Local IPv4 with `/CIDR` + `iface · MTU` trailing
- Wi-Fi details: channel, band, RSSI dBm, security, transmit rate, 4-bar signal indicator (CoreWLAN)
- Public IPv4 + ASN + ISP + city + country flag (ipinfo.io)
- Public IPv6 (when available, via api6.ipify.org)
- Gateway IP + manufacturer (OUI lookup) + ping latency
- System DNS resolvers (from `scutil --dns`)
- Internet ping to 1.1.1.1 with color-coded latency pill
- VPN active pill when any `utun*` / `ipsec*` / `ppp*` tunnel has an IPv4 binding
- Auto-refreshes every 30 seconds; manual refresh button + last-checked timestamp

### Changed — Network Info tab redesign

The Network Info tab moved from a stale sectioned-VStack to dark NS-token cards matching the rest of the app:
- **Fixed long-standing `MAC Address: N/A` bug** — `NetworkInfoProvider.getMACAddress()` was a hardcoded `"N/A"` stub. Now reads real MACs from the `AF_LINK` family via raw pointer arithmetic, bounded by `sdl_len` so interfaces with names ≥ 7 chars (e.g. `bridge0`) don't overflow the Swift-imported 12-byte `sdl_data` tuple. The same bug was fixed in `ConnectionSummaryCard.fetchLocalDetail`.
- New rich `InterfaceInfo` fields: link speed + duplex (parsed from `ifconfig -a`), MTU, carrier state, media type (Ethernet / Wi-Fi / VPN / Loopback / Bridge / AWDL / IPsec / PPP), traffic counters (rx/tx bytes/packets/errors/dropped from `if_data`), IPv4 with CIDR (via netmask popcount), IPv6 with scope (link-local / unique-local / global / multicast).
- `NetworkInfoProvider.activeRouteInterface` tracks the default-route interface; surfaced as an amber "Active route" pill on its sidebar row + detail header.
- New `DHCPHelper.fetchLease(iface:)` reads `ipconfig getpacket` for the selected interface and parses server / router / mask / DNS / lease time / renewal / rebind / expiry.
- Replaced translucent native `List(.sidebar)` (which inherited macOS's sidebar material and clashed with our dark UI) with a custom `InterfaceRow` button using NS tokens.
- Six cards per interface: **Hardware** (name, friendly, media, MAC, MTU, speed/duplex, carrier, flags), **IPv4** (addresses with CIDR + "default route" indicator), **IPv6** (grouped by scope), **Wi-Fi** (via CoreWLAN, when applicable), **Traffic** (since-boot rx/tx bytes auto-scaled, packets, errors), **DHCP lease** (when applicable).
- Toolbar gains a Copy / Export TXT+JSON action bar consistent with the rest of the app.
- Sidebar pre-selects the active-route interface on first appear.

### Added — Dashboard redesign

The Dashboard now leads with the new Connection Summary hero card, then a 2x2 grid of focused cards:
- **Live Bandwidth**: real-time RX/TX with dual mini-sparklines (existing BandwidthDashMonitor, unchanged)
- **Recent Alerts**: last 4 entries from AlertManager with metric label + value + timestamp, or a green "No alerts" empty state
- **Network Map snapshot**: device count, gateway IP + vendor, last-scan timestamp (auto-loads the persisted scan; tap the panel header to open the full Network Map)
- **Latest Speed Test**: download/upload/ping triple with timestamp + provider; tap to open Speed Test

**Removed**: the previous 4 metric tiles (Download / Upload / Ext IP / Interfaces), the top status bar (`DashTopBar`), and the Quick Tools launcher panel — all redundant with the new hero card + sidebar.

### Changed — Interface Stats full rewrite

Replaced the old netstat-shell-out + grid-of-stat-cards UI with a sortable Table + live ticker:
- One `getifaddrs` walk (sub-millisecond) instead of `netstat -ibn` process spawn each refresh
- New lightweight `NetworkInfoProvider.snapshotLive()` for the 1-second tick (just traffic counters, no `ifconfig` reparse)
- Sortable Table columns: Status · Interface · Type · MAC · MTU · Speed · RX bytes · TX bytes · Errors · Live (RX/TX stacked sparklines)
- Filter chips: All / Up / Ethernet / Wi-Fi / VPN / Loopback / Other
- Search box (name, friendly name, MAC, IPv4)
- Per-row 60-second RX + TX sparklines in **live mode** — compare every interface's traffic side-by-side without switching pages
- Right-side detail pane on row click: bigger sparkline chart, full metadata, traffic with live BPS, errors color-coded red
- Active-route badge on the gateway-carrying row, matching the new sidebar convention
- CSV + JSON export via the standard `ToolActionBar`

### Changed — tab category reorganization

Five tabs moved to better-fitting categories:
- **DNS Propagation** Diagnostics → **Advanced** (run when you change a record, not day-to-day)
- **DNS Benchmark** Diagnostics → **Advanced** (one-off "which resolver should I use")
- **Fingerprint** Diagnostics → **Advanced** (service/OS recon is security work)
- **Whois** Diagnostics → **Tools** (lookup utility, not troubleshooting)
- **GeoIP Lookup** Diagnostics → **Tools** (same)

Diagnostics is now exclusively "troubleshoot a target" tools (Ping, Lookup, Traceroute, Visual Trace, MTR, Port Scan, MTU Discovery, Network Health). Tools is now utilities + passive system info (Bonjour, Wake-on-LAN, Subnet, SSL, HTTP, DHCP Leases, ARP Table, Whois, GeoIP). Advanced gains the deeper DNS work + recon.

### Fixed

- `InterfaceInfo.id` was a fresh UUID per construction — meant Table selection bindings broke across refreshes. Identity is now the interface name (string), with Equatable/Hashable redefined to match.

---

## [1.2.3] — 2026-05-12

### Added — three deferred items, all shipped

**Persistent Bandwidth Monitor history** ([BandwidthHistoryStore.swift](SNAP/BandwidthHistoryStore.swift))
- SQLite-backed sample store at `~/Library/Application Support/SNAP/bandwidth.sqlite`. Uses the system `libsqlite3` via Swift C interop — no new dependencies. WAL mode, indexed on `(iface, ts)`.
- Every live sample (rx/tx/latency/jitter/loss/retransmit/DNS-latency/quality) is now persisted automatically. 30-day retention, pruned on launch.
- New **time-range picker** in the Bandwidth Monitor: **Live · 5 min · 1 h · 6 h · 24 h · 7 d**. Non-live ranges aggregate in SQL via `GROUP BY (ts / bucket) * bucket` so the chart renders ~120 points regardless of range (30 s buckets for 1 h up to 30 min buckets for 7 d).
- Row count + "Clear all history" actions inline.
- Replaces the in-memory rolling buffer that previously lost everything on quit — deferred from v1.2.0 ([CHANGELOG](#1-2-0--2026-05-11) entry "Known follow-ups").

**XCTest target — `SNAPTests`** (deferred from v1.2.0)
- New `com.apple.product-type.bundle.unit-test` target, hosted on `SNAP.app` via `TEST_HOST` + `BUNDLE_LOADER`.
- Shared scheme at [SNAP.xcodeproj/xcshareddata/xcschemes/SNAP.xcscheme](SNAP.xcodeproj/xcshareddata/xcschemes/SNAP.xcscheme) — `xcodebuild test -scheme SNAP` and ⌘U both work.
- **47 tests across 4 suites, all green in ~20 ms:**
  - [SubnetCalculatorTests](SNAPTests/SubnetCalculatorTests.swift) — 12 tests. Includes a **regression test for the `/0` UInt32 overflow bug** that was fixed in v1.1.0; it's now pinned so any future refactor can't reintroduce it. Also covers /24/31/32, class detection (A/B/C/D), and rejection of malformed inputs.
  - [DNSWireTests](SNAPTests/DNSWireTests.swift) — 7 tests. RFC-1035 type-number invariants, public resolver list shape + uniqueness + major-provider presence.
  - [OUIDatabaseTests](SNAPTests/OUIDatabaseTests.swift) — 14 tests. Separator normalization (`:` / `-` / `.` / none / mixed case), edge cases (empty / short / unknown), role hints for Sonos/Roku/Pi/Apple/Pixel/Ubiquiti.
  - [NetworkMapModelTests](SNAPTests/NetworkMapModelTests.swift) — 14 tests. The multi-subnet prefix parser: single subnet, comma-separated, `/24` form, `.x` sentinel, whitespace handling, empty entries, garbage rejection. Plus `ipNumeric` round-trips.

**MTR — mtr-style combined traceroute** ([MTRView.swift](SNAP/MTRView.swift)) — new sidebar tab in Diagnostics
- Phase 1: `/usr/sbin/traceroute -n -q1` discovers the path (configurable max hops, 5–64).
- Phase 2: spawns a continuous `/sbin/ping -i 1` per hop, in parallel. Each reply feeds **Welford's running-stats algorithm** for stddev so memory stays O(1) regardless of session length.
- Table columns: Hop · Host · Sent · Recv · Loss % · Last · Avg · Best · Worst · StDev. Reverse DNS resolves in the background.
- Summary bar identifies the worst hop in plain English (e.g. *"Worst: hop 7 (12% loss)"*) — the whole point of mtr.
- Loss is color-coded (green / amber / red) so the bad hop jumps out at a glance.
- TXT + CSV export.

### Changed

- `NetworkMapModel.parseSubnetPrefixes`, `stripTrailing24`, and `ipNumeric` are now `nonisolated static` so the XCTest target can call them without a MainActor hop. Pure string parsers should never have needed actor isolation anyway.
- `BandwidthMonitorView` is now sectioned: toolbar → AlertSettingsPanel → **range bar** → content. Range bar is always visible (the old code had no concept of historical view).
- Sidebar now has **28 tabs**.

### Engineering health

This release closes both of the v1.2.0 "deferred to v1.2.x" items from the original changelog. With the test target in place, future refactors of `SubnetCalculator`, `DNSWire`, `OUIDatabase`, and the subnet parser are now backstopped — a `xcodebuild test` run will catch regressions before they ship.

---

## [1.2.2] — 2026-05-12

### Added — UniFi / Ubiquiti device identification
Ubiquiti gear was under-identified in 1.2.1 because we only listened for mDNS, SSDP, and HTTP banners — none of which UniFi devices use as their primary discovery channel. This release adds:

- **UBNT Discovery Protocol** ([DeviceIdentifier.swift](SNAP/DeviceIdentifier.swift)) — a UDP/10001 broadcast probe (both v1 and v2 query forms) that asks every Ubiquiti device on the LAN to identify itself. Devices respond with a TLV-encoded payload containing **exact model**, **hostname**, and **firmware version**. This is the same protocol Ubiquiti's own discovery tool uses, and gives ground-truth identification for UDM-Pro, UDM-SE, UDR, UXG, UCG, UAP-* / U6-* / U7-* APs, USW-* switches, UVC / G3 / G4 / G5 cameras, UCK Cloud Keys, etc.
- **5 additional mDNS service types**: `_unifi._tcp`, `_unifi-protect._tcp`, `_http._tcp`, `_https._tcp`, `_device-info._tcp` — catches UniFi advertisements plus a wider set of previously-silent IoT devices.
- **UniFi-aware role + manufacturer heuristics** — hostname / banner / SSDP / mDNS strings matching `UDM`, `UAP`, `USW`, `UXG`, `UDR`, `UVC`, `U6-`, `U7-`, `UCK`, `unifi`, or `ubiquiti` are now mapped to the correct device role (router / AP / switch / camera / Cloud Key) and manufacturer.
- **OUIDatabase** expanded with ~30 newer Ubiquiti OUIs (UDM-SE, UXG, U7 lineage) and ~40 common smart-home OUIs (Ecobee, Wyze, Eufy, Reolink, Arlo, TP-Link Kasa/Tapo, LIFX, Shelly, Tuya, Sonos, TCL, Hisense, Sony TVs).

### Fixed
- **Gateway tagging never overrode role to `.router`** — `netstat -rn` told us "this IP is the gateway", but if the OUI hint had already set `.accessPoint`, the gateway signal was ignored. UniFi UDMs identified as the gateway now correctly show as Router. `selfDetected` likewise forces `.mac` on your own machine regardless of prior signals.
- **mDNS-detected hostnames** now feed back into role inference (e.g. `_ssh._tcp` finding `UDM-Pro.local` now correctly resolves to a UniFi router, not just "Linux").

---

## [1.2.1] — 2026-05-12

### Changed — Network Map redesign
The Network Map's three view modes (Grid / List / Visual) now share a richer model and a real identification pipeline. Devices show their actual model, manufacturer, role, and the **signals** that produced that identity, so you can trust (or distrust) the heuristic on a per-device basis.

**New multi-signal device identifier** ([DeviceIdentifier.swift](SNAP/DeviceIdentifier.swift))
- **mDNS sweep** — `NetServiceBrowser` × 16 service types (`_companion-link`, `_airplay`, `_raop`, `_googlecast`, `_hap`, `_ipp`/`_ipps`/`_printer`/`_pdl-datastream`, `_sonos`, `_spotify-connect`, `_smb`, `_afpovertcp`, `_ssh`, `_workstation`, `_androidtvremote2`, `_amzn-wplay`). TXT records are parsed for known fields (`md`, `fn`, `model`, `rpMd`, etc.) so we resolve precise models like "Apple TV4,1", "Chromecast Ultra", "Sonos Play:1".
- **SSDP / UPnP** — single `M-SEARCH * HTTP/1.1` multicast to `239.255.255.250:1900`, parses `SERVER:` and USN model strings.
- **NetBIOS Node Status** — UDP/137 query per device. Reveals Windows machine names + workstation/server role bit.
- **HTTP banner grab** — `GET /` on 80 / 443 / 8080 per device with permissive TLS. Captures `Server:` header + `<title>` (catches routers, IoT, Hue Bridge, Synology DSM, etc.).
- **Reverse DNS** — `getnameinfo`. Picks up router-published DHCP names like `Pixel-7.lan` when the router supports it.
- **OUI vendor lookup** — extracted to [OUIDatabase.swift](SNAP/OUIDatabase.swift), expanded to ~300 curated entries with **role hints** (Sonos OUIs → speakers, Roku OUIs → streamers, Pixel-line Google OUIs → Android phones, etc.).
- **Self + gateway detection** — real, via `netstat -rn` + `getifaddrs`. The constellation centers on your *actual* gateway and tags *your* Mac.
- **Confidence-weighted merge** — every signal is retained on the device. The detail panel surfaces all of them with their source, so you can see *why* a device was identified.

### Honest limits
- Apple devices, Chromecast/Nest, HomeKit, Sonos, Spotify Connect, AirPlay speakers, IPP printers, and Windows hosts identify reliably down to the model.
- Routers, NAS, IP cameras, and IoT identify via SSDP or HTTP banner.
- **Android phones (Pixel etc.) don't broadcast over Wi-Fi.** Best we can do is OUI manufacturer + reverse DNS if your router publishes DHCP hostnames. With router cooperation: "Pixel-7" appears. Without: "Google · Android Phone".

### Changed — Network Map UI
- **Filter bar** — search field + group chips (Infrastructure / Computers / Mobile / Streaming / Audio / Peripherals / Smart Home / Gaming / Other) + vendor dropdown + "Online only" toggle. Filters apply to all three view modes.
- **Visual tab** — total redesign. Real gateway at center (with its IP + manufacturer), "This Mac" tagged with a YOU pill, devices arranged in **type-grouped angular slices** around the gateway, edge color + thickness = latency. Click a node to open the detail panel. Auto-scales radius — no overlap regardless of device count. Latency legend bottom-left.
- **Grid cards** — status dot, role label, model, MAC, vendor, ping color-coded. Selection highlight.
- **List view** — sortable Table with columns: Status, IP (with gateway/self icons), Name, Role, Vendor, MAC, Ping, Last seen.
- **Detail panel** (right-side, persistent) — identity card with all known fields, list of every identification signal with its source icon, and quick actions: Copy IP, Open in Browser, Ping.

### Changed — model
- `NetworkMapModel` is now an `@MainActor ObservableObject` with explicit `ScanPhase` reporting (ARP → ping sweep → mDNS/SSDP → per-device probes).
- Scan results are persisted to `UserDefaults` so re-opening the tab shows the last scan with a `Scanned at HH:MM` timestamp until the next scan.
- Status is now tri-state: `alive` (ping or LAN sweep response), `arpOnly` (ARP cache hit, no response), `unreachable`.
- `OUIDatabase` extracted from `ARPTableView.swift` to its own file; ARP Table continues to use it via the same `OUIDatabase.lookup(_:)` API.

---

## [1.2.0] — 2026-05-11

### Added — new tools
- **DNS Propagation** — query a hostname across 16 public resolvers (Cloudflare, Google, Quad9, OpenDNS, AdGuard, ControlD, CleanBrowsing, Verisign, DNS.WATCH, Yandex, Baidu, AliDNS) in parallel, with a consensus badge that summarises whether all resolvers agree. Sandboxless raw DNS over UDP/53 — no third-party API dependency.
- **DNS Resolver Benchmark** — race the same 16 resolvers across a configurable basket of domains. Reports mean / median / p95 latency and per-resolver loss, ranked best-first.
- **MTU / Path-MTU Discovery** — binary-search the largest payload that traverses the path with the DF bit set. Annotates the result with likely encapsulation (PPPoE, GRE, IPsec, WireGuard).
- **Captive Portal Detector** — probes Apple, Cloudflare, Google, Microsoft, and Firefox detection endpoints with `URLSession`, refuses redirects so the captive portal's intercept is visible. Auto-runs on tab open.
- **DHCP Lease Inspector** — surfaces every interface's active DHCP lease via `ipconfig getpacket`, with parsed router / DNS / lease-time / expiry plus the raw packet for advanced inspection.
- **ARP Table** — reads the system ARP cache via `arp -an`, joins it with a curated OUI vendor database and reverse-DNS lookups, flags the default gateway. Includes an opt-in **/24 sweep** to repopulate stale cache entries.

### Added — quality of life
- **Threshold Alerts** in Bandwidth Monitor — configurable per-metric thresholds (latency, jitter, packet loss, retransmit rate, DNS latency) with consecutive-sample debouncing and 60-second cooldown. Fires native macOS notifications via `UNUserNotificationCenter`.
- **Session Report (HTML)** — `⌘⇧R` saves a single self-contained HTML report with interfaces, external IP, gateway, system DNS, and recent alert log, plus a notes field. No external assets.

### Changed
- Bumped all internal version strings to v1.2
- Sidebar grew to 27 tabs across the existing five categories

### Known follow-ups (v1.2.x)
- Rolling SQLite store for Bandwidth Monitor history (currently still in-memory after restart)
- `SNAPTests` XCTest target (not yet present in the project)

---

## [1.1.0] — 2026-05-05

### Added
- **GeoIP Lookup** — new tool with full map view (macOS 14+) and detail panel
  - IP address, IP type (IPv4/IPv6), flag emoji, EU membership badge
  - Continent + code, Country + code, Region + code, City, Postal, Coordinates
  - Calling code, Capital city
  - ISP, Organization, ASN, Domain
  - Timezone ID, abbreviation, UTC offset, local time
  - Security signals panel (Proxy, VPN, Tor, Hosting, Anonymous) — shown only when flagged
  - "My IP" quick-lookup button
  - Powered by ipwho.is (no API key required)

### Fixed
- **Subnet Calculator crash at /0 CIDR** — `UInt32` overflow when computing total host count for a `/0` subnet; widened intermediate arithmetic to `UInt64` before the `+ 1` addition

### Changed
- Bumped all internal version strings to v1.1

---

## [1.0.0] — 2026-04-15
### Initial release by Sevag Bardakjian

### App
- Dark-only UI with custom 3-column layout (IconRail + DarkSidebar + main)
- NS design tokens throughout
- Menu bar widget with live bandwidth monitor

### Tools
- Dashboard with live bandwidth sparklines
- Network Info
- Ping
- Traceroute / Visual Trace Route
- DNS Lookup
- Port Scanner
- Whois
- SSL/TLS Checker
- HTTP Probe
- Bonjour Browser
- Wake-on-LAN
- Subnet Calculator
- Interface Stats
- Connection Table
- Fingerprint
- Multi-Host Compare
- Network Map
- Packet Capture
- WiFi Analyzer (2.4 / 5 / 6 GHz, DFS channel support)

### Bandwidth Monitor
- Live RX/TX charts (green/blue) with auto-scaling units (B/s → KB/s → MB/s → GB/s)
- Latency chart with dynamic per-segment colour (green/yellow/red by threshold)
- Packet loss chart with step interpolation and 1%/5% threshold rules
- Jitter measurement
- TCP retransmit rate via sysctl (no netstat)
- DNS latency via getaddrinfo syscall
- ISP / ASN info via ipinfo.io
- Connection quality score (0–100, Excellent → Critical)
- Session timer

### Speed Test
- Cloudflare provider + iPerf3 LAN
- Delegate-based download (URLSessionDataDelegate) — accurate at 400+ Mbps
- Test sizes: 25 MB / 100 MB / 500 MB / 1 GB / 2 GB
- Persistent history (UserDefaults, CSV/JSON export)

### Menu Bar Widget
- Live RX (green) + TX (blue) dual sparklines
- Collapsible sections: Wi-Fi, Network, VPN/Tunnels, Quick Tools
- Quick Ping + DNS Lookup inline
- All bandwidth reading via getifaddrs syscall

### Infrastructure
- App Sandbox disabled for raw network access (direct distribution)
- All byte counters via getifaddrs / sysctl — no netstat process spawning
- DNS via Cloudflare DNS-over-HTTPS
- Universal binary (Apple Silicon + Intel)
- Minimum macOS 13.0
