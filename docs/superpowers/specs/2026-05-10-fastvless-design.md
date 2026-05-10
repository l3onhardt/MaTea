# FastVLESS Design

## Goal

Build a small one-file server script for simple, safe, fast VLESS Reality deployment on low-end cloud servers. The script should feel like a user-facing installer, not a protocol toolbox. A normal install should take only a few choices and end with copyable `vless://` and optional `socks5://` links.

The first version focuses on:

- VLESS + REALITY using sing-box
- Automatic Reality SNI selection
- Conservative one-click BBR/network acceleration
- Optional upstream SOCKS5 outbound
- Optional local SOCKS5 export for tools such as fingerprint browsers
- Low dependency and low disk/RAM usage

## Users And Constraints

Target servers include NAT VPS, KVM VPS, AWS, GCP, and other small cloud machines. Some machines may have around 512 MB RAM, 1 vCPU, or about 1 GB disk. The installer must avoid heavyweight services and avoid installing packages unless required.

The script assumes the operator has root access and is deploying on their own server.

## User Flow

The default flow is:

1. User runs the script.
2. Script detects OS, CPU architecture, init system, virtualization, IP stack, public IP, free disk space, and BBR status.
3. User chooses `1. Recommended install`.
4. Script downloads sing-box, generates Reality keys, chooses a port, chooses a Reality SNI, writes config, and starts the service.
5. Script asks whether to configure an upstream SOCKS5 outbound.
6. Script asks whether to export a local SOCKS5 inbound.
7. Script applies conservative BBR if supported and user accepts.
8. Script prints the VLESS Reality link, SOCKS5 export link if enabled, current detected outbound IP, and management commands.

The management menu:

```text
1. Recommended install / repair
2. Show VLESS link
3. Configure upstream SOCKS5 outbound
4. Enable / disable local SOCKS5 export
5. Re-select Reality SNI
6. Enable BBR / show acceleration status
7. Show service status / logs
8. Uninstall
```

## Architecture

The script is a single POSIX-style shell script with Bash features. It keeps all persistent files under `/etc/fastvless`:

- `/etc/fastvless/fastvless.sh`: installed script copy
- `/etc/fastvless/sing-box`: sing-box binary
- `/etc/fastvless/config.json`: sing-box server config
- `/etc/fastvless/state.env`: generated UUID, keys, port, SNI, usernames, and selected options
- `/etc/fastvless/links.txt`: latest generated client links
- `/etc/fastvless/install.log`: install and update log

If systemd exists, the script creates `/etc/systemd/system/fastvless.service`. If systemd is unavailable, the script starts sing-box with `nohup` and records the PID under `/etc/fastvless/fastvless.pid`.

## Dependency Policy

Default dependencies are intentionally minimal:

- `curl` or `wget` for downloads and network checks
- `tar` or `unzip` only if needed for the selected sing-box release package
- `systemctl` only when already available

The script does not install these by default:

- `jq`
- `qrencode`
- `nginx`
- `acme.sh`
- `python3`
- `git`
- `cron`
- `iptables-persistent`
- WARP clients

When a required downloader or unpacker is missing, the script asks before installing only that package. If the machine is too small or the package manager is unavailable, it stops with a clear message.

Before installation, the script checks free space under `/etc` and `/tmp`. If available space is below 150 MB, the recommended install stops before downloading binaries.

## Platform Detection

The script detects:

- OS family: Debian/Ubuntu, RHEL-compatible, Alpine, or unsupported
- CPU architecture: amd64, arm64, armv7 where sing-box supports it
- Init system: systemd, OpenRC, or no known service manager
- Virtualization: KVM, Xen, VMware, Hyper-V, OpenVZ, LXC, Docker/container hints
- IPv4 and IPv6 availability
- Public IP through multiple lightweight endpoints
- Existing listeners on selected ports
- Current congestion control and queue discipline

Detection results are shown in a short human-readable summary before install.

## Reality SNI Selection

The script ships with a conservative candidate list and also supports manual input. It does not treat one fixed domain as universally best.

For each candidate, the script checks:

- TCP 443 connection success
- TLS handshake success with SNI
- TLS 1.3 support when detectable with available tools
- Certificate name matches the candidate domain
- ALPN support for `h2` or `http/1.1` when detectable
- No obvious forced redirect to another hostname
- Connection latency

