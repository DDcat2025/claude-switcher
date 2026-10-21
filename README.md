<div align="center">

# Claude 切换器

**Fail-Closed 账号环境管理器 —— 把真实 IP 泄漏拦截在启动之前**

> 🛠️ **本项目持续活跃更新中**——防护项随目标平台风控演进不断增加，见下方[路线图](#路线图)。

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS-blue.svg)]()
[![Windows](https://img.shields.io/badge/Windows-Beta-lightgrey.svg)](windows/)
[![Linux](https://img.shields.io/badge/Linux-Beta-lightgrey.svg)](linux/)
[![UI](https://img.shields.io/badge/UI-SwiftUI-orange.svg)]()
[![Dependencies](https://img.shields.io/badge/Dependencies-Zero-brightgreen.svg)]()

<img src="assets/icon-2048.png" width="128">

</div>

---

## 为什么做这个

AI 服务平台的风控已经从"看 IP"进化到**全维度环境画像**：时区、Locale、DNS 出口、WebRTC 候选地址、设备指纹、行为时序。绝大多数封号不是因为你做错了什么，而是某个你没意识到的场景里，真实出口 IP 悄悄溜出去了一次——哪怕只是一个 TCP SYN 握手包。

本项目的立场：**防御不建立在"用户记得"上，而建立在系统级的硬性约束上**。

> 代理暴毙、软件静默升级、随手乱点——这些场景下受保护进程会被保镖在秒级终止，裸连窗口被压缩到最小。这是**进程级急停**，不是防火墙级保证：巡检周期内存在固有的 TOCTOU 窗口，边界说明见 [SECURITY.md](SECURITY.md)。

## 核心创新

### 1. Block-on-Fail 环境审计引擎

每次启动前强制执行 14 项环境指纹审计，**任一指标不达标，应用物理上不会被拉起**：

| # | 检查项 | 防什么 |
|---|---|---|
| 01 | 代理内核 | 代理根本没在跑就启动 |
| 02 | TUN 网卡 | 系统代理开着但流量没被接管 |
| 03 | 出口 IP | 出口国家/地区异常 |
| 04 | IP 一致性 | 出口 IP 突变（跳节点是风控信号） |
| 05 | 时区 | 系统时区与 IP Geo-location 冲突 |
| 06 | 地区 Locale | 系统区域设置不符 |
| 07 | IPv6 | 双栈旁路直连（最隐蔽的泄漏通道之一） |
| 08 | DNS 隧道 | Fake-IP 校验，杜绝明文 DNS 泄漏 |
| 09 | WebRTC | 多节点 STUN 交叉探测（详见第 2 节） |
| 10 | 保镖守护进程 | Kill-Switch 是否在线（详见第 3 节） |
| 11 | 置顶路由规则 | 生态域名是否被强制走代理（详见第 6 节） |
| 12 | 客户端语言 | 防止 JS 层 `navigator.language` / `Intl` 读出系统中文 |
| 13 | ASN 属性 | 住宅宽带 vs 机房 IP（Residential vs Datacenter） |
| 14 | 生态可达性 | claude.ai / api.anthropic.com 连通性验证 |

> 关于「IP 与上次一致」：除了比对上一次出口，审计引擎还会维护 48 小时出口 IP 历史——**48 小时内出口 IP 变化 ≥3 次会亮黄色警告**（不阻断启动）。IP 频繁漂移意味着账号画像在风控眼里"居无定所"，建议固定一条高质量住宅节点长期使用。

### 2. 纯标准库手写 STUN 协议栈的 WebRTC 泄漏探针

不依赖浏览器内核（headless Chrome 的 ICE 子系统在无人值守场景下根本不工作——我们踩过这个坑），直接用 `socket` + `struct` 手工构造 RFC 5389 Binding Request，解析 XOR-MAPPED-ADDRESS。

真正的创新在**交叉验证拓扑**：探测列表同时包含全球节点（Google/Cloudflare）与国内骨干节点——走隧道时应回传代理出口 IP，裸连时国内节点必然秒回并当场抓获真实 IP。两种状态可区分、零误报、不依赖"恰好不通"。

### 3. Fail-Closed Kill-Switch

常驻守护进程以 10s 周期巡检隧道健康度（内核进程 × 虚拟网卡双因子），隧道中断即刻终止受保护进程。区别于客户端自带的 Fail-Open 容错重试——那种机制会把含真实 IP 的握手包送到对方网关日志里，哪怕最终"超时失败"。

### 4. Session Snapshot 快照隔离

多账号不是"登出再登入"（那会产生大量认证事件与指纹抖动），而是**物理交换数据卷**：每个账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换时原子化封存/载入。对服务端而言，每个账号看到的都是一台恒定不变的设备。

### 5. 配置漂移自愈（Watchdog）

软件更新会静默重置你的安全配置（我们的生产环境里，TUN 开关被代理客户端更新重置了 4 次，系统时区被改回 8 次）。Watchdog 周期巡检 + 基线回滚 + 全程留痕，配置漂移从"事故"降级为"日志里的一行记录"。

### 6. Pinned Routing 置顶路由

目标服务全家族域名及其生态依赖（Turnstile 人机验证 / Telemetry / Payment / Support）置顶锁定代理路由，优先级高于任何第三方分流规则集——不信任、不验证、直接免疫规则库误判。

## 实战战绩

这不是玩具项目，每个机制都有生产环境实战记录：

```
2026-10-07 00:31:12  代理离线(内核或TUN丢失),已自动关闭 Claude   ← Kill-Switch 真实拦截
2026-10-04 12:55:26  时区异常: [Asia/Shanghai] 已自动恢复        ← Watchdog 第 8 次拦截漂移
```

## 界面

![Screenshot](docs/screenshot.png)

原生 SwiftUI 单文件应用（无 Xcode 工程、无第三方依赖，`swiftc` 一条命令出可执行文件），图标由 Swift 代码程序生成——整个仓库不含一张设计素材。

## 安装

**系统要求**：macOS · Clash Verge / Shadowrocket / sing-box / ClashX / Surge 任一（TUN 可用）· Claude 桌面版 · python3

> **Windows 用户**：[`windows/`](windows/) 目录提供 Windows 版（PowerShell + WPF，Beta），安装与注意事项见 [windows/README.md](windows/README.md)。
> **Linux 用户**：[`linux/`](linux/) 目录提供 Linux 版（bash + systemd，Beta），设计取舍（无官方桌面版→切换浏览器登录态）见 [linux/README.md](linux/README.md)。

```bash
# 克隆后双击 installer/安装.command 即可,自动识别代理客户端、代理组名与地区目标
git clone https://github.com/YOURSJEYO/claude-switcher.git
```

## 地区自适应

不再锁死美国：安装程序按当前出口 IP 的国家自动锁定**目标国家 + 时区 + 地区格式**三件套（出口是 CN 会直接拒装，逼你先挂好代理）。之后换了其他国家的节点，不用重装，一条命令重新适配：

```bash
~/.local/bin/claude-switch.sh set-region
# 自动探测出口国家 → 改写自身配置 → 设地区格式 → 弹一次授权锁时区 → 同步看门狗
# 输出: OK:region=JP tz=Asia/Tokyo locale=ja_JP
```

14 项检查里的「出口 IP / 时区 / 地区」全部按新目标判定，界面无需任何改动。

## 不会配置？交给你的 AI

仓库根目录的 [`AGENTS.md`](AGENTS.md) 是一份完整的 **Agent 交接提示词**：把它直接粘贴给你的本地模型（Kimi Code / Cursor / Claude Code 等），它会按文档自动完成环境检查、安装、配置与验收。里面还附了我们实战踩过的全部坑的排障手册。

## 使用

1. 双击桌面「Claude切换器」→ 等待 14 项检查
2. 全绿 → 选账号启动；有红项 → 「一键修复」自动处理
3. B 账号首次使用登录一次，以后 A/B 随切随用、互不干扰
4. 换了其他国家的节点 → 跑一次 `~/.local/bin/claude-switch.sh set-region`，国家/时区/地区格式一键重新锁定

## Web 版环境检测（零安装）

手机 / 平板浏览器打开即测，无需安装：[https://yoursjeyo.github.io/claude-switcher/](https://yoursjeyo.github.io/claude-switcher/)

页面逐项评估 6 类浏览器侧信号，并给出总评与失败项：

- **出口 IP / 归属**：ipinfo.io 优先，Cloudflare trace 兜底
- **地区一致性**：浏览器时区、UTC 偏移与语言是否和出口国家矛盾
- **WebRTC 泄漏**：STUN 候选地址与出口 IP 比对，识别 mDNS 混淆与 fake-IP
- **IPv6 暴露**：IPv6 是否可直连、归属国家是否与 IPv4 出口一致
- **DNS 泄漏（近似）**：1.1.1.1 / Google DoH 公共加密解析可达性
- **浏览器指纹展示**：Canvas 哈希、WebGL vendor/renderer、屏幕与设备参数（只展示，不阻断）

纯前端、无追踪、无 localStorage；检测请求只发往公共 API，结果不上传。它只评估浏览器侧信号，**不替代桌面版 14 项审计**，也不检测 TUN / 保镖 / 进程级泄漏。部署方式与完整隐私说明见 [docs/WEB-README.md](docs/WEB-README.md)。

## 已有代理的独立诊断（macOS CLI）

已有 HTTP/SOCKS 入口、由其他工具管理账号时，可以先单独检查 Claude 的网络传输，无需运行安装器或启动 Claude：

```bash
bash core/claude-switch.sh diagnose-proxy --proxy http://127.0.0.1:18080
# 已安装版本:
~/.local/bin/claude-switch.sh diagnose-proxy --config /path/to/private-proxy.json
```

私有配置文件只需包含 `{"proxy_url":"http://127.0.0.1:18080"}`。也可明确设置 `CLAUDE_SWITCHER_PROXY_URL`；命令行/配置文件优先于该变量。需要代理认证时优先使用私有配置或变量，避免凭据出现在本命令的参数中。支持 `http`、`https`、`socks5`、`socks5h`，地址必须包含端口；不会自动扫描代理或回退直连。

命令只向固定的 Claude 网页/API 地址发送无账号认证的请求，输出 JSON，不读取账号存档、不创建状态目录、不更改系统设置、不启动/关闭应用。代理地址和凭据不进入报告；代理凭据通过 curl 标准输入传递。它随现有核心脚本分发和更新，无需额外服务。

- 退出码 `0`：两个目标均收到经过 TLS 验证的 HTTP 响应。API 的 `401` 单独标为 `unauthenticated`，网页的 `403` 标为 `access_restricted`，均不等于账号或业务可用。
- 退出码 `1`：至少一项传输失败、超时或输出异常；未完成的检查保持未知。
- 退出码 `2`：代理或参数配置无效。普通 `HTTP_PROXY` / `NO_PROXY` 等继承值不会代替明确选择的入口。

该命令仅诊断上述官方域名的传输，不验证自定义 API Base URL/第三方供应商、DNS/WebRTC/IPv6 泄漏，不产生启动许可，也不绕过或修改原有的 TUN 启动审计。可用 `CLAUDE_SWITCHER_PYTHON` 选择已有 Python 解释器；默认 `python3`。

隔离回归测试（不连接真实代理或账号）：`python3 -m unittest discover -s tests -v`。

## 使用卫生与被封急救

工具能兜底技术泄漏，兜不住主动作死。以下每条都是社区里用账号堆出来的教训：

- **先退出 Claude，再断/换代理**。断线重连的那几秒是全年最高危时刻——保镖会兜底杀进程，但正确姿势永远是先退客户端再动网络，不要反过来挑战物理
- **不要把订阅账号接入任何第三方工具/中转站/拼车服务**（2026 年头号封号诱因，没有之一）。你的会话凭证经过谁的机器，谁就拥有你的账号
- **支付卡段、账单地址尽量与出口国家一致**。美国出口配国内双币卡 + 北京账单地址，等于在风控表格里自己填了"我是跨区用户"
- **新账号前几天不要拉满高档位用量**。注册即跑满额度的行为序列，是批量养号工作室的指纹，正常用户不长这样
- **真被封了**：先用被封账号登录 [claude.ai/restricted](https://claude.ai/restricted) 提交申诉（社区历史成功率约十分之一，值得一试）；申诉前先在封号提示页导出你的数据；**不要立刻用同一台机器、同一张卡、同一个邮箱再注册新号**——绕过封禁本身违反条款，而且关联指纹会让新号活得比旧号还短

## 项目结构

```
├── app/main.swift          # SwiftUI 界面(单文件)
├── core/
│   ├── claude-switch.sh    # 核心逻辑:审计/切换/修复
│   └── stun-probe.py       # STUN 探针(手工协议实现)
├── windows/                # Windows 版(PowerShell 核心 + WPF 界面, Beta)
├── linux/                  # Linux 版(bash 核心 + systemd 保镖 + 终端菜单, Beta)
├── docs/                   # Web 版环境检测页(index.html 等, GitHub Pages 从这里发布) + 项目文档
├── daemons/                # Kill-Switch / Watchdog / 自动更新 launchd 模板
├── installer/              # 双击安装/卸载
├── scripts/gen-sums.sh     # 重新生成 SHA256SUMS(改动 core/daemons/installer 后必跑)
├── SHA256SUMS              # 发布工件完整性校验清单(自动更新逐项比对)
└── assets/                 # 程序生成图标
```

## 二改指南

- **改界面**：编辑 `app/main.swift`，`swiftc -O -parse-as-library` 重编译即可
- **加检查项**：`core/claude-switch.sh` 的 `checkdetail()` + UI 的 `keyMap` 各加一行
- **改防护策略**：`daemons/` 里的模板即全部守护逻辑

欢迎 Fork / PR。Issue 区接受场景补充——你遇到的每一个真实泄漏场景，都可能成为下一个检查项。

## 问题反馈

- 提交 [Issue](https://github.com/YOURSJEYO/claude-switcher/issues)
- 在 [Linux.do](https://linux.do) 论坛发帖讨论
- **安全问题请走非公开渠道**：见 [SECURITY.md](SECURITY.md)（GitHub Private Vulnerability Reporting 优先）

反馈掉登录、弹盾类问题时，请附上「应用设置 → 日志」导出的日志，里面不含密码和 Cookie 原文；如果可以，也请附上可复现步骤。

## 路线图

本项目按"实战驱动"迭代——风控怎么进化，防护就怎么跟上：

- [x] macOS 版：14 项环境审计 + Kill-Switch + 快照切换 + 漂移自愈（已稳定）
- [x] Windows 版（Beta）：核心逻辑全移植
- [x] Linux 版（Beta）：bash 核心 + systemd 保镖 + 终端菜单
- [ ] Windows 版稳定化：真机测试迭代，收敛 Beta
- [ ] Linux 版稳定化：多发行版实测迭代
- [x] Web 版环境检测页：手机/平板浏览器打开即测，零安装
- [ ] 更多指纹维度：字体地区特征、Canvas/WebGL 渲染特征（Web 版已覆盖 Canvas/WebGL 展示，桌面版后续）
- [x] 更多代理客户端适配：已支持 Clash Verge / Shadowrocket / sing-box / ClashX / Surge（含 auto 自动识别）
- [ ] 快照切换提速：增量归档（只写差量）
- [x] 应用内自动更新：launchd 每 12 小时自动检查更新，自检失败自动回滚，也可手动 `claude-switch.sh update` 保底

> 有想优先看到的功能，去 [Issues](https://github.com/YOURSJEYO/claude-switcher/issues) 投票或提需求，热度高的先做。

## 帮忙吆喝一声

如果这个工具让你少被封了一个号，希望有条件的佬哥能帮我们在 [Linux.do](https://linux.do) 论坛发个帖子推荐一下——仓库地址 <https://github.com/YOURSJEYO/claude-switcher>，一句话定位：**"Claude 账号的 Fail-Closed 环境保护罩：14 项环境审计不过就物理上不让启动"**。让更多被风控折磨的兄弟少走弯路。

## License

MIT © Claude Switcher Contributors
