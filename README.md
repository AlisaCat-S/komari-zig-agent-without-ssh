# Komari Minimal Monitor

这是一个仅上报监控数据的 Komari Agent fork。它保留 BasicInfo、资源使用率和 WebSocket/HTTP 上报，删除了所有服务端可触发的执行路径。

## 已删除能力

- Web SSH、PTY 和交互式 Shell
- 服务端下发的命令执行
- 服务端下发的 Ping/TCP/HTTP 探测
- 运行时自更新、二进制替换和 GitHub 代理回退
- 上游/代理下载、运行时自更新和 root 运行服务

Agent 仅向配置的面板发起连接并上报监控数据。收到的服务端 WebSocket 帧会被丢弃，仅处理协议级 Ping/Pong 以保持连接；不会解析或执行面板任务。

## 构建

项目的 CI 工具链为 Zig `0.16.0`：

```sh
zig build -Doptimize=ReleaseSmall -Dversion=dev
```

产物位于 `zig-out/bin/komari-agent`。Agent 运行时不提供自动下载或自动替换机制；Release 提供由管理员主动运行、并校验附件哈希的安装器。

## 下载

每次推送到 `main` 后，GitHub Actions 会先完成全部测试和跨平台编译；成功后自动创建本 fork 的 GitHub Release。下列链接始终指向最新成功发布的修改版：

首次启用前，在仓库 `Settings -> Actions -> General -> Workflow permissions` 选择 `Read and write permissions`；发布工作流需要该权限创建标签、Release 和附件。

- [最新 Release 与全部产物](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest)
- [SHA256SUMS](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/SHA256SUMS)

| 平台 | 直接下载 |
| --- | --- |
| Linux x86_64 | [komari-agent-linux-amd64](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-amd64) |
| Linux ARM64 | [komari-agent-linux-arm64](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-arm64) |
| Linux x86 | [komari-agent-linux-386](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-386) |
| Linux ARM | [komari-agent-linux-arm](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-arm) |
| Linux MIPS | [komari-agent-linux-mips](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-mips) |
| Linux MIPSel | [komari-agent-linux-mipsel](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-mipsel) |
| Linux MIPS64 | [komari-agent-linux-mips64](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-mips64) |
| Linux MIPS64el | [komari-agent-linux-mips64el](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-mips64el) |
| Linux RISC-V 64 | [komari-agent-linux-riscv64](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-riscv64) |
| Linux s390x | [komari-agent-linux-s390x](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-s390x) |
| Linux LoongArch64 | [komari-agent-linux-loong64](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-linux-loong64) |
| FreeBSD x86_64 | [komari-agent-freebsd-amd64](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-freebsd-amd64) |
| FreeBSD ARM64 | [komari-agent-freebsd-arm64](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-freebsd-arm64) |
| FreeBSD x86 | [komari-agent-freebsd-386](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-freebsd-386) |
| FreeBSD ARM | [komari-agent-freebsd-arm](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-freebsd-arm) |
| macOS x86_64 | [komari-agent-darwin-amd64](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-darwin-amd64) |
| macOS ARM64 | [komari-agent-darwin-arm64](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-darwin-arm64) |
| Windows x86_64 | [komari-agent-windows-amd64.exe](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-windows-amd64.exe) |
| Windows ARM64 | [komari-agent-windows-arm64.exe](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-windows-arm64.exe) |
| Windows x86 | [komari-agent-windows-386.exe](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/komari-agent-windows-386.exe) |

## 安装脚本

安装器支持 Linux systemd、OpenRC、Upstart、OpenWrt `procd`、FreeBSD `rc.d`、macOS 用户级 `launchd` 和 Windows。所有 Release 附件均来自本仓库：[install.sh](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/install.sh)、[install.ps1](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/install.ps1) 与 [SHA256SUMS](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/SHA256SUMS)。

安装器只会从 `AlisaCat-S/komari-zig-agent-without-ssh` 的同一 GitHub Release 下载二进制、配置模板和服务定义，并校验 `SHA256SUMS`。不会访问原 fork 上游、GitHub 代理或第三方二进制服务；Agent 本身不会自动更新。

Linux、FreeBSD 和 OpenWrt 需要以 root 运行安装器。Linux/FreeBSD 上取得 root shell 后，可按下面方式下载、校验并安装：

```sh
curl -fLO https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/install.sh
curl -fLO https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/SHA256SUMS
grep '  install.sh$' SHA256SUMS | sha256sum -c -
chmod 0755 install.sh
./install.sh
```

OpenWrt 通常自带 `uclient-fetch` 或 `wget`，无需安装 `curl`。以 root 登录后执行：

