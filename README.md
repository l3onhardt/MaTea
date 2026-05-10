# 马王脚本 MaTea

马王脚本，也可以叫马哥梯子，是一个尽量简单、低依赖的 `sing-box` 一键部署脚本。默认主线是 `VLESS + REALITY`，脚本会自动检测服务器环境、优选 Reality SNI、按需开启保守 BBR，并在最后直接输出可复制的 `vless://` 链接。

```text
 __  __    _    __        ___    _   _  ____
|  \/  |  / \   \ \      / / \  | \ | |/ ___|
| |\/| | / _ \   \ \ /\ / / _ \ |  \| | |  _
| |  | |/ ___ \   \ V  V / ___ \| |\  | |_| |
|_|  |_/_/   \_\   \_/\_/_/   \_\_| \_|\____|
马王脚本
马哥梯子 | VLESS Reality 一键加速
```

## 特性

- 一键安装 `VLESS + REALITY`
- 自动优选 Reality SNI
- 安装时可手动指定 VLESS 端口，回车则使用随机高位端口
- 自动检测系统、架构、虚拟化、IPv4/IPv6、公网 IP、磁盘空间和 BBR 状态
- 支持一键保守 BBR，不安装自定义内核
- 支持外部 SOCKS5 作为上游出口，让服务流量走家宽/住宅代理
- 支持导出本机 SOCKS5 给指纹浏览器等工具使用
- 低配 VPS 友好，不默认安装 Web 面板、Nginx、ACME、WARP、订阅服务、`jq`、`qrencode`、`python3` 或 `git`

## 快速使用

在你自己的 Linux 服务器上用 root 运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/l3onhardt/MaTea/main/fastvless.sh)
```

如果服务器没有 `curl`，可以先下载后运行：

```bash
wget -O fastvless.sh https://raw.githubusercontent.com/l3onhardt/MaTea/main/fastvless.sh
bash fastvless.sh
```

进入菜单后选择：

```text
1. 推荐一键安装/修复
```

安装时会询问 `VLESS Reality` 端口。你可以输入指定端口，也可以直接回车使用脚本给出的随机端口。NAT 机器如果本地监听端口和公网映射端口不同，按提示填写公网映射端口。

安装结束后会输出：

```text
vless://...
```

如果开启了本机 SOCKS5 导出，还会输出：

```text
socks5://user:pass@server_ip:port
socks5://server_ip:port:user:pass
```

## 菜单

```text
1. 推荐一键安装/修复
2. 查看 VLESS 链接
3. 配置上游 SOCKS5 出站
4. 开启/关闭本机 SOCKS5 导出
5. 重新优选 Reality SNI
6. 一键 BBR/查看加速状态
7. 查看服务状态/日志
8. 卸载
0. 退出
```

## SOCKS5 用法

### 上游 SOCKS5 出站

如果你有外部 SOCKS5，比如住宅代理，可以填入：

```text
socks5://82.153.200.96:45001:username:password
```

也支持标准格式：

```text
socks5://username:password@82.153.200.96:45001
```

配置后，VLESS 服务流量会通过这个 SOCKS5 出站。

### 本机 SOCKS5 导出

如果你需要给指纹浏览器或其他只支持 SOCKS5 的工具使用，可以在菜单里开启本机 SOCKS5 导出。默认只监听 `127.0.0.1`；如果要公网访问，脚本会要求显式确认，并使用用户名和密码。

## 文件位置

- `/etc/fastvless/config.json`
- `/etc/fastvless/state.env`
- `/etc/fastvless/links.txt`
- `/etc/fastvless/install.log`

查看链接：

```bash
cat /etc/fastvless/links.txt
```

## 安全说明

- 默认不开放本机 SOCKS5 到公网。
- 公网 SOCKS5 必须带用户名和密码。
- 上游 SOCKS5 账号会写入 `/etc/fastvless/state.env` 和 `/etc/fastvless/config.json`，文件权限限制为 root 可读写。
- BBR 只做保守 sysctl 配置；OpenVZ、LXC、Docker 等环境不会强行修改内核能力。

## 本地验证

仓库内置了无依赖测试：

```bash
bash -n fastvless.sh
bash tests/run.sh
```

当前测试覆盖 SOCKS5 解析、VLESS 链接生成、sing-box 配置生成、SNI 选择、BBR 配置文件、菜单文案和服务文件生成。
