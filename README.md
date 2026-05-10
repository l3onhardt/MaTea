# FastVLESS

FastVLESS is a small Bash installer for a simple sing-box VLESS Reality server.

## Goals

- Simple default install
- Low dependency use on small VPS machines
- Automatic Reality SNI selection
- Conservative BBR setup when supported
- Optional upstream SOCKS5 outbound
- Optional local SOCKS5 export

## Usage

Run as root on your own server:

```bash
bash fastvless.sh
```

Choose:

```text
1. 推荐一键安装/修复
```

At the end, the script prints a `vless://` link. If local SOCKS5 export is enabled, it also prints two `socks5://` formats for tools with different import formats.

## Files

- `/etc/fastvless/config.json`
- `/etc/fastvless/state.env`
- `/etc/fastvless/links.txt`
- `/etc/fastvless/install.log`

## Notes

The default install avoids web panels, subscription services, nginx, acme.sh, qrencode, jq, git, and WARP clients. Public SOCKS5 export is disabled unless explicitly enabled and protected with username/password.
