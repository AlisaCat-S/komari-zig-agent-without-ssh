# Komari Minimal Monitor

这是一个仅上报监控数据的 Komari Agent fork。它保留 BasicInfo、资源使用率和 WebSocket/HTTP 上报，删除了所有服务端可触发的执行路径。

## 已删除能力

- Web SSH、PTY 和交互式 Shell
- 服务端下发的命令执行
- 服务端下发的 Ping/TCP/HTTP 探测
- 运行时自更新、二进制替换和 GitHub 代理回退
- 网络下载安装脚本和 root 自启动安装器

Agent 仅向配置的面板发起连接并上报监控数据。收到的服务端 WebSocket 帧会被丢弃，仅处理协议级 Ping/Pong 以保持连接；不会解析或执行面板任务。

## 构建

项目的 CI 工具链为 Zig `0.16.0`：

```sh
zig build -Doptimize=ReleaseSmall -Dversion=dev
```

产物位于 `zig-out/bin/komari-agent`。Agent 本身不提供自动下载或自动替换机制；发布的 Release 仅供管理员手动下载和部署。

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

## Linux 部署

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
- 本 fork 不会从 GitHub 或任何代理下载、更新或替换自身，因此不会再被上游 Release 覆盖。
