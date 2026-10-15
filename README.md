# SNAP — Sev's Network Analysis Platform
**by Sevag Bardakjian**

A professional macOS network utility — sandboxless, built for speed, with ten themes.

Free and open source under the [GNU GPL v3](LICENSE). No accounts, analytics, telemetry, or crash reporting. See [Privacy & Security](#privacy--security) for every service SNAP contacts, what it stores, and what it can do on your network.

If SNAP is useful to you, you can [buy me a coffee](https://buymeacoffee.com/sevoog).

## Screenshots

![Dashboard: live cards and quick tools](marketing/linkedin/framed/01-dashboard.png)
![Network Map: find out what's on your network](marketing/linkedin/framed/02-network-map.png)
![Wi-Fi Analyzer: every nearby network with vendor, band, channel, and security](marketing/linkedin/framed/03-wifi.png)
![Status Board: a full-screen view for a second monitor](marketing/linkedin/framed/05-status-board.png)

<details>
<summary>More screenshots</summary>

![Wi-Fi channel overlap](marketing/linkedin/framed/04-spectrum.png)
![Bandwidth Monitor: live traffic plus history](marketing/linkedin/framed/06-bandwidth.png)
![Command bar: press ⌘K to jump to any tool](marketing/linkedin/framed/07-command-bar.png)
![Ten themes](marketing/linkedin/framed/08-themes.png)

</details>

*Every network detail in these screenshots is a placeholder.*

## Install

1. Download `SNAP-1.5.5.zip` from the [latest release](https://github.com/Sevoog/SNAP/releases/latest).
2. Unzip it and drag **SNAP** into your Applications folder. It runs natively on Apple silicon and Intel Macs with macOS 14 or later.
3. Open SNAP. The first time, macOS blocks it, because SNAP isn't notarized by Apple yet. To open it anyway:
   - In the warning ("Apple could not verify…"), click **Done**.
   - Open **System Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to the message about SNAP. The button stays there for about an hour after the blocked attempt.
   - Click **Open** in the warning that follows, and enter your login password if macOS asks.

   After that, SNAP opens normally. If you'd rather use Terminal, `xattr -dr com.apple.quarantine /Applications/SNAP.app` does the same thing.
4. On first launch, SNAP asks for **Location** (macOS only shows Wi-Fi network names to apps that have it) and **Local Network** access. See [Privacy & Security](#privacy--security) for what each is used for. A short Quick Tour opens the first time; reopen it anytime from **Help → Quick Tour…**.

**Check the download (optional):** the release page lists the zip's SHA-256. Compare it with the output of `shasum -a 256 SNAP-1.5.5.zip`.

**Build it yourself:** see [Building](#building). There are no dependencies, and Xcode signs it to run on your Mac automatically.

**Uninstall:** quit SNAP (⌘Q), delete it from Applications, and follow the removal steps at the end of [Stored on your Mac](#stored-on-your-mac).

## Features

### Overview
- **Dashboard** — Connection Summary hero card (active interface, Wi-Fi SSID, public IPv4/IPv6, ISP/ASN, gateway + vendor, DNS, latency) plus a **fully customizable grid** of pinned tool cards in three buckets (functional / live / launcher). Layout persists per user, **+ Add Tools** modal, **Edit Mode** to remove. *Reworked in v1.5.0; hero originally introduced v1.2.4*

### Diagnostics — *troubleshoot a target*
- **Network Info** — Per-interface dark cards: Hardware (MAC, link speed/duplex, MTU, carrier), IPv4 with CIDR, IPv6 by scope, Wi-Fi specifics, traffic counters, DHCP lease, "Active route" badge — *redesigned in v1.2.4*
- **Ping** — Configurable count or unlimited mode
- **Lookup** — DNS lookups via DNS-over-HTTPS (A, AAAA, MX, NS, TXT, and more)
- **Traceroute** / **Visual Trace** — One-shot path discovery, optionally geo-mapped
- **GeoIP Lookup** — Map-based IP geolocation with location, network, timezone, and security signals *(grouped under Visual Trace in v1.4.2 — they offer related services)*
- **MTR** — Combined traceroute + per-hop continuous ping with running stats (Welford stddev) — *new in v1.2.3*
- **Port Scan** — Scan hosts for open TCP ports
- **MTU Discovery** — Path MTU via DF-bit binary search, with encapsulation hints
- **Network Health** — Captive portal, DNS hijacking, transparent proxy, outbound port blocking checks (renamed from "Captive Portal" in v1.2.2)

### Tools — *utilities + passive system info*
- **Bonjour** — Browse mDNS/Bonjour services on the local network
- **Wake-on-LAN** — Send magic packets to wake remote machines
- **Subnet Calculator** — CIDR / netmask / host-range calculations
- **SSL/TLS Checker** — Inspect certificates, chains, and TLS configuration
- **HTTP Probe** — Send HTTP requests and inspect responses, headers, timing
- **DHCP Leases** — Parsed `ipconfig getpacket` lease inspector with raw-packet view
- **ARP Table** — L2 neighbor cache with vendor lookup, reverse DNS, optional /24 sweep
- **Whois** — Domain registration lookups *(moved from Diagnostics in v1.2.4)*
- **BGP/ASN Lookup** — *new in v1.4* Team Cymru DNS-based ASN service: ASN, AS organization, BGP prefix, country, registry, allocation date. Accepts IPv4, IPv6, or a bare ASN.

### Monitoring — *live continuous data*
- **Bandwidth** — Live RX/TX charts, latency, packet loss, jitter, TCP retransmits, DNS latency, ISP/ASN info, 0–100 quality score, **threshold alerts**, **SQLite-backed history with Live / 5 min / 1 h / 6 h / 24 h / 7 d ranges** — *history added in v1.2.3*
- **Interface Stats** — Sortable Table with filter chips, search, per-row 60s live sparklines, detail pane with bigger chart — *redesigned in v1.2.4*
- **Connections** — Active socket / connection table
- **Speed Test** — Cloudflare provider + iPerf3 LAN, delegate-based download accurate at 400+ Mbps, persistent history
  - **iPerf3 LAN:** upload, download, or both, with 1 to 8 streams for 5 to 60 seconds. Results come with summary cards, a verdict against your Mac's link speed, and a per-second chart next to iperf3's own output.
- **WiFi Analyzer** — *fully revamped in v1.4.2* Sortable native-`Table` networks list (vendor via OUI, mode, generation, width, security, warning flags) over a **resizable** tabbed graph panel:
  - **Network Details** — full per-network breakdown (radio / signal / security)
  - **Signal Strength** — RSSI-over-time with **auto-scaling Y axis**, signal-quality zone bands, and a glow + area-fill highlight on the selected network, plus a stats strip (current / avg / min-max / jitter σ / SNR / quality / trend)
  - **2.4 / 5 / 6 GHz** — spectrum envelopes drawn as real channel-width boxes, axis fitted to the occupied band so channels spread across the full width
  - **Channels** — full per-band grid (sub-bands + DFS tags), click a channel to highlight the tile and open an **inline detail card** with co-channel contention + overlapping-AP interference analysis
  - Live mode, band filter, search, TXT/CSV/JSON export. Root-free (public CoreWLAN only)
- **Syslog** — *new in v1.3* UDP syslog receiver (defaults to port 5140 for unprivileged use). RFC 3164 + RFC 5424 parser, severity / facility / source filters, color-coded severity, 5000-row retention, pause/clear/auto-scroll

### Advanced — *power-user features*
- **DNS Propagation** — Query a hostname across 16 global public resolvers in parallel, with consensus badge *(moved from Diagnostics in v1.2.4)*
- **DNS Benchmark** — Race resolvers across a basket of domains, ranked by latency + loss *(moved from Diagnostics in v1.2.4)*
- **Fingerprint** — Service / OS fingerprinting on remote hosts. **v1.3** adds SNMP probe + a vendor classifier that fuses sysObjectID, SSH banner, HTTP Server, and rDNS into a single vendor + model + role verdict (Cisco / Juniper / Arista / Aruba / Palo Alto / Fortinet / MikroTik / Ubiquiti / etc.)
- **Multi-Host Compare** — Compare metrics across multiple hosts simultaneously
- **Network Map** — Visualize the local network topology with **multi-signal device identification** (mDNS, SSDP, UBNT discovery for UniFi gear, NetBIOS, HTTP banner, reverse DNS, full IEEE OUI registry + vendor-pattern role inference) — *enterprise-grade vendor coverage in v1.3*. Scans any range up to a /16: a subnet (`10.0.0.0/16`), a custom range (`10.0.0.1-10.0.3.254`), a /24 shorthand, or a comma-separated mix. Prefilled from your connection's real subnet; asks before scans over ~1,000 addresses, with a time estimate — *ranges in v1.5.4*
- **SNMP** — *new in v1.3* Read-only SNMP v2c client (ASN.1 BER from scratch, no deps). System Info / Interfaces / Custom OID Walk modes. `sysObjectID` lookup against an enterprise database (Cisco, Cisco Meraki, Juniper, Arista, Extreme, HP/HPE, Aruba, Palo Alto, Fortinet, Check Point, SonicWall, F5, NetScaler, Synology, QNAP, …).
  - **v1 and v2c:** Auto asks over v2c, then over v1 for older devices. A how-to card explains setup, a "No answer" card lists what to check, and any host's right-click menu has Query with SNMP.
  - **Seven views:** System Info; Health (printer toner and ink, UPS battery and minutes left, NAS and server storage and CPU, each with a one-line verdict); Inventory (models and serial numbers, with Copy buttons); Interfaces (port names, admin labels, speeds, errors, last change, a physical-ports filter, and Watch live for traffic per port with % of link); Neighbors (LLDP and CDP, with a button to query the next switch); Where Is It? (the switch port an IP or MAC address is on); and Custom OID Walk.
  - **Remember and the Status Board:** opt-in Remember keeps a host's community string in your Keychain, and any device or port can go on the Status Board's SNMP Watch tile.
- **Routing Hello** — *new in v1.3* Passive UDP multicast listener for HSRPv1 / HSRPv2 / GLBP — gateway redundancy + load-balancing speakers detected without raw-socket access. Limitations footer documents what OSPF/EIGRP/VRRP/PIM detection would need.
- **UniFi** — *new in v1.4* Authenticate to a UniFi Network Controller (UDM-Pro / Cloud Key / self-hosted Network application or legacy standalone controller) and pull the adopted-device inventory across all VLANs the controller knows. Credentials stored in the macOS Keychain; self-signed certs accepted.
- **Bulk Discovery** — *new in v1.4* Range-driven asset inventory (same range syntax as Network Map, up to 8,192 addresses): aliveness sweep + per-host port scan + SNMP probe + reverse DNS + ARP-based vendor lookup. Concurrent two-phase pipeline. CSV/JSON export shares the schema with Network Map + UniFi for cross-source correlation.
- **Packet Capture** — Capture and inspect network packets

### Additional Features

- **Menu Bar Widget** — Live RX/TX sparklines, Wi-Fi / Network / VPN sections, inline Quick Ping & DNS Lookup
- **Threshold Alerts** — Configure latency / loss / jitter / retransmit / DNS thresholds with consecutive-sample debouncing, native macOS notifications
- **Session Report (HTML)** — `⌘⇧R` saves a single self-contained HTML snapshot of network state + recent alerts
- **Export Results** — Every tool exports to TXT, CSV, or JSON via a consistent action bar
- **Persistent Speed Test History** — Saved across sessions with CSV/JSON export
- **Persistent Bandwidth History** — SQLite-backed, 30-day retention, time-range aggregation
- **Connection Quality Score** — 0–100 rating (Excellent → Critical) derived from latency, loss, jitter, retransmits, and DNS responsiveness
- **Sandboxless Networking** — Direct `getifaddrs` / `sysctl` / raw UDP syscalls — no `netstat` spawning for hot-path sampling
- **Dark-Only UI** — Custom 3-column layout (icon rail + sidebar + main) with NS design tokens throughout
- **XCTest target** — 124 unit tests across SubnetCalculator, DNSWire, OUIDatabase, NetworkMapModel, SNMP (ASN.1 BER round-trip + sysObjectID), Syslog parser (RFC 3164 + 5424), enterprise OUI vendor-pattern inference, CIDR expansion, ARP-cache parsing, WiFi band/channel helpers, connection-health scoring (incl. menu bar dot outage timelines), public-lookup caching, Status Board Wi-Fi readings, and scan-range parsing (CIDR, ranges, limits) — *added in v1.2.3, expanded through v1.5.4*

## Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 15+
- Universal binary (Apple Silicon + Intel)

## Privacy & Security

SNAP has no accounts, analytics, telemetry, ads, or crash reporting, and contains no third-party code. It never sends anything to me. This section lists everything SNAP itself does, plus what macOS stores on SNAP's behalf. If you find something it doesn't cover, please report it.

Unless a bullet says otherwise, SNAP's web requests carry macOS's default User-Agent (`SNAP/1 CFNetwork/… Darwin/…`), which names SNAP and your macOS (Darwin) version. Each extra main window (File > New Window) runs its own copy of the window-based checks below.

### Contacted automatically

These happen without you starting a tool: at launch, on a timer, or when you open a view. Some also repeat when you press Refresh. SNAP keeps running in the menu bar after you close its window, so anything marked "until you quit" keeps going until you quit SNAP (⌘Q, or SNAP > Quit SNAP).

| When | Destination | What and why |
|---|---|---|
| From launch until you quit, every 10 s | Your router (default gateway) | Ping, for the menu bar health dot. |
| While a main window is open, including in the background, minimized, or behind the Status Board: when it opens, then every 15 s | `www.apple.com` (falls back to `www.cloudflare.com`, then `www.google.com`) | A small HTTPS request to confirm you're online. The Cloudflare fallback (`/cdn-cgi/trace`) returns your public IP. |
| While the Dashboard or Network Info tab is selected in an open window, even a minimized or background one, or behind the Status Board. The Dashboard is the default tab, so this starts at launch. | `api.ipify.org`, `api6.ipify.org` | Your public IPv4/IPv6 address, for the connection summary at the top of those tabs. **These services see your public IP.** |
| Same summary, once it knows your public IPv4: at most once per address per day while SNAP runs, again after every launch, 5 min after a failed attempt, and when you press Refresh | `ipinfo.io` | A request to `ipinfo.io/<your IPv4>/json` for the ISP, ASN, city, region, and country of that address. **ipinfo sees your public IP.** |
| Same summary, when it appears and then every 30 s while its tab is selected | `1.1.1.1` and your router | Ping, for the latency readouts. Each refresh also reads your router's entry in the ARP table (`arp -n`) to show its vendor. |
| From launch (the Dashboard loads your favorites) until you quit, every 30 s, or every 10 s while the Status Board is open or detached (including after you close the main window while the board is showing) | Hosts you added as favorites (nothing if you have none) | Ping. |
| Each time the menu bar popover opens, and when you press its refresh button | `api.ipify.org` | Your public IP. |
| When the Network Info tab first opens, each time you return to it, and when you press its toolbar Refresh | `api.ipify.org` | Your public IP. This is a separate, uncached lookup, not the summary's. |
| From the first time you open the Status Board until you quit: 4 s after that first open, then every 10 min. This continues after the board closes and after the main window closes. Opening the board again doesn't add a lookup. | `ipwho.is` | Your public IP, ISP, ASN, city, and country for the header chip. **ipwho.is sees your public IP.** |
| After you pin a device or port to the Status Board's SNMP Watch tile, until you unpin it: when the board shows the tile, then every 10 s while it stays showing (the board open in a main window, or detached) | The device you pinned | One SNMP GET with the community string saved for the tile: the device's uptime and name, plus the port's status and traffic counters if you pinned a port. Like all v1 and v2c SNMP, the community string travels unencrypted. |
| From the first time the Status Board shows its DNS Latency tile (it's in the default layout) until you quit: 2 s later, then every 10 s. This continues after the board or the main window closes, and after you remove the tile. | The first DNS resolver your Mac uses, `1.1.1.1`, `8.8.8.8`, `9.9.9.9` | A plain UDP/53 lookup of `cloudflare.com` to each resolver in turn, to time them. That is up to 4 queries every 10 s, about 34,560 a day. |

SNAP keeps the public IP in memory only. It looks it up at the first refresh after launch, then at the next 30 s refresh once 10 min have passed or your network changes (interface, local IP, router, Wi-Fi name, or VPN), on every 30 s refresh while both lookups are failing, and when you press Refresh.

Two more Status Board monitors work the same way but send nothing over the network. The Top Talkers tile is in the default layout. From the first time the board shows it until you quit, SNAP runs `/usr/bin/nettop` 3 s later and then every 4 s. Each run takes about 1 s and reads the name, process ID, and byte counts of every process on your Mac with network activity. The top 5 are kept in memory. The System tile, also in the default layout, reads CPU, memory, uptime, and battery as soon as the board first shows it, then every 3 s until you quit. A detached Status Board window stays open, with its live tiles, after you close the main window.

### Contacted only when you use a tool

Tools keep running after you switch to another tab (a ping, a traceroute, a scan, a capture) until they finish or you stop them. Closing the main window stops Ping, Traceroute, Visual Trace, MTR, Port Scan, Speed Test, Bandwidth, Bulk Discovery, Bonjour, Packet Capture, Syslog, Routing Hello, and SNMP (including Watch live). Anything else you've already started runs to completion. That includes a Network Map scan, ARP Table's Sweep /24, Network Health, Fingerprint, Multi-Host, MTU Discovery, DNS Propagation, DNS Benchmark, Whois, SSL/TLS, HTTP Probe, GeoIP Lookup, and BGP/ASN.

A few tools start as soon as you open their tab, without a click: Network Health, ARP Table, Bonjour, and WiFi Analyzer. Connections, DHCP Leases, and Interface Stats also start on their own but stay on your Mac. Visual Trace shows its map as soon as it opens.

- **Anything you type into a tool goes to the target you chose.** That covers Ping, Traceroute, MTR, Port Scan, HTTP Probe, SSL/TLS, MTU Discovery, SNMP, iperf3, and the menu bar's quick Ping. Names you type are resolved through your system DNS resolver unless a bullet below says otherwise. SNMP uses v2c, or v1 when Auto falls back to it; both send the community string unencrypted. SNMP's Interfaces view asks the device again every 2 to 30 s (your choice) while Watch live is on, for the ports shown. Neighbors' Query button and Where Is It?'s hop button query the next device's management address with the same community. Where Is It? also reads your Mac's own ARP cache (`arp -n <address>`) when the device doesn't know the MAC address.
- **Bandwidth** (when you press **Start**; opening the tab doesn't start it): a request to `ipinfo.io/json` for your public IP, ISP, ASN, city, and region (**ipinfo sees your public IP**). While it runs, which continues after you switch tabs until you press **Stop** or close the window: every 3 s, four TCP connections to `1.1.1.1` port 80 to time latency, jitter, and loss, and every 10 s a lookup of `one.one.one.one` through your DNS resolver to time DNS.
- **Traceroute, Visual Trace, and MTR reach every router on the path**, not just the target. Traceroute and Visual Trace look up a name (PTR record) for every hop through your system DNS resolver. MTR pings every hop that responds once a second (`ping -i 1`) until you press Stop or close the window, and also looks up each hop's name.
- **HTTP Probe** sends the method, headers, and body you type. macOS adds its standard headers unless you set your own: the default User-Agent, Accept, Accept-Language, Accept-Encoding, and any cookies stored for that site. It follows redirects unless you turn that off, so a redirect can carry the request to a different host. It keeps any cookies the site sets (see *Stored on your Mac*). The Dashboard's **HTTP Probe card** sends a GET to the URL you enter and also follows redirects.
- **Fingerprint** (when you click **Fingerprint**):
  - It looks up the target's A and AAAA records, plus the PTR record of the first IPv4 address Cloudflare returns, over plain UDP/53 at Cloudflare's `1.1.1.1`, so every name you type, internal ones included, goes to Cloudflare. The probes below connect to the name you typed, so your system resolver looks it up too.
  - It sends a plain-HTTP GET to `http://<target>` and a GET to `https://<target>`. Both follow redirects and use the shared cookie store.
  - It opens TCP connections to ports 22, 21, and 25 to read their greetings.
  - It pings the target once.
  - With the SNMP option on (the default), it sends an SNMP v2c GET for sysDescr, sysObjectID, and sysName with the community string shown (`public` unless you change it, sent unencrypted), retried once if there's no answer.
- **Multi-Host** (when you click **Compare**; the list starts with `google.com` and `cloudflare.com`): for each host, 5 pings (the count is editable), a lookup through your system resolver, and a GET to `https://<host>` that follows redirects.
- **Dashboard cards** run only when you press their button, but some start with targets filled in for you: Ping `1.1.1.1`, DNS `cloudflare.com` (looked up through your system resolver), Traceroute `github.com`, GeoIP `8.8.8.8`, Whois `apple.com`, HTTP Probe `https://api.github.com`, and Port Scan `192.168.1.1`. The Port Scan card always tries the same ports: 22, 53, 80, 161, 443, 8080, and 8443.
- **GeoIP Lookup and Visual Trace** → `ipwho.is`. GeoIP sends the IP you look up. If you type a hostname, it's resolved through your system resolver first and only the IP is sent. *My IP* sends a request with no address, so ipwho.is sees yours. Visual Trace sends each hop's IP except 10.x, 172.16.x to 172.31.x, 192.168.x, and 127.x addresses. Other non-public hops, such as an ISP's 100.64.x.x addresses, are sent too.
- **Apple Maps** → Visual Trace shows an Apple Maps (MapKit) map as soon as its tab opens, and GeoIP Lookup shows one with each result. Loading the map tiles lets Apple see your IP and the area shown: the world view at first, then the area around the located hops or the address you looked up.
- **Dashboard GeoIP card** → `ip-api.com` over **plain HTTP**. Whatever you type, an IP or a hostname, is sent as is (unlike GeoIP Lookup, it isn't resolved first), so it's visible to anyone on the network path.
- **Whois** → WHOIS registry servers, via macOS's `whois` command.
- **BGP/ASN** (the tool and its Dashboard card) → TXT lookups over plain UDP/53 to Google Public DNS (`8.8.8.8`), which forwards them to Team Cymru (`asn.cymru.com`). An IP lookup sends `<reversed IP>.origin.asn.cymru.com` (`origin6` for IPv6), then `AS<n>.asn.cymru.com` for the AS name. An ASN lookup sends only the second. Google and Team Cymru both see what you looked up.
- **DNS Lookup** (the **Lookup** tab) → DNS-over-HTTPS to the provider you pick: `1.1.1.1` (the default), `8.8.8.8`, or `9.9.9.9`. It never uses your system resolver, so internal names you look up go to that provider.
- **DNS Propagation** → sends the name you type over plain UDP/53 to all 16 built-in public resolvers, and you can't leave any out. They are Cloudflare (2), Google (2), Quad9 (2), OpenDNS (2), AdGuard, ControlD, CleanBrowsing, Verisign, DNS.WATCH, Yandex (Russia), Baidu (China), and AliDNS (China).
- **DNS Benchmark** → the same 16 resolvers over plain UDP/53. By default each one gets 8 rounds of `google.com`, `apple.com`, `cloudflare.com`, `wikipedia.org`, and `amazon.com`, 640 queries in total. Your system resolver isn't queried, even with *Include system resolver* on.
- **Speed Test** → `speed.cloudflare.com` and `www.cloudflare.com`.
- **Network Health** (formerly the Captive Portal check) runs every check when its tab opens, and again on **Re-check** (⌘R):
  - **Captive-portal checks:** plain-HTTP requests to `captive.apple.com`, `www.msftconnecttest.com`, `cp.cloudflare.com`, and `detectportal.firefox.com`, three to `www.gstatic.com`, and one HTTPS request to `captive.apple.com`. These use throwaway sessions with no cookies or cache and don't follow redirects. The six portal probes identify themselves as macOS's captive-portal checker (User-Agent `CaptiveNetworkSupport-407.40.1 wispr`). The two extra `www.gstatic.com` requests, which look for a transparent proxy, use SNAP's default User-Agent.
  - **DNS checks:** it resolves a random `snap-nxdomain-<random>.invalid` name, `localhost`, and `example.com` through your system resolver, and looks up `example.com` with DNS-over-HTTPS at `1.1.1.1`. It also fetches `https://1.1.1.1/cdn-cgi/trace`, whose response includes your public IP.
  - **Port checks:** TCP connections, with nothing sent, to `github.com` (22), `smtp.gmail.com` (25, 465, 587), `1.1.1.1` (53), `cloudflare.com` (80, 443), `imap.gmail.com` (993), `pop.gmail.com` (995), and `stun.l.google.com` (3478).
- **Menu bar quick DNS** → `1.1.1.1` (DNS-over-HTTPS).
- **UniFi** → the controller only, and only when you press **Connect** or **Refresh**. Nothing runs in the background. SNAP logs in with your username, password, and any 2FA code (`POST /api/auth/login`, or `/api/login` on older controllers), then requests the device list. It uses HTTPS only.
- **Session Report** (File > Save Session Report…, ⌘⇧R) → after you choose where to save it, two requests to `api.ipify.org` for your public IP. The HTML file contains your hostname, macOS version, public IP, router, DNS servers, every interface's IPv4/IPv6 addresses and status, and up to 20 recent alerts. It's written only to the file you chose and then opened in your default app for `.html` files.
- **Links**, such as *Source code and license* in the About panel (click the version number at the bottom of the sidebar) and a Network Map device's *Open* button, open in your default browser. SNAP doesn't fetch them itself.

### On your local network

- **Network Map** (when you click **Scan Network**; it asks first above 1,024 addresses, and the limit is a /16):
  - **Range sweep:** it reads the ARP table, pings every address in the range, and sends a Ubiquiti discovery probe (UDP 10001) to every address. For 6 s it also sends and listens for mDNS/Bonjour, SSDP (UPnP) multicast, and Ubiquiti broadcast queries.
  - **Per-device probes:** every device that answered gets probed, all at the same time. That includes devices outside the range that answered the multicast or broadcast queries. Each gets a NetBIOS name query (UDP 137), another Ubiquiti probe, and a reverse DNS (PTR) lookup through your system resolver, which may be a server outside your network.
  - **Web requests:** each device also gets up to three read-only requests, to `http://<ip>:80/`, `http://<ip>:8080/`, then `https://<ip>:443/`. They stop at the first one that returns a page title or Server header, and identify as `SNAP/1.2 LAN-scan`. They accept any certificate without checking it and never send credentials. They keep no cookies or cache. They do follow redirects, so a device that redirects to an outside address, such as a vendor's cloud login, sends the request there.
  - **Limits:** scan ranges aren't restricted to private addresses. A scan has no Stop button and keeps going after you close the main window; by SNAP's own estimate a /16 takes about 38 minutes.
- **Bulk Discovery** (when you click **Start**). It defaults to your Mac's subnet, or its /24 if the subnet is larger. It can cover up to 8,192 addresses and doesn't ask before large ranges.
  - **Live check:** it tries TCP connections to ports 80, 22, 443, 8443, 161, 445, and 23 on every address in the range (all seven at once, 64 hosts at a time). A host that accepts or refuses a connection counts as live.
  - **Per-host probes**, for each live host, 12 at a time:
    - a reverse DNS lookup through your system resolver
    - with *Port scan* on (the default), connection attempts to 22, 23, 80, 161, 443, 514, 830, 902, 4443, 8443, and 9100 (connect only, nothing sent)
    - with *SNMP probe* on (the default), one SNMP v2c GET for sysDescr, sysObjectID, and sysName with the community string shown (`public` unless you change it, sent unencrypted)
  - It reads the ARP table once. It sends no mDNS, SSDP, Ubiquiti, NetBIOS, or web requests. **Stop** or closing the window cancels it.
- **ARP Table**: opening the tab, returning to it, or pressing Refresh (⌘R) reads the ARP table. It then looks up names (PTR records) for up to 64 entries through your system resolver. **Sweep /24** pings addresses 1 to 254 of the /24 around your Mac's Wi-Fi or Ethernet address, whatever your actual subnet size, to refill the table. It can't be stopped once started.
- **Port Scan**: TCP connection attempts to the ports you choose.
- **Wake-on-LAN**: sends a UDP broadcast "magic packet" (6 bytes of `FF`, then the target MAC 16 times). By default it goes to `255.255.255.255` port 9, so every device on your network segment receives it. Each device entry can set its own broadcast address and port, while the Dashboard card always uses `255.255.255.255:9`. The device list isn't saved.
- **Bonjour**: once opened, keeps listening for and querying mDNS services on your local network until the window closes. It also browses over Apple's peer-to-peer Wi-Fi (AWDL), so it can list nearby Apple devices that aren't on your network.
- **WiFi Analyzer**: has macOS scan for nearby Wi-Fi networks. A scan runs when the tab first opens, when Location permission changes, when you press Scan, and every 5 s while Live is on and the tab is visible. Each scan briefly takes your Wi-Fi radio off its channel. Nothing else in SNAP scans: the Dashboard, menu bar, and Status Board only read your current connection.
- **Syslog receiver**: listens on a UDP port (5140 by default) only while it's running. It listens on every network interface and accepts messages from any device that can reach your Mac on that port. Messages stay in memory (the newest 5,000) unless you export them.
- **Routing Hello**: when you press **Listen**, joins the HSRP and GLBP multicast groups (`224.0.0.2` and `224.0.0.102`, UDP 1985 and 3222) and only listens. It sends no hellos, though joining a group makes macOS announce the membership (IGMP). It stops when you press Stop or close the window.
- **Packet Capture**: runs macOS's `tcpdump` on the interface you pick (`en0`, `en1`, `en2`, `lo0`, or `any`). This puts the interface into promiscuous mode, so on a wired, mirrored, or hub segment it can capture other devices' traffic too.
  - It needs read access to `/dev/bpf*`. That means launching SNAP with `sudo` (the app shows the command), unless something like Wireshark's ChmodBPF has already made those devices readable.
  - Running SNAP with `sudo` runs the whole app, and every tool it launches, as root. That session's settings and history may then be stored under root's account (`/var/root`) instead of yours.
  - Captured packets stay in memory, appear in SNAP, and go nowhere else. Capture stops when the window closes.
- **Vendor names** for MAC addresses come from the IEEE registry bundled with SNAP. MAC addresses are never sent to an online lookup service.

Scans and port probes are visible to network monitoring and intrusion-detection systems. **Only scan networks you own or are authorized to test.**

### System tools SNAP runs

SNAP launches these directly, never through a shell:

- `/sbin/ping`
- `/usr/sbin/traceroute`
- `/usr/sbin/arp` (only reads the table)
- `/usr/sbin/ipconfig getpacket` (read-only DHCP details, for Network Info and DHCP Leases)
- `/usr/sbin/netstat` (the Connections tab, which lists every TCP connection on your Mac with its process)
- `/sbin/ifconfig` (also reads the link speed of the connection that reaches an iPerf3 server)
- `/sbin/route` (only `route -n get <server>`, to see which connection reaches an iPerf3 server)
- `/usr/bin/whois`
- `/usr/bin/nettop` (Top Talkers, see above)
- `/usr/sbin/tcpdump`
- `/usr/bin/which` (to find `iperf3` if it isn't in one of the folders below)
- `iperf3`, if it's installed (`iperf3 -c <host> -p <port> -t <seconds> --forceflush`, plus `-P <streams>` for more than one stream and `-R` for a download test). SNAP looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, and `/usr/bin` (Homebrew on Apple silicon and Intel, MacPorts, the system), then asks `which`.

SNAP never asks for your admin password, and it installs no helpers, daemons, or login items.

### Permissions

- **Location Services** (asked at first launch). macOS only shows Wi-Fi network names (SSIDs) to apps with location permission. SNAP never requests your coordinates. If you decline, network names are hidden and everything else works.
- **Local Network** (macOS 15+). macOS asks the first time SNAP, or a tool it launches such as `ping`, contacts a device on your local network. That's usually the router ping a few seconds after launch. If you decline, anything aimed at your local network fails: the router ping and health dot, scans, Bonjour, the UniFi controller, and LAN targets in every tool.
- **Notifications** (in practice asked at first launch, because the Dashboard's Recent Alerts card, on by default, loads the alerts). Used only for bandwidth threshold alerts, which can fire only while the Bandwidth monitor runs. macOS Notification Center keeps the alerts it has shown.
- **Keychain**. Used only if you tick *Remember* in the UniFi tool (the password) or the SNMP tool (a community string), or pin a device to the Status Board's SNMP Watch tile (its community string). They go into your login Keychain. While Remember is on, the UniFi tab reads its password back when it opens, and the SNMP tab reads a host's community back when you enter that host. The SNMP Watch tile reads its copy while the Status Board shows it.
- **Full Disk Access**. SNAP never asks for it. Without it, the Status Board's Top Talkers tile may show less data.

### Stored on your Mac

- **Preferences** (`~/Library/Preferences/com.sevagbardakjian.snap.plist`):
  - theme, Dashboard and Status Board layouts, and favorites (name, host, and date added)
  - the last 10 inputs for Ping, Lookup, Whois, HTTP Probe, GeoIP, BGP/ASN, Traceroute, and Port Scan, shared with their Dashboard cards, and the last 10 SNMP hosts (never the community string). *Clear history* in the clock menu next to each input removes them.
  - alert thresholds, and whether alert notifications are on
  - the last 100 internet speed test results
  - the last 100 iPerf3 results: server and port, direction, streams, test length, speed, retransmits, and your Mac's link speed. *Clear* under Recent LAN tests removes them.
  - the SNMP hosts and ports whose community string you chose to remember (not the community strings themselves, which are in the Keychain)
  - the SNMP Watch tile's device: host, port, SNMP version, device name, and, for a port, its interface index, name, and speed. Unpinning removes it.
  - the last Network Map scan, described below
  - the UniFi controller URL, username, and *Remember* setting. These are saved after every successful connection, even with Remember off.
  - approved UniFi certificate fingerprints
  - whether you've seen the Quick Tour

  The saved Network Map scan holds each device's IP, MAC, vendor, name, model, manufacturer, role, ping time, and last-seen time, plus your router's IP, your Mac's IP, and the scan time. Each new scan replaces it, and SNAP has no button to delete it. macOS may also keep the window's size and position, the menu bar item's position, and the last folder you used in a Save dialog in this file.
- **Bandwidth history** (`~/Library/Application Support/SNAP/bandwidth.sqlite`, with `-wal` and `-shm` files next to it). While the Bandwidth monitor runs, SNAP adds one row per second with:
  - the time
  - the interface
  - receive and send rates
  - latency, jitter, and loss to `1.1.1.1`
  - TCP retransmit rate
  - DNS lookup time
  - quality score

  Rows older than 30 days are deleted when the file is opened, and *Clear all history…* in the Bandwidth tab deletes them all. The folder and an empty file are created the first time you open the Bandwidth tab, even if you never press Start. Never packet contents.
- **Keychain**: the UniFi password, only if you chose *Remember*. There's one item for each controller URL and username. Unticking Remember or pressing Disconnect doesn't delete it.
- **Keychain**: SNMP community strings, service `com.bardaklabs.snap.snmp.community`. There's one item for each host and port you ticked *Remember* for, and one for the Status Board's SNMP Watch tile if you pinned a device. Unticking Remember deletes that host's item; unpinning deletes the tile's; *Forget All* in the SNMP tab's Options deletes them all.
- **Web cache and cookies**, kept by macOS's networking framework for SNAP:
  - **Where:** cached responses go in `~/Library/Caches/com.sevagbardakjian.snap`. Their URLs can include IPs and names you looked up. Cookies and HSTS data go in `~/Library/HTTPStorages/com.sevagbardakjian.snap` and `com.sevagbardakjian.snap.binarycookies`.
  - **What uses it:** most of SNAP's web requests. That includes the automatic ones (ipify, ipinfo.io, ipwho.is, and the online check), DNS-over-HTTPS lookups, Fingerprint, Multi-Host, HTTP Probe, the Dashboard HTTP Probe and GeoIP cards, and Speed Test. A cookie that any of these services sets is stored and sent back on later requests to it.
  - **Exceptions:** Network Health's captive-portal and proxy checks, SSL/TLS, the Network Map web requests, and Speed Test's latency check use throwaway sessions. Network Health's DNS-over-HTTPS lookup and its `1.1.1.1/cdn-cgi/trace` request (which returns your public IP) use the shared store. The UniFi tool keeps its login cookies in memory only, though its responses can still be cached.
- **macOS log** (Console): SNAP writes there only on errors:
  - if the bandwidth database can't be opened (the message includes its path, and so your user folder name)
  - if a database command fails
  - when Visual Trace can't locate a hop (the message includes the hop's IP)
- **Files** are written only where you choose in a Save dialog (exports, session reports).
- **Clipboard**: SNAP never reads it. It only writes to it when you click Copy.

To remove everything SNAP has stored:

1. Quit SNAP (⌘Q). Closing the window leaves it running in the menu bar.
2. Delete the app.
3. Run `defaults delete com.sevagbardakjian.snap`.
4. Delete these folders and files:
   - `~/Library/Application Support/SNAP`
   - `~/Library/Caches/com.sevagbardakjian.snap`
   - `~/Library/HTTPStorages/com.sevagbardakjian.snap`
   - `~/Library/HTTPStorages/com.sevagbardakjian.snap.binarycookies`
   - `~/Library/Saved Application State/com.sevagbardakjian.snap.savedState`, if present
5. If you saved a UniFi password, remove every `com.bardaklabs.snap.unifi` item in Keychain Access. Or run `security delete-generic-password -s com.bardaklabs.snap.unifi` repeatedly until it reports that no item was found. Do the same for saved SNMP community strings, service `com.bardaklabs.snap.snmp.community` (or press *Forget All* in the SNMP tab's Options before you delete SNAP).
6. If SNAP ever crashed, delete its crash reports (`SNAP-*.ips`) in `~/Library/Logs/DiagnosticReports`.
7. Optionally, turn off SNAP's Location Services, Local Network, and Notifications permissions in System Settings.
8. If you ever ran SNAP with `sudo`, repeat this for root's account.

### Security notes

- **Not sandboxed.** The App Sandbox would block the system tools and raw network probes listed above, so SNAP runs with the same file access as any app you launch yourself. It writes only what's listed above. It reads system network state to show it to you:
  - routing and DNS configuration, and `/etc/resolv.conf`
  - the ARP table
  - Wi-Fi details, and nearby Wi-Fi networks (WiFi Analyzer)
  - every TCP connection and its process ID (Connections)
  - your Mac's name, macOS version, and uptime
  - interface and TCP counters
  - DHCP lease details, including the date of `/var/db/dhcpclient/leases/<interface>.plist`
  - CPU, memory, and battery
  - per-process network byte counts

  None of it leaves your Mac except as this section describes.
- **Plain HTTP allowed.** App Transport Security is turned off for every host (`NSAllowsArbitraryLoads`), so SNAP can reach LAN devices with HTTP-only admin pages. SNAP itself sends plain HTTP to:
  - `ip-api.com` (Dashboard GeoIP card)
  - the Network Health portal checks (`captive.apple.com`, `www.msftconnecttest.com`, `cp.cloudflare.com`, `detectportal.firefox.com`, `www.gstatic.com`)
  - `http://<target>` in Fingerprint
  - the Network Map web requests to ports 80 and 8080
  - any `http://` URL you enter in HTTP Probe or its Dashboard card

  Anyone on the network path can read or change those requests.
- **Plain DNS.** DNS Propagation, DNS Benchmark, Fingerprint, BGP/ASN, and the Status Board's DNS Latency tile send unencrypted UDP/53 queries. The names they ask about are visible on the network path.
- **Other plaintext traffic.** Whois (TCP 43), SNMP, NetBIOS, SSDP, and syslog are unencrypted protocols, so what they carry is visible on the network path too.
- **UniFi credentials are protected by certificate pinning.** The first time a controller presents a certificate macOS doesn't trust (self-signed, expired, or for another name), SNAP shows its SHA-256 fingerprint and asks you to trust it. After that, a different untrusted certificate stops the connection before your credentials are sent. A certificate macOS trusts is accepted as usual. SNAP also refuses plain-HTTP controller URLs.
- **Not notarized.** Current builds are ad-hoc signed and haven't been checked by Apple's notarization service.

## Architecture
- SwiftUI, no third-party dependencies
- App Sandbox **disabled** — required for raw network access (direct distribution only)
- Interface byte counters read via `getifaddrs` / `sysctl` — no process spawning on the hot path
- DNS via DNS-over-HTTPS (lookups) and direct UDP/53 (propagation/benchmark)
- SNMP v2c via ASN.1 BER over UDP/161 (self-contained, no `net-snmp` dependency)
- libsqlite3 (system) for Bandwidth Monitor history
- CoreWLAN for Wi-Fi specifics; SystemConfiguration for routing state
- Full IEEE MA-L OUI registry (39,403 entries) bundled at [SNAP/oui_registry.txt](SNAP/oui_registry.txt), refreshed from <https://standards-oui.ieee.org/oui/oui.csv>

## Building
```bash
open SNAP.xcodeproj
# ⌘⇧K — Clean Build Folder
# ⌘R   — Build & Run
# ⌘U   — Run tests (124 tests in SNAPTests)
```

## Version
Current: **v1.5.5**. See [CHANGELOG.md](CHANGELOG.md).

### What's new in v1.5.5: open source, two e-ink themes, fixes
- **Open source.** SNAP is now free and open source under the GNU GPL v3. Contributions are welcome under a [Contributor License Agreement](CLA.md).
- **Two new themes: E-ink and Color e-ink.** Paper-and-ink looks, in a new E-ink group in the theme picker. On the Dashboard and sidebar they show status with shapes (filled, ringed, or hollow dots; inverted, outlined, or dashed chips; solid vs. dashed chart lines), so state stays readable without bright colors.
- **Fixed: plain-HTTP requests to the internet were blocked.** The Dashboard's GeoIP card, three of Network Health's captive-portal checks, and HTTP Probe on `http://` sites now work.
- **Fixed: the window title and toolbar now follow the tab on screen.** After visiting Network Info, other tabs showed its title and its Refresh, Copy, and Export buttons.
- **Fixed:** the Status Board's CPU row showed "%" with no number, and the Quick Tour said 38 tools (there are 35).
- **Fixed: narrow windows.** At the smallest window size, some tools pushed the sidebar off the window's edge or squeezed their labels until they broke mid-word. Their toolbars now wrap onto two rows when space is tight, and the sidebar always stays fully visible.
- **Easier to read and to find help.** The sidebar's status and version and the About panel's text are brighter in every theme. **Help → SNAP Help** opens this page, and the About window links to the source code and [sevag.ai](https://sevag.ai).
- **Credit stays with the code.** Every source file carries its copyright notice, and [NOTICE.md](NOTICE.md) asks anyone who shares SNAP to keep the attribution (GPL v3 section 7(b)).
- **Requires macOS 14.0**, now pinned instead of depending on the Xcode version used to build.

### What's new in v1.5.4 — persistent tabs, Daylight fix, real scan ranges
Builds clean; all 124 tests pass. Requires macOS 14.0 or later.
- **Tabs keep running and remember their state** — switching tabs used to destroy the tool you left, stopping a running ping, scan, or capture and clearing its results. Every tab you open now stays alive in the background. Automatic background work (Dashboard refreshes, Wi-Fi Analyzer live scans) pauses while its tab is hidden; info tabs (Network Info, ARP, DHCP, Connections, Interface Stats) refresh when you return.
- **Daylight theme fixed** — the app forced dark mode for every theme, so under Daylight the tables, lists, text fields, and gray labels rendered dark or near-invisible. Light/dark mode now follows the theme everywhere, including the menu bar popover (which had white text on a light background) and the detached Status Board.
- **Network Map scans real ranges** — it used to scan exactly one /24 (.1–.254) per entry and silently cut `10.0.0.0/16` down to `10.0.0.1–254`. It now takes any CIDR up to a /16, custom start–end ranges, single hosts, or a mix; prefills your actual subnet; shows a live host count; and asks before big scans, offering your own /24 as a quick alternative. Bulk Discovery uses the same parser, and its label now matches its real 8,192-address limit.
- **Picker labels no longer squeezed** — the Network Map's "View" label wrapped onto two lines when the device count changed width, and the Subnet Calculator's "Input Mode" picker was 43 pt too narrow. Both now size to their content.

### What's new in v1.5.3 — macOS 27 / Xcode 27 compatibility, UniFi pinning, release prep
Mostly a warning cleanup, plus five behavioral fixes, a security hardening, and release prep. Builds clean against the macOS 27 SDK with Swift 6.4; all 122 tests pass. Requires macOS 14.0 or later (these notes originally said 13.0; see the CHANGELOG).
- **UniFi certificate pinning** — the UniFi login used to accept any certificate on the connection carrying your admin credentials. Now a self-signed controller certificate is shown and approved once, then pinned; a changed certificate is refused inside the TLS handshake, before credentials are sent. Plain-HTTP controller URLs are refused.
- **[LICENSE](LICENSE) + [Privacy & Security](#privacy--security)** — proprietary license (free to use, source not open; since replaced by GPL-3.0), and an audited list of everything SNAP contacts, stores, and can do on your network.
- **Credited to Sevag Bardakjian** — About window, file headers, session-report footer, and copyright string.
- **Dashboard stops hammering ipinfo.io** — it used to repeat the public-IP and ISP lookups on every 30-second refresh, about 2,900 ipinfo requests a day, enough to get rate-limited. Now the public IP is re-checked every 10 min or when your network changes, and ISP details are fetched once per IP per day. Latency pings still run every 30 s.
- **System Health tells the truth** — the score now counts jitter, packet loss, and Wi-Fi signal on router-scale thresholds, and the Gateway Latency label uses the same model over the whole sample window instead of the latest ping. A connection that used to score 98 "Excellent" next to 64 ms of jitter now reads 43 "Degraded".
- **Real Wi-Fi details on the Status Board** — TX Rate, Security, Noise, and SNR were hard-coded mockup values (TX Rate always said 1441). All six cells are now live CoreWLAN readings; MCS is replaced by PHY (Wi-Fi 4/5/6/6E/7), since CoreWLAN doesn't expose MCS.
- **Menu bar dot judges the last 5 minutes** — it used to go green or red on a single ping. It now uses the same model as the Status Board, so all three agree. It still turns red ~20 s into an outage, and its tooltip explains the color.
- **Status Board "Run Now" actually runs a test now** — it previously only switched tabs *underneath a board that was still covering them*, so nothing happened. Added an autostart handoff token, made board dismissal mode-aware (in-window boards come down, detached second-monitor boards stay up), and forced the internet pane so the test isn't run behind the iPerf3 view.
- **All cross-tool handoffs fixed, not just Speed Test** — `ConsumeHandoffModifier` only fired on `.onAppear`, so a handoff to a tab you were *already* on was never consumed. "Send to Ping" while sitting on the Ping tab was silently broken too. Root cause was a missing `@ObservedObject` — the same SwiftUI view-diffing trap as the v1.5.0 theme-propagation bugs.
- **Swift 6 concurrency (14 warnings → 0)** — marked four pure-computation statics `nonisolated` (`dnsPing`, `runNettop`, `parse`, `ping`) since a `@MainActor` class also isolates its statics, and wrapped four `Timer`/`asyncAfter` callbacks in `Task { @MainActor in … }`.
- **Missing `Combine` import (4 → 0)** — `SidebarFooter`'s `Timer.publish(…).autoconnect()` property exposes a Combine type in a file that never imported Combine.
- **`ViewBuilder` limited-availability (2 → 0)** — `GeoIPView.mapPane` leaked the macOS-14-only `GeoIPMapView` into its opaque return type; both branches now type-erase through `AnyView`.
- **Left deliberately:** 20 `onChange(of:perform:)` deprecation warnings across 11 files (22 as of v1.5.4). These were left on the assumption that SNAP targets macOS 13, where the replacement API doesn't exist. It actually requires macOS 14, so they can now be switched to the newer API. (An earlier draft said 13 across 10 files — that was a miscount of a clean build's output, which logs each site twice.)

### What's new in v1.5.2 — Status Board rework
Full visual + functional pass on the Status Board:
- **9 tile types** (up from 6): existing Bandwidth / Wi-Fi / Alerts (now "System Health") / Favorites / Gateway Latency / Speed Test **plus** three new — **DNS Latency** (bar chart per resolver: System / Cloudflare / Google / Quad9), **System** (Mac uptime + CPU + memory + battery), **Top Talkers** (per-process bandwidth via `nettop`).
- **Enhanced visual language across every tile** — area-fill sparklines with peak markers, ring gauges (Wi-Fi quality, gateway latency, health score), a 4-hour activity timeline under System Health, min/max/avg/jitter/loss stat row under Gateway Latency, session-totals row under Bandwidth, history sparkline + inline **Run Now** button under Speed Test.
- **System Health reimagined** — composite 0–100 score (100 minus penalties for latency, packet loss, and recent alerts) + grade word + "CLEAN FOR 3h 12m" context + colored activity timeline. Actually useful now.
- **Header additions** — theme picker (switch themes without leaving the board) + compact **Public IP chip** with country flag + ISP/ASN (right-click for full host menu).
- **Reusable components** — new `RingGauge`, `AreaSparkline`, `StatusPill`, `ByteFormat` under `StatusBoardTiles.swift` for future tiles.

### What's new in v1.5.1 — post-launch polish
Substantial expansion on top of v1.5.0 features:
- **⌘K Command Palette** (Spotlight-style launcher, smart `ping HOST` / `lookup HOST` inline execution).
- **Status Board** (`⌘⇧B`) is now customizable — 6 tile types (Bandwidth / Wi-Fi / Alerts / Favorites / Gateway Latency / Speed Test), Edit Mode, drag-to-reorder, **Detach to a second monitor** (fullscreen).
- **Favorites**: pinned hosts strip on the Dashboard, up to 10 hosts auto-pinged (30 s idle / 10 s while Status Board is open). Each Favorites-tile row shows an RTT sparkline + hover-reveal ✕ to remove.
- **Right-click any host or IP** anywhere in SNAP (Network Map, ARP, DHCP, Traceroute, Lookup, Connections, Bonjour, Multi-Host, Bulk Discovery, Fingerprint, Visual Traceroute, ConnectionSummary hero rows): Copy / Send to Ping/Traceroute/Port Scan/Lookup/Whois / Find in Map / Add to Favorites.
- **Per-tool input history** on every functional card + full tool (clock-icon menu, last 10 values).
- **Menu bar heartbeat** (colored dot next to the network icon, driven by a 10-s gateway ping).
- **"Why this classification?" popover** on every Network Map device (lists the raw discovery signals that voted on its identity).
- **`dig` → DNSWire migration complete** — no more `/usr/bin/dig` shell-outs anywhere.
- **Service fixes** — Visual Trace map now plots hops via `ipwho.is` (ipinfo.io was rate-limiting anonymous requests; an intermediate `ip-api.com` attempt also failed in the field). Each hop row now shows the nation flag inline with the city/country (🇺🇸 Pasadena, United States). GeoIP now pre-resolves hostnames via `getaddrinfo` before hitting `ipwho.is` (fixes intermittent 404s on CDN-fronted domains).

### What's new in v1.5.0 — customizable Dashboard + Themes
Two headline features plus a god-file split:
- **Customizable Dashboard.** Connection Summary hero stays anchored; everything below is a user-pinnable grid of tool cards across **24 entries** in three buckets — **Functional** (10 inline form-and-result cards: Ping, Lookup, Port Scan, Subnet, BGP, Traceroute, GeoIP, Whois, HTTP Probe, Wake-on-LAN), **Live** (3 auto-refreshing summaries: Bandwidth, Wi-Fi, Recent Alerts), **Launcher** (11 tiles that open the full tab: Network Map, Packet Capture, Bulk Discovery, UniFi, SNMP, SSL/TLS, MTU Discovery, MTR, Syslog, Speed Test, Connections). Toolbar gets **+ Add Tools** (categorized modal), **Edit Mode** (✕ to remove, **drag-to-reorder** — the grid rearranges live as you hover the dragged card over targets), and **Reset Layout**. Layout persists per user.
- **Themes.** App-wide color theming with a picker in the Dashboard toolbar and an `Appearance` menu in the menu bar. Ten themes ship: Midnight (default), Daylight (light), Nord, Solarized Dark, Tokyo Night, Dracula, Matrix, Cyberpunk, DeeX (Deus Ex: HR gold-on-black), Synthwave '84. The central `NS` palette forwards to a `ThemeManager` singleton, so theme changes propagate instantly to every chrome view, hero card, and dashboard card.
- **Power-user combo.** Six small features that compose: **⌘K Command Palette** (Spotlight-style launcher with smart `ping HOST` / `lookup HOST` inline execution), **Status Board** (fullscreen ambient display on `⌘⇧B`), **Favorites** (up-to-10 pinned hosts auto-pinged every 30 s, with a strip above the Dashboard), **right-click any host** (Copy / Send to Ping / Traceroute / Port Scan / Lookup / Whois / Find in Map / Favorites), **per-tool input history** (clock-icon menu with last 10 values on every Ping/Lookup/Whois/Traceroute/Port Scan/GeoIP/BGP/HTTP input), and **menu bar heartbeat** (colored dot driven by gateway ping every 10 s). A 3D card-tilt effect was scoped but dropped before ship — it broke hit-testing on nested TextFields.
- **"Why this classification?" popover.** Every device in the Network Map's card view has a small **ⓘ** button (when signals exist) that opens a popover listing the raw discovery signals (mDNS / SSDP / NetBIOS / OUI / etc.) that voted on the device's identity. Trust or refute the classification at a glance.
- **Right-click coverage is comprehensive** — every result surface in SNAP that has a meaningful per-row host now supports the host context menu: Network Map (card + table), ConnectionSummary hero rows, ARP Table, DHCP Leases, Traceroute hops, Lookup answers, Connections (local/remote), Bonjour service IPs, Multi-Host Compare rows, Bulk Discovery, Fingerprint (IPv4/IPv6/Reverse DNS), and Visual Traceroute hops. Same menu everywhere: Copy / Send to Ping / Traceroute / Port Scan / Lookup / Whois / Find in Map / Add to Favorites.
- **Status Board** is customizable: pick from six tile types (Bandwidth, Wi-Fi, Alerts, Favorites, Gateway Latency, Latest Speed Test), drop tiles in Edit Mode, persists per user. **Detach to window** button pops it to a second monitor (fullscreen) if connected. `⌘⇧B` toggles in-window mode. Header now uses the real app icon.
- **`dig` → DNSWire migration.** The last three `dig` shell-outs in Fingerprint moved to the native UDP/53 querier. SNAP no longer invokes `/usr/bin/dig` anywhere; remaining shell-outs are `ping`, `traceroute`, and `arp`.
- **First-launch Quick Tour.** A 5-slide welcome modal introduces the customizable Dashboard, the 35-tool sidebar, the 10 themes, and key shortcuts. Opens once on first launch; reopen anytime from **Help → Quick Tour…**
- **Refactor:** `DeviceIdentifier.swift` (1351 LOC) split into three focused files — `DeviceIdentity.swift` (types + role-classification), `DeviceIdentifier.swift` (orchestrator + simple probes), `DiscoveryProbes.swift` (NetBIOS/SSDP/UBNT/mDNS). No behavior change.
- **Known limitation:** the macOS sidebar and `.regularMaterial` system surfaces don't fully respect custom themes (especially Daylight) — full bleed-through is deferred to a follow-up.

### What's new in v1.4.5 — stability: crash, hang & lifecycle fixes
A review-driven stability release (no new features):
- **Crash fixes** — input-validation traps in Port Scan (reversed ranges), Subnet Calc (`/32` at the address-space edges, now RFC-3021-correct for `/31`), DNS query builder (oversized labels), SNMP OID encoding (X.690 arc validation); NULL `ifa_addr` guards across all 12 `getifaddrs` walks.
- **Hang fixes** — three remaining drain-after-wait pipe deadlocks (Connections `netstat`, `ifconfig -a`, Bulk Discovery `arp`); Syslog no longer busy-spins on dead flows; Port Scan no longer leaks a connection per closed port.
- **Lifecycle** — switching tools now stops the running work (ping/traceroute/tcpdump/syslog listener/multicast joins/live WiFi scan/scans); Speed Test **Stop** genuinely aborts the transfer and terminates iperf3; stale lines from a stopped run can no longer interleave into a new run's table (the scrambled-chart bug).
- **Removed** the broken global Export sheet (⌘⇧E, always exported empty) — per-tool export and ⌘⇧R session report are unchanged.
- **Version strings single-sourced** from the bundle (`AppInfo.version`) — menu bar / session reports no longer show a stale version.

### What's new in v1.4.4 — shell-out → native APIs
First pass at replacing CLI subprocess spawns with native system calls, for robustness:
- **Default gateway / primary interface** now read from `SCDynamicStore` (`RouteInfo`) instead of parsing `netstat -rn` — collapsed 7 call sites to 1.
- **System DNS resolvers** read from `SCDynamicStore` (`DNSInfo`) instead of `scutil --dns`.
- **DNS A-record resolution** via `getaddrinfo` (was `/usr/bin/host`); **service banner grab** via `NWConnection` (was `/usr/bin/nc`); Menu Bar gateway no longer spawns `/sbin/route`.
- Remaining shell-outs (`ping`, `traceroute`, `arp`, `dig`) are deferred to later passes; `ipconfig`/`ifconfig` are kept (no clean public-API equivalent).

### What's new in v1.4.3 — technical-debt cleanup
A maintenance release focused on robustness and consistency (no new features):
- **`Shell.run` hardened** — drains the subprocess pipe to EOF *before* `waitUntilExit()`, eliminating a latent deadlock when a command emitted more than the ~64 KB pipe buffer; added a 60-second watchdog that terminates runaway processes.
- **UI design-token migration** — replaced raw `Color(red:…)` literals with shared `NS.*` design tokens across ~18 view files, unifying the look (the older tabs now match the newer ones). Single source of truth for the palette.
- **Export consistency** — added the standard TXT/CSV/JSON action bar to 12 more tabs (Ping, Lookup, Whois, Traceroute, Visual Trace, Port Scan, HTTP Probe, SSL/TLS, Fingerprint, Connections, Multi-Host, GeoIP).
- **Parser test coverage** — +14 tests covering CIDR expansion (Bulk Discovery), ARP-cache parsing (ARP Table), and WiFi band / channel / sub-band helpers — the logic most prone to silent breakage on OS updates.

## Contributing
Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to build and test, and the [Contributor License Agreement](CLA.md) you'll be asked to sign on your first pull request. Please report security issues privately; see [SECURITY.md](SECURITY.md).

## License
SNAP is free software, licensed under the [GNU General Public License v3.0](LICENSE) (`GPL-3.0-only`). You can use, study, change, and share it. If you distribute a modified version, you must release its source code under the same license.

SNAP comes with **absolutely no warranty**. Copyright © 2025–2026 Sevag Bardakjian.

**Attribution.** As section 7(b) of the GPL allows, SNAP adds one term: if you share SNAP or a version of it, keep the copyright notices naming Sevag Bardakjian, and a modified version must show "Based on SNAP by Sevag Bardakjian" with a link to this repository in its About window. See [NOTICE.md](NOTICE.md).

If you'd like to use SNAP under terms other than the GPL, for example in a closed-source product, open an issue or get in touch through GitHub.

Bundled data: the IEEE MA-L OUI registry (`SNAP/oui_registry.txt`), published by the IEEE Registration Authority.