The script picks the lowest-latency candidate that passes safety checks. If no candidate passes, it asks the user to enter a domain manually and validates it.

The menu can re-run SNI selection and regenerate the client link without changing the UUID unless the user chooses a full reinstall.

## sing-box Configuration

The default inbound is VLESS Reality over TCP:

- `type`: `vless`
- `flow`: `xtls-rprx-vision` when supported by the selected sing-box version
- `tls.enabled`: `true`
- `tls.server_name`: selected SNI
- `tls.reality.enabled`: `true`
- generated private/public key pair
- generated short ID
- one generated UUID

Default outbound is direct unless upstream SOCKS5 is configured.

Logs default to warning level to reduce disk writes on small machines.

## Upstream SOCKS5 Outbound

This is for replacing the VPS datacenter egress IP with an external SOCKS5 IP, such as a residential proxy.

Accepted input format:

```text
socks5://82.153.200.96:45001:dVO69eb58eac45a6:k8oRVgpuiE29MKCTOd
```

The script also accepts the common URI form:

```text
socks5://user:pass@82.153.200.96:45001
```

The parser extracts server, port, username, and password. The script then writes a sing-box SOCKS outbound and routes VLESS traffic through it. After restart, it checks the current outbound IP and prints whether the upstream appears active.

Credentials are stored in `/etc/fastvless/state.env` and `/etc/fastvless/config.json`, both with owner-only permissions.

## Local SOCKS5 Export

This is for external tools that only support SOCKS5, such as fingerprint browsers.

Security defaults:

- Disabled by default.
- Default listen address is `127.0.0.1`.
- Public listening requires explicit confirmation.
- Public listening always uses a generated username and password unless the user overrides them.

Output formats:

```text
socks5://user:pass@server_ip:port
socks5://server_ip:port:user:pass
```

If the server is NAT-only, the script asks for the public mapped port before printing the public SOCKS5 link.

## BBR And Network Acceleration

The BBR option is conservative:

- On normal KVM/cloud kernels, the script enables:
  - `net.core.default_qdisc=fq`
  - `net.ipv4.tcp_congestion_control=bbr`
- On OpenVZ, LXC, Docker, or kernels without BBR support, it only reports status and avoids unsafe changes.
- It writes settings to `/etc/sysctl.d/99-fastvless-bbr.conf`.
- It can remove that file and reload sysctl during uninstall.

The first version does not install custom kernels or BBR-plus kernels. That keeps the script safer on cloud providers and low-end machines.

## Port Strategy

The script prefers a random high TCP port for VLESS Reality to avoid conflicts. It checks whether the port is already listening before writing the config.

For NAT VPS, the script can ask the user for the provider-mapped public port and use that port in generated client links while keeping the local listen port in config.

The local SOCKS5 export uses a separate random high TCP port.

## Error Handling

Every major step prints a short status line and writes details to `/etc/fastvless/install.log`.

If a step fails:

- Download failure suggests trying curl/wget fallback and checking GitHub connectivity.
- Unsupported architecture stops before writing service files.
- Invalid upstream SOCKS5 input is rejected before modifying config.
- Service start failure prints the last service log lines.
- SNI selection failure asks for a manual SNI.

Config writes are atomic: write to a temporary file, validate with `sing-box check`, then replace the live config.

## Uninstall

Uninstall stops the service, removes service files, removes `/etc/fastvless`, and optionally removes the BBR sysctl file. It does not remove system packages that may have existed before the script ran.

## Testing Plan

Local script checks:

- Shell syntax check with `bash -n`
- Static linting if `shellcheck` exists, without requiring installation
- Unit-like parser tests for SOCKS5 input strings
- Config generation test using sample state values

Server smoke checks:

- `sing-box check -c /etc/fastvless/config.json`
- service start and status check
- public IP detection
- upstream SOCKS5 outbound IP check when configured
- generated VLESS link contains UUID, port, SNI, public key, short ID, and Reality parameters

## Out Of Scope For Version 1

- Web panel
- Subscription server
- QR code dependency
- TLS certificate automation
- Nginx fallback sites
- WARP installation
- Custom kernel or BBR-plus installation
- Multiple protocols beyond VLESS Reality and SOCKS5
