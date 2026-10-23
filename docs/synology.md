# 在群晖套件中心安装 Komari Agent

下载匹配 NAS 架构的 `.spk`，在 **套件中心 → 手动安装** 中选择文件，填写面板地址、Agent Token 和上报间隔，然后启动。常规安装和使用不需要启用 SSH，也不需要 Docker、Python 或额外的运行时套件。

当前面向 **DSM 7.0-41890 及以上**，标记为实验性。已完成静态构建、Linux 回归和浏览器页面测试；真实 DSM 的菜单入口、登录鉴权、套件安装及开机启动仍需实机验证。DSM 6 不在本套件的支持范围内。

## 选择安装包

在 [最新 Release](https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/releases/latest) 查找：

| 安装包 | CPU / DSM 架构 |
| --- | --- |
| `komari-agent-dsm7-amd64.spk` | Intel / AMD x86_64，使用 DSM 的 `x86_64` 架构族 |
| `komari-agent-dsm7-arm64.spk` | 64 位 ARM，使用 DSM 的 `armv8` 架构族 |
| `komari-agent-dsm7-arm.spk` | 32 位 ARM，使用 `armv7` 架构族及 `armada370`、`armada375`、`armada38x`、`armadaxp`、`comcerto2k`、`monaco` 平台 |