```sh
uclient-fetch -O install.sh https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/install.sh
uclient-fetch -O SHA256SUMS https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/SHA256SUMS
grep '  install.sh$' SHA256SUMS | sha256sum -c -
chmod 0755 install.sh
./install.sh
```

安装器会在 OpenWrt 上生成 `/etc/init.d/komari-agent`，以低权限 `komari` 用户通过 `procd` 运行，并将二进制安装到 `/usr/bin/komari-agent`。若设备没有 HTTPS 下载支持，先通过 OpenWrt 自己的软件源安装 CA/TLS 支持后再执行上述命令。

macOS 必须由当前登录用户运行，不能使用 `sudo`：

```sh
curl -fLO https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/install.sh
curl -fLO https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/SHA256SUMS
grep '  install.sh$' SHA256SUMS | shasum -a 256 -c -
chmod 0755 install.sh
./install.sh
```

指定固定版本时，将 `KOMARI_VERSION` 设为 Release 标签：

```sh
KOMARI_VERSION=v0.1.42.1 ./install.sh
```

首次安装只创建配置和服务定义，不会启动 Agent。编辑配置中的 `endpoint` 和 `token` 后，按对应平台启用：

```sh
# systemd Linux
sudoedit /etc/komari-agent/config.json
sudo systemctl enable --now komari-agent

# OpenRC Linux
sudo rc-update add komari-agent default
sudo rc-service komari-agent start

# Upstart Linux
sudo initctl start komari-agent

# OpenWrt
vi /etc/komari-agent/config.json
/etc/init.d/komari-agent enable
/etc/init.d/komari-agent start

# FreeBSD
sudoedit /usr/local/etc/komari-agent/config.json
sudo sysrc komari_agent_enable=YES
sudo service komari-agent start

# macOS
${EDITOR:-vi} "$HOME/Library/Application Support/KomariAgent/config.json"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.komari.agent.plist"
```

Linux、OpenWrt 和 FreeBSD 服务均以低权限 `komari` 用户运行；macOS 使用当前登录用户。Windows 以管理员身份打开 PowerShell 后下载并运行。脚本会创建使用 `NT AUTHORITY\LocalService` 的启动任务；首次安装后先编辑配置，再启用任务。

```powershell
Invoke-WebRequest https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/install.ps1 -OutFile .\install.ps1
Invoke-WebRequest https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest/download/SHA256SUMS -OutFile .\SHA256SUMS
$checksumLine = Get-Content .\SHA256SUMS | Where-Object { $_ -match '\s+\*?install\.ps1$' } | Select-Object -First 1
$expected = ($checksumLine -split '\s+')[0]
if (-not $expected -or (Get-FileHash .\install.ps1 -Algorithm SHA256).Hash -ne $expected) { throw 'install.ps1 SHA-256 verification failed' }
powershell -ExecutionPolicy Bypass -File .\install.ps1
notepad "$env:ProgramData\KomariAgent\config.json"
Enable-ScheduledTask -TaskName 'Komari Agent'
Start-ScheduledTask -TaskName 'Komari Agent'
```

指定版本时追加 `-Version v0.1.42.1`。

## 手动 systemd 部署

仓库提供 [deploy/komari-agent.service](deploy/komari-agent.service)，服务固定使用低权限账户 `komari`。管理员应先创建账户和配置，再部署已经验证过的本地二进制：

```sh
useradd --system --user-group --home-dir /var/lib/komari-agent --shell /usr/sbin/nologin komari
install -o root -g root -m 0555 zig-out/bin/komari-agent /usr/local/bin/komari-agent
install -d -o root -g komari -m 0750 /etc/komari-agent
install -o root -g komari -m 0640 deploy/config.json.example /etc/komari-agent/config.json
install -o root -g root -m 0644 deploy/komari-agent.service /etc/systemd/system/komari-agent.service
systemctl daemon-reload
systemctl enable --now komari-agent
```

将 `/etc/komari-agent/config.json` 中的 `endpoint` 和 `token` 替换为实际值。Token 位于配置文件中，应保持仅 root 和 `komari` 组可读。

## 容器

`Dockerfile` 创建并使用 `komari` 非 root 用户。容器仍需要可访问的 `/proc` 和网络接口才能采集相应指标。

## 安全边界

- HTTPS/WSS 连接始终校验证书；请为面板配置受信任的 TLS 证书。
- 面板地址和 Token 仍是敏感配置。请使用 HTTPS/WSS，并限制配置文件和服务管理权限。
- Agent 运行时不会从 GitHub、上游仓库或代理下载、更新或替换自身，因此不会再被上游 Release 覆盖。管理员主动运行的安装器只会从本仓库的 Release 下载并校验附件。
