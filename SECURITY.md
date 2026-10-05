# Security Policy

## Reporting a vulnerability

**Please don't report security problems in public issues.** Report them privately through GitHub instead: go to the repository's **Security** tab and choose **Report a vulnerability**. Only the maintainer can see the report.

Include what you found, how to reproduce it, and what an attacker could do with it. SNAP is maintained by one person, so expect an acknowledgement within about a week. Fixes are prioritized by severity.

## What's in scope

SNAP is a network tool that runs unsandboxed and talks to devices on your network, so these matter most:

- Handling of credentials, such as the UniFi controller login and its Keychain storage.
- TLS and certificate validation, including UniFi certificate pinning.
- Anything that sends data somewhere the [Privacy & Security](README.md#privacy--security) section doesn't say it goes.
- Parsing of untrusted network input (DNS, SNMP, syslog, mDNS/SSDP, HTTP responses) that could crash SNAP or be exploited.
- How SNAP launches system tools (ping, traceroute, arp, tcpdump, and so on).

## Supported versions

Security fixes go into the latest release.