不确定时，按 NAS 型号查询群晖 [CPU / 套件架构列表](https://kb.synology.com/en-global/DSM/tutorial/What_kind_of_CPU_does_my_NAS_have)。套件中心也会检查包内的架构声明；不要修改 `INFO` 绕过不兼容提示。

这些套件未使用群晖签名，也未上架官方套件源。手动安装时请核对仓库和附件来源，再确认 DSM 的第三方套件提示。Release 的 `SHA256SUMS` 包含 `.spk` 的校验值。

## 配置与日常使用

安装后，以管理员身份登录 DSM，在 **主菜单 → Komari Monitor** 中打开管理页；套件中心的“打开”入口指向同一应用。页面通过 DSM 自带 Web 服务访问，不需要额外开放端口。请保留原 DSM 窗口，以便管理页使用当前登录会话；会话过期后，重新登录 DSM 并从主菜单打开应用。

- **面板地址**：填写 `https://panel.example` 一类的完整地址。HTTPS 会校验证书。
- **Agent Token**：填写面板中为这台 NAS 创建的 Agent Token，不是 DSM 登录密码。
- **上报间隔**：默认 3 秒，安装向导接受 1–86400 的整数秒，管理页可按 0.1 秒调整。
- **协议和过滤**：管理页可选择 V1/V2 协议。网卡列表用逗号分隔并支持 `*`，包含列表优先于排除列表，仍遵循 Agent 的默认排除规则。挂载点用分号分隔，例如 `/volume1;/volume2`。其他已有配置字段会保留。
- **启停**：在套件中心操作 Komari Minimal Monitor。启用后的开机启停由 DSM 调用套件生命周期脚本。

修改后点击 **保存并应用**。Token 不回显，留空表示保留当前值。运行中保存会重启 Agent，短暂中断上报；已停止时只保存配置，不自动启动。新配置导致进程启动失败时，会恢复原配置并尝试恢复服务；地址或 Token 无效但进程仍能运行时，则通过状态页排查连接问题，不自动回滚。页面每 3 秒刷新状态，不覆盖未保存的编辑；多窗口修改冲突时，点击“放弃更改”加载最新配置。

### 状态页怎么看

- **连接状态**：区分已停止、正在连接、正在重连和状态暂未更新；进程运行不等于上报成功。
- **最近发送 / 本次运行已发送**：来自 Agent 的实际发送事件，重启后重新计数。WebSocket 发送完成不代表服务端已确认接收。
- **当前传输**：显示 WebSocket 或 HTTP 回退，以及实际协议版本。
- **基础信息确认 / HTTP 报告确认**：仅在对应 HTTP 请求成功并通过响应校验后更新；没有 HTTP 回退时，“尚无 HTTP 确认”是正常现象。
- **最近错误**：显示连接或发送失败的错误类型，不输出 Token 或完整请求地址。详细数据是否入库仍以 Komari 面板为准。

套件只主动连接面板上报，不提供远程终端或任意命令执行。DSM 创建专用的 `komari-agent` 套件用户，Agent 和配置 CGI 均不使用 root 身份。CGI 通过 `conf/privilege` 以套件用户身份访问私有配置，并使用 DSM 会话及 `administrators` 组校验权限。低权限用户无法读取的数据可能缺失，尤其是受限制的传感器、GPU 和存储设备信息；不要为此授予管理员权限。

若已经用脚本或任务计划运行 Agent，请先停止旧实例。本套件不会接管、停止或删除包外的服务和配置。

## 升级与卸载

下载新版本的同架构 `.spk`，再次执行手动安装。升级不重新询问 Token，保留完整配置文件和月流量状态；是否恢复启动由 DSM 按升级前状态管理。Agent 本身不自动更新。

套件版本采用 `0.2.0-构建号`，构建号来自 Release 工作流的 `run_number`，保证此工作流后续发布的套件修订号递增。Agent 的原始标签（包括 `v0.0.0-main.N`）显示在套件描述中。这避免 DSM 拒绝含字母的版本号。Actions 中的开发包使用 Build 工作流自己的编号，供测试使用，升级正式安装请使用 Release 附件。

**卸载会删除套件的 Token、配置、上次配置备份和月流量状态，不会删除面板上的历史记录。** 更换面板或 Token 请直接使用管理页，无需卸载。重新安装会采用安装向导的新配置。

## 排错和高级配置

正常使用无需 SSH。需要管理员排错或修改高级配置时，相关路径为：

| 内容 | 路径 |
| --- | --- |
| 配置 | `/var/packages/komari-agent/var/config.json` |
| 上次保存前的配置 | `/var/packages/komari-agent/var/config.json.previous` |
| 月流量状态 | `/var/packages/komari-agent/var/state/` |
| 本次运行的上报状态 | `/var/packages/komari-agent/tmp/status.json` |
| 当前启动日志 | `/var/packages/komari-agent/tmp/agent.log` |
| 上一次启动日志 | `/var/packages/komari-agent/tmp/agent.log.previous` |
| 二进制 | `/var/packages/komari-agent/target/bin/komari-agent` |

配置文件及备份权限为 `0600`，都可能含 Token，不应公开分享。Token 不放在 Agent 命令行中。手动修改文件前停止套件，修改后重新启动；保留文件所有者和权限。配置支持项目原有的监控字段。月流量状态默认写入上表的 `state` 目录；若手动设置 `state_dir`，需自行管理该目录的访问权限、备份和清理。

日志存放在 DSM 的套件临时目录，重启/升级可能清除；每次启动保留上一份日志。运行期间不做日志轮转，不建议长期打开 `debug_log`。进程异常退出后，套件状态返回“已停止”，可从套件中心重新启动；当前未增加额外的崩溃重启守护进程。

## 自动构建和本地打包

- **Build**：编译三种架构的静态 Agent 和 CGI，生成 `.spk`，上传到 `komari-agent-dsm7-experimental` artifact；测试真实 amd64 Agent 的生命周期、状态输出和 CGI 配置 API。
- **Release**：在发布前将对应 Linux 产物打包；`.spk` 随现有 `komari-agent-*` 附件一起上传，并纳入 `SHA256SUMS`。首次包含此改动的工作流成功后，Release 才会出现套件附件。

本地需要 Zig 0.16.0 和 Python 3，仅构建机需要这些工具：

```sh
zig build -Doptimize=ReleaseSmall -Dversion=dev-dsm -Dtarget=x86_64-linux-musl -Ddsm-ui=true
python3 scripts/build_synology_spk.py --binary zig-out/bin/komari-agent \
  --arch amd64 --version dev-dsm --build-number 1 --output-dir build/synology
```

打包器默认读取 Agent 同目录中的 `komari-dsm-api.cgi`，也可用 `--cgi` 指定。ARM64 使用 `-Dtarget=aarch64-linux-musl --arch arm64`，ARM 使用 `-Dtarget=arm-linux-musleabi --arch arm`（分别用于 Zig 命令和打包命令）。每次要作为升级安装的本地构建，应提供比已安装包更大的 `--build-number`。打包器检查两个 ELF 的架构和动态加载器，拒绝错误架构或依赖动态 libc 的产物。

Linux 上运行回归测试：

```sh
python3 scripts/test_synology.py -v
KOMARI_TEST_AGENT=zig-out/bin/komari-agent python3 scripts/test_synology.py -v
python3 scripts/test_synology_ui.py
```

测试覆盖包结构、权限、凭据转义、错误输入、升级保留配置/状态、启停、PID 复用保护、未登录/非管理员拒绝访问、跨站写入拒绝、修改冲突、启动失败回滚，以及 WebSocket 发送与 HTTP 确认的区别。API 测试需以非 root 用户运行，在临时目录模拟 DSM 提供的鉴权及服务接口，不会修改宿主机服务；`-Ddsm-test-root` 仅供编译测试产物，不可用于分发。

开发机有 Chrome 时，可测试实际页面。先运行 `python3 scripts/test_synology_ui.py --serve 8876`，另开终端：

```sh
npm install --prefix build/synology/browser-test --no-save --no-package-lock playwright-core@1.55.1
PLAYWRIGHT_MODULE=../build/synology/browser-test/node_modules/playwright-core \
  node scripts/test_synology_browser.cjs http://127.0.0.1:8876/
```

测试保存、轮询不覆盖编辑、多窗口冲突、会话失效和窄屏布局，截图位于 `build/synology/ui-*.png`。`CHROME_BIN` 可指定 Chrome 可执行文件。这个仅绑定本机地址的预览使用假会话和假服务，不能验证 DSM 本身的登录和权限行为；测试完成后停止预览进程。

实机验收需要 NAS 管理员检查：匹配架构的包能通过手动安装；中英文向导能保存设置；主菜单及套件中心能打开管理页；管理员会话可读写、非管理员及退出登录后被拒绝；保存配置后上报恢复；断网时页面显示重连；套件中心停启有效；NAS 重启后恢复运行；升级保留 Token/配置/状态；卸载后无残留进程。问题反馈请附 NAS 型号、DSM 版本、包版本和去除敏感内容后的日志，不要上传 Token。

## 实现依据

- 群晖官方：[SPK 结构](https://help.synology.com/developer-guide/synology_package/introduction.html)、[INFO 必需字段与版本格式](https://help.synology.com/developer-guide/synology_package/INFO_necessary_fields.html)、[架构族映射](https://help.synology.com/developer-guide/appendix/platarchs.html)。
- 群晖官方：[低权限运行](https://help.synology.com/developer-guide/privilege/privilege_config.html)、[持久化目录](https://help.synology.com/developer-guide/integrate_dsm/fhs.html)、[生命周期及退出码](https://help.synology.com/developer-guide/synology_package/scripts.html)。
- 群晖官方：[DSM 应用配置](https://help.synology.com/developer-guide/integrate_dsm/config.html)、[应用会话鉴权](https://help.synology.com/developer-guide/integrate_dsm/web_authentication.html)。
- 向导使用传统 JSON 字段格式，参考维护中的 [SynoCommunity Beszel Agent 安装向导](https://github.com/SynoCommunity/spksrc/blob/master/spk/beszel-agent/src/wizard/install_uifile)；不引入仅供 DSM 7.2.2 的新 Vue 构建链。
