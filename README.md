<div align="center">

# 🚀 Hiveton H5000M 定制固件说明书

> **2026-09-18 起本仓库只编译一套产物**：`H5000M-WIFI-YES-MT5700-immortalwrt-master`。
> AP3000M / X86 的工作流、配置与专用脚本已删除；MT5700M 方案停用。
> 加速与稳定性优化的取舍（含未采纳项及理由）见
> [`FIRMWARE_OPTIMIZATION_REPORT.md`](FIRMWARE_OPTIMIZATION_REPORT.md)。

*基于 ImmortalWrt 主线源码，为 Hiveton H5000M 5G CPE（MT7987A + MT5700 5G 模组）提供的定制化编译配置*

</div>

<br>

## 🚀 快速开始（云编译）

本项目使用 GitHub Actions 自动编译固件，无需本地搭建环境。所有工作流位于 `.github/workflows/`：

| 工作流 | 触发方式 | 作用 |
| :--- | :--- | :--- |
| **Guard-Check** | push / PR / 手动 | **编译前的静态自检闸门**（跑 `Scripts/SelfCheck.sh` 的 C1~C10）。秒级反馈，且不占编译的 concurrency 组 |
| **WRT-BUILD** | 手动 `workflow_dispatch` | 手动编译 / 预览配置。机型与源码已收敛为单一选项，仅 **MT 模式**可选（`MT5700`，唯一在用的模式），默认完整编译并发布固件（`TEST=false`） |
| **H5000M-MT-AUTO** | 每天随 `Auto-Clean` 完成后自动触发，亦可手动 | 自动并行编译 H5000M 的 **MT5700** 单配置并发布 |
| **Auto-Clean** | 每天定时 + 手动 | 清理 Release 与 Workflow 运行记录。Release **默认全部清空**；手动触发时勾选 `keep_latest_per_device` 才改为「每个机型保留最新一个」。运行记录保留 30 天 |
| **Cache-Clean** | 仅手动触发 | 清理 GitHub Actions 编译缓存（已移除每周定时清空：那会让本周第一次构建必然冷启动，配额交由 GitHub 按 LRU 自动回收） |

**手动编译步骤：** 仓库页面 → `Actions` → 选择 `WRT-BUILD` → `Run workflow` → 选择机型与 MT 模式 → 直接运行即完整编译；只想校验配置时把 `TEST` 设为 `true`。

**说明：** `TEST=false`（默认）会完整编译并发布固件；`TEST=true` 只生成 `.config` 配置用于校验，不消耗编译资源。

**产物命名：** 文件名与 Release Tag 都嵌入 MT 模式标签，例如：

```text
…-MT5700-wifi-yes-26.09.13-….bin
Tag: H5000M-WIFI-YES-MT5700-…
```

Job 名为 `机型-MT模式`（如 `H5000M-WIFI-YES-MT5700`），在 Actions 页面可直接分辨。

> 早先这里还并列过 `…-MT5700M-wifi-yes-…bin` / `Tag: H5000M-WIFI-YES-MT5700M-…` 两个示例。
> MT5700M 方案已于 2026-09-18 停用，且 `ApplyMTMode.sh` / `VerifyMTMode.sh` 对它**直接报错终止**
> —— 该产物已不可能产生，示例留着只会让人以为还能选（2026-09-28 修正）。

<br>

## 📂 项目结构

```
OpenWRT-CI/
├── .github/workflows/        # 云编译工作流
│   ├── WRT-CORE.yml          # 公用编译核心（被调用）
│   ├── WRT-BUILD.yml         # 手动编译入口（机型 × MT 模式）
│   ├── H5000M-MT-AUTO.yml    # 自动编译 H5000M（MT5700）
│   ├── Auto-Clean.yml        # 清理旧 Release / 运行记录
│   └── Cache-Clean.yml       # 清理编译缓存
│   └── Guard-Check.yml       # 静态自检闸门（跑 Scripts/SelfCheck.sh，编译前先自查）
├── Config/                   # 编译配置（WRT-CORE 里的叠加顺序：机型 → GENERAL → PRIVATE）
│   ├── GENERAL.txt           # 通用插件与内核配置（不含 MT 插件；含 H5000M / mediatek 专属项，见文件内标注）
│   ├── MT5700.txt            # MT5700 独立插件层（方案 B）
│   ├── H5000M-WIFI-YES.txt   # Hiveton H5000M（带 Wi-Fi）
│   └── PRIVATE.txt           # 私有覆盖层：由 Settings.sh 最后写入 .config，可覆盖上面各层的同名项
├── Files/                    # 固件 files 覆盖层（随固件打包，首次开机生效）
│   ├── etc/
│   │   ├── uci-defaults/99-mt5700-net   # 网络调优（flow offload / TCP / 中断均衡 / 5G 无线）
│   │   ├── uci-defaults/99-mt5700-wan   # 补齐 MT5700M 接口、防火墙 wan 区、关 USB autosuspend
│   │   ├── uci-defaults/99-mt5700-sys   # zram 512M / 无线 isolate=0 / 国内 NTP
│   │   ├── uci-defaults/99-mt5700-stability  # 可用性兜底（rpcd 自愈等，不动网络策略）
│   │   ├── uci-defaults/99-h5000m-wifi-mac   # ★ Wi-Fi MAC 唯一化（全机型 BSSID 相同的修复，见第三节）
│   │   ├── uci-defaults/99-h5000m-wifi-scrub # ★ 清理厂家固件残留的无线私有键（assocresp_elements 等）
│   │   ├── sysctl.d/99-mt5700-tcp.conf  # BBR / fq / TFO / rp_filter=0
│   │   ├── sysctl.d/99-mt5700-conntrack.conf  # 连接跟踪容量（max 10 万）
│   │   ├── sysctl.d/99-mt5700-lan.conf  # proxy_arp_pvlan（MLO 跨射频互通）
│   │   ├── init.d/mt5700-rps            # 收包软中断多核分摊（RPS/XPS）
│   │   ├── init.d/mt5700-smp            # 硬中断亲和（能搬的按负载分到四核）
│   │   ├── init.d/apk-index-cache       # apk 索引缓存持久化（软件页重启后不必手动 Update lists）
│   │   ├── hotplug.d/net/30-mt5700-rps  # 后出现的接口补设 RPS/中断亲和（无线 + USB 网卡重枚举）
│   │   ├── nftables.d/12-mangle-ttl-128.nft  # WAN 出包 TTL/hoplimit 统一为 128
│   │   ├── mt5700/flow-offload          # flow offload 编译期选型（MODE=auto|off|on|on-hw，默认 off）
│   │   └── rc.local                     # ★ 停用内核温控，让 h5000m-fancontrol 独占风扇 pwm1（见第三节）
├── Scripts/                  # 编译前自定义脚本
│   ├── Packages.sh           # 拉取第三方插件与主题（含 MT 模式条件克隆/折叠）
│   ├── ApplyMTMode.sh        # 按 MT_MODE 叠加配置层并写入互斥保护
│   ├── VerifyMTMode.sh       # make defconfig 后校验 MT 包互斥
│   ├── ApplyFlowOffload.sh   # flow offload 选型写入固件覆盖层
│   ├── VerifyNoSingBox.sh    # 编译前后双断言 sing-box / homeproxy 未编入
│   ├── Handles.sh            # feeds 源码修补（主题配色 / 组件冲突 / 软件页安装行为）
│   └── Settings.sh           # 默认 IP / 主机名 / Wi-Fi / 主题
│   └── SelfCheck.sh          # 编译前静态自检（C1~C14，见 CHANGELOG 顶部清单）
├── LICENSE
└── README.md
```

<br>

## 🎯 支持的编译配置

| 配置 | 目标平台 | 设备 | Wi-Fi |
| :--- | :--- | :--- | :--- |
| `H5000M-WIFI-YES` | MediaTek Filogic | Hiveton H5000M | ✅ 开启 |

<br>

## ⚙️ 默认配置

固件刷入后默认配置如下（由 `Scripts/Settings.sh` 在编译时写入）：

- 想改 **SSID / 密码 / 管理地址 / 主机名 / 主题**：改 `WRT-CORE.yml` 里 `workflow_call.inputs` 的 `default`（一处改，手动编译与定时编译**同时生效**；两个调用工作流都不再重复这些值）。
- 想改 **Wi-Fi 频宽 / 加密 / 国家码**：改 `Scripts/Settings.sh`。

| 项目 | 默认值 |
| :--- | :--- |
| Wi-Fi SSID（2.4G / 5G） | `OWRT` |
| Wi-Fi 密码 | `12345678` |
| 加密方式 | WPA-PSK / WPA2-PSK Mixed Mode |
| 管理地址 | `192.168.10.1` |
| 主机名 | `OWRT` |
| 国家码 | `CN` |
| 2.4G 频宽 | 40MHz |
| 5G 频宽 | 目标 `EHT160`，但**这条链路不可靠** —— 见下方「5G 频宽现状」 |
| Flow Offload | `off`（**默认关**；刷机后可在「网络 → 防火墙 → 常规设置」或 uci 改） |
| 时区 | `CST-8`（`Asia/Shanghai`） |

> **5G 频宽现状（2026-09-28）**
>
> 目标是 `EHT160`，但**没有任何一条路径能保证这个结果**；而且本机真机读数**不能作为证据** ——
> 那台设备的 Wi-Fi 被手工改过（`ssid` 不是默认的 `OWRT`，`encryption` 是 `sae-mixed`
> 而不是脚本会设的 `psk-mixed`），所以它显示的 `HE160` + `channel=auto`
> **反映的是用户的选择，不是编译产物的状态**。已定位的三条路径：
>
> 1. `Scripts/Settings.sh` 的 `$WIFI_SH` 分支（设 `EHT160`，还配了一条守卫告警）——**该分支永不执行**：
>    upstream 的 `target/linux/mediatek/filogic/base-files/etc/uci-defaults/` 下已无 `*set-wireless.sh`
>    （只剩 `05_fix-compat-version`），`find` 返回空 → 走 `elif` 的 `mac80211.uc` 分支；
> 2. `Settings.sh` 的 uc 分支 —— 那两条改频宽的 `sed` 是**注释掉的**，理由是「5G 保持 80MHz 上限」。
>    该理由**与上游行为一致**：`mac80211.uc` 里 `if (width > 80) width = 80;` 会把生成的 htmode
>    后缀钉成 80。也就是说**编译产物的 5G 更可能是 `EHT80`/`HE80`，而不是 `EHT160`**；
> 3. `Files/etc/uci-defaults/99-mt5700-net` 第 5b 节（设 `channel=36` + `EHT160`）——该脚本确已执行
>    （`/etc/uci-defaults/` 已被消费、同批次的 rpcd respawn 改动在真机上生效），但**无法从当前真机
>    状态判断它有没有被后续覆盖**，因为用户的手工改动同样会覆盖它。
>
> **结论**：上表写 `EHT160` 是**意图**，不是已验证的事实。要确定实际频宽，需刷一台**未被手工改过**
> 的固件再看；要真正把 5G 钉在某个频宽上，唯一有效的位置是 `Settings.sh` 的 uc 分支
> （能影响 `mac80211.uc` 的输出），而频宽改动触及 DFS，必须在真机带自动回滚验证后再合。

> **Flow Offload 说明**（本固件最易被误解的开关，与 SQM/CAKE 互斥）：
> 1. 四个取值通过 `WRT-BUILD` 手动页的 `FLOW_OFFLOAD` 选择（`auto` / `off` / `on` / `on-hw`），**默认 `off`**；定时自动编译（`H5000M-MT-AUTO`）同样取 `off`。
> 2. `auto` 模式先查 SQM 是否启用：启用则关；未启用则**再查固件是否带 TTL 统一规则**（`/etc/nftables.d/*.nft` 含 `ip ttl set`）—— 带就一律关。本固件自带该规则，所以 **`auto` 在这台机器上等价于 `off`**。
> 3. 为什么默认宁可不开：offload 把连接从 nftables 路径上摘走，TTL 规则对快转包零命中，运营商按「多设备共享」丢弃客户端 TCP 包。真机实测（kernel 6.18.52）：卸载开 → 客户端 HTTP 25s 超时、conntrack 带 `[OFFLOAD]`；卸载关 → 同一请求 HTTP 200 / 1.0s，出口抓到 TTL=128。
> 4. `on-hw`（硬件卸载）在本机命中率≈0：本基线无 `mtk_wed`（WiFi 侧硬件转发缺失），且 5G WAN 是 USB CDC-NCM（PPE 管不到 USB 口），开了只会让 nft 计数器看不到流量。

<br>

## 💖 鸣谢与致敬

本固件的高效自动化编译、底层系统的稳定性以及对特定 5G 模组的完美适配，离不开开源社区开发者的无私奉献。在此特别感谢以下作者及其开源项目：

> **🐧 源码上游：[ImmortalWrt](https://github.com/immortalwrt/immortalwrt/)**
>
> 感谢 ImmortalWrt 团队提供的最新主线源码。其卓越的路由性能和丰富的本地化特性，为固件的开发提供了无比坚实的底层源码基础。
> * 🔗 **项目链接**：[immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt/)

> **👤 基础底包、插件优化与编译框架：[VIKINGYFY](https://github.com/VIKINGYFY)**
>
> 感谢作者提供的 OpenWRT-CI 项目。作者不仅打造了高效的云端自动化编译框架，更为本项目提供了稳定可靠的**基础底包固件配置**、**深度的插件细节优化**，以及**大量优质实用的额外插件支持**，极大降低了固件定制门槛并全面提升了路由器的整体体验和可玩性。
> * 🔗 **项目链接**：[OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)

> **👤 CPE 核心插件支持：[FAN789](https://github.com/FAN789)**
>
> 感谢作者为 Hiveton H5000M 及 MT5700M 模组开发的系列核心控制插件，赋予了该设备真正的 5G CPE 灵魂。
> * 🔗 **主页链接**：[https://github.com/FAN789](https://github.com/FAN789)
> * 📦 **5G 模组控制**：[luci-app-mt5700m](https://github.com/LianXia233/luci-app-mt5700m)
> * ❄️ **智能风扇温控**：[luci-app-h5000m-fancontrol](https://github.com/FAN789/luci-app-h5000m-fancontrol)（本固件编的是[其 fork](https://github.com/woshinibabao1/luci-app-h5000m-fancontrol)，仅补上 5G 模组取温，见第二节）
> * 🔀 **网络模式切换**：[luci-app-h5000m-netmode](https://github.com/FAN789/luci-app-h5000m-netmode)（本固件编的是[其 fork](https://github.com/woshinibabao1/luci-app-h5000m-netmode)，同源的性能与缺陷修复，包名与接口不变，见第二节）

---

## 📡 一、 硬件平台与固件底层概述

**Hiveton H5000M** 是一款高性能的 5G CPE（Customer Premises Equipment）路由器，致力于将高速的 5G 移动网络转化为稳定可靠的局域网 Wi-Fi 或有线网络。

| 核心特征 | 详情描述 |
| :--- | :--- |
| 🏗️ **固件底包** | **基于 ImmortalWrt 主线最新源码构建**。内核层面已开启硬件加解密优化（`kmod-cryptodev`, `kmod-tls`），为科学分流和安全组网提供底层加速。 |
| 🖥️ **基础架构** | 采用 **联发科 (MediaTek) Filogic** 平台（本设备为 **MT7987A**，四核 Cortex-A53 + MT7992 无线），具备网络数据转发与 Wi-Fi 7 能力。 |
| 📶 **核心模组** | 深度集成 **MT5700 5G 模组**，支持直接插卡上网，实现 5G 高速蜂窝接入。 |
| ❄️ **散热设计** | 针对 5G 模组高负载下的发热特性，设备配备了**主动散热风扇**，专为高负载网络转化设计，确保极限性能下不降频。 |

---

## 🧩 二、 核心专属插件详解

固件包含网络模式切换与 MT5700 模组控制等全设备通用插件；风扇温控仅编入 H5000M 固件。以下是三大核心插件的功能说明：

### 1. MT5700 5G 模组支持 (`luci-app-mt5700`)
MT5700 是本台 CPE 的数据吞吐核心，由 `luci-app-mt5700`（方案 B，单包自含 Rust 后端 `at-webserver-rust`）提供系统级驱动支持与图形化管理界面 (LuCI)。

* **📊 状态监控**：在后台实时呈现 5G 信号强度、SA/NSA 网络制式、当前频段、运营商及 IMEI/IMSI 等关键状态。
* **🔌 连接管理**：兼容 QMI/NCM 等多种拨号协议，实现高速稳定的蜂窝联网。
* **⚙️ AT 指令交互**：内置 AT 通道与 Web 终端，支持通过界面向模组发送 AT 指令，便于高级调试或频段锁定。
* **✉️ 短信功能**：通过界面接收与发送运营商短信，方便接收流量提醒。

> 注：MT5700（方案 B）是**单包自含**的，不安装 `sms-tool_q` / `ubus-at-daemon`
> （CI 里对这两个包显式置 `=n` 并做互斥校验），短信与 AT 能力由它自己的后端提供。
> 旧方案 `luci-app-mt5700m` 已停用（依赖 `sms-tool_q` 版本号对 apk 非法，且功能重复）。

### 2. 硬件级风扇温控 (`luci-app-h5000m-fancontrol`)
仅 Hiveton H5000M 固件包含此插件。5G 高速传输伴随显著发热，该插件确保设备在满负荷运作下的温控稳定。

* **🌡️ 智能监测**：实时读取 CPU、以太网 PHY、Wi-Fi 射频与 MT5700 模组的温度。
* **🌀 多档调速**：根据设定的温度阈值（如阈值 A、B、C），自动调节风扇的 PWM 转速百分比，兼顾低负载静音与高负载散热。
* **🛠️ 自定义配置**：用户可自由调整启动温度、目标温度，打造个性化的散热策略。

> **关于 5G 模组取温（本固件用的是 fork）**：上游版本读 `/var/run/mt5700m/temperature`
> （别的模组管理软件生成的缓存），本机没有这个文件 —— 模组温度实际上从未参与过取热。
> 因此本固件改用 [woshinibabao1/luci-app-h5000m-fancontrol](https://github.com/woshinibabao1/luci-app-h5000m-fancontrol)
> （基于上游 v2.1.0，包名与配置符号不变）：新增经 `ubus call mt5700 at '{"cmd":"AT^CHIPTEMP?"}'`
> 向 **MT5700 Console 的 Rust 后端**取温的通道（只读，默认 30 秒一次），取到后按上游格式回写缓存。
> 没有该后端时自动退回旧缓存，不会报错。

### 3. 网络模式无缝切换 (`luci-app-h5000m-netmode`)
所有配置均包含此插件，用于应对复杂的网络接入环境（5G 蜂窝与传统有线宽带双接入），提供极简的管理体验。

> **关于本固件用的 fork（2026-09-30 换源）**：上游 FAN789 原版停在 v1.3.1-r2，本固件改用
> [woshinibabao1/luci-app-h5000m-netmode](https://github.com/woshinibabao1/luci-app-h5000m-netmode)
> —— 它是上游 `main` 的**直接后代**（只多 3 个提交，v1.3.4-r1），包名、Config 符号、安装路径与
> UCI 配置结构全部不变，也没有新增任何依赖；ACL 只做了收紧（去掉视图用不到的 uci 授权）。
> 换源换来的是运行开销与缺陷修复：真机上一次状态查询从 **54 个外部进程 / 约 156 ms** 降到
> **11 个 / 约 83 ms**（LuCI 每 5 秒轮询一次状态，而 rpcd 是单线程的），并修掉
> 「没有模组 IPv6 别名段时把 `usbv6_defaultroute`/`usbv6_auto` 谎报成 1」、
> 「抢锁用 `rm -rf` + `mkdir`，两个实例可能互相删锁」等问题。
> 回退方式：把 `Scripts/Packages.sh` 里该行的 repo 改回 `FAN789/...` 即可。

### 4. MT 插件模式（MT_MODE）

固件构建支持独立的 5G 模组插件配置层，当前仅 H5000M 一套产物，唯一在用的模式是 `MT5700`（`WRT-BUILD` 的 `MT_MODE` 选项仅 `MT5700`）：

| MT_MODE | 安装内容 | 状态 |
| :--- | :--- | :--- |
| `MT5700` | `luci-app-mt5700`（单包自含 Rust 后端） | ✅ 现役（默认） |
| `MT5700M` | `luci-app-mt5700m` + `sms-tool_q` + `ubus-at-daemon` | ⛔ 已停用（依赖 sms-tool_q 版本号对 apk 非法，且功能与 MT5700 重复） |

自动编译（`H5000M-MT-AUTO`）只编译 `MT5700` 单配置；产物文件名、配置导出与 Release Tag 均嵌入 MT 模式标签。

配置层文件：

* `Config/MT5700.txt`（方案 B，唯一在用的 MT 插件层）

> ⚠️ **没有 `Config/MT5700M.txt`，这是有意的，别补回来。** MT5700M 分支保留在
> `ApplyMTMode.sh` / `VerifyMTMode.sh` 里作为 **fail-fast 守卫**：万一有人手滑把
> `MT_MODE` 填成 `MT5700M`，会在配置生成前就明确报错终止，而不是静默编出一套
> **从未真机验证**的固件。删掉这个配置文件正是让守卫生效的手段 ——
> 2026-09-21 曾把它当成"缺文件的 bug"补回一次，结果是把安全网拆了，2026-09-22 已还原。

互斥由 CI 在**配置生成前**（`Scripts/ApplyMTMode.sh`）与**配置生成后、编译前**（`Scripts/VerifyMTMode.sh`）双重校验，冲突时直接失败。

* **🔄 一键切换**：支持在“仅 5G 模式”、“仅有线宽带模式”及“负载均衡/故障转移模式”间快速切换，告别复杂的接口配置。
* ~~**⚡ 链路检测**：搭配 mwan3，实时监测链路连通状态，主链路故障时实现毫秒级无缝切换，确保网络永不掉线。~~
  > ⚠️ **2026-09-28 更正：本固件没有编入 mwan3。** `Config/*.txt` 与 `Scripts/Packages.sh`
  > 里都搜不到它（`luci-app-h5000m-netmode` 的 `LUCI_DEPENDS` 只有 `+luci-base`，不会把它带进来），
  > 真机上也既无 `mwan3` 命令、也无 `/etc/init.d/mwan3`。所以「毫秒级无缝切换 / 确保网络永不掉线」
  > 是**没有实现的宣称**，已划掉。链路优先级切换由 `luci-app-h5000m-netmode` 提供，
  > 但**不含** mwan3 的链路健康探测与故障转移。确实需要的话得自己加
  > `CONFIG_PACKAGE_mwan3=y` + `CONFIG_PACKAGE_luci-app-mwan3=y` 重编。

---

## 🛠️ 三、 固件底层组件与扩展支持

得益于 ImmortalWrt 优秀的底包基础，Hiveton H5000M 不仅具备卓越的基础路由性能，还将扩展性推向极致：

* **内核级加解密加速**：开启 `kmod-cryptodev` 与 `kmod-tls`，大幅提升加密隧道（WireGuard、HTTPS 等）的吞吐量，降低 CPU 占用。
  > **EIP-197 的溯源（2026-09-28 更正）**：`kmod-crypto-hw-safexcel` 由 `Config/GENERAL.txt`
  > 的 `CONFIG_PACKAGE_kmod-crypto-hw-safexcel=y` 选中；其固件 `eip197-mini-firmware`
  > 是**靠该包的 `+DEPENDS` 自动带入**的，本仓并未显式声明它
  > （原先这里写成「已就位」，还指向 `H5000M-WIFI-YES.txt` —— 那个文件里其实没有这个符号）。
  > ⚠️ 真机核对：`/lib/firmware/` 下**未见** eip197 固件，该引擎在本机是否真的启用**未经验证**；
  > 需要时以真机 `dmesg | grep -i safexcel` 为准。
* **USB 驱动栈扩展**：包含 `kmod-usb-core`, `kmod-usb3` 及 `kmod-usb-net-qmi-wwan` 等丰富驱动，确保系统准确识别各类移动通信模组。
* **轻量级 NAS 存储**：支持 NVMe 固态硬盘（`kmod-nvme`）挂载，结合 BTRFS 文件系统，轻松打造家庭数据中心。
* **安全异地组网**：内置 WireGuard（`kmod-wireguard` + `luci-proto-relay`），轻松实现内网设备的远程安全访问。
* **Wi-Fi MAC 唯一化（2026-09-30 修复；这是"全机型 BSSID 相同"的真缺陷）**：
  `Files/etc/uci-defaults/99-h5000m-wifi-mac` 按 eMMC CID 派生本机唯一 MAC，写进
  `wireless.<iface>.macaddr`。
  > **缺陷与取证（真机 192.168.10.1）**：`factory` 分区（`/dev/mmcblk0p2`）**整块全零** →
  > mt76 每次开机走内置默认 eeprom（`eeprom tx_power zeros detected, using defaults` /
  > `eeprom load fail, use default bin`），而那份文件里写死了 MediaTek 的**样例 MAC**
  > （`MT_EE_MAC_ADDR=00:0c:43:26:60:10` / `MAC_ADDR2=…:11`），mt76 按频段从 eeprom 取
  > **接口** MAC：
  > - 上游 `11_fix_wifi_mac` 的 `hiveton,h5000m` 分支**确实生效**了，但它只改 **phy 级**地址
  >   （实测 `/sys/class/ieee80211/phy0/macaddress` = CID 派生的 `56:9d:93:7b:f5:a5`）；
  > - AP 接口仍是 eeprom 里那对固定值（实测 `iw dev`：`phy0.1-ap0` = `00:0c:43:26:60:11`）。
  >
  > ⇒ **所有刷本固件的 H5000M，2.4G/5G 的 BSSID 都是同一对地址**，同网段两台机器直接冲突。
  > 修法走 OpenWrt 官方路径（`/usr/share/ucode/wifi/ap.uc` 会把 `macaddr` 作为 hostapd 的
  > `bssid=`）；取值沿用 immortalwrt 既有约定（同一颗 phy：radio0 = CID+2、radio1 = CID+3，
  > 地址占用表写在脚本注释里）。刷机后验证：`ubus call network.wireless status | grep bssid`
  > 应显示 `56:9d:…` 段，而不再是 `00:0c:43:…`。
  > `SelfCheck.sh` 的 **C13** 钉三条红线：必须 CID 派生、已有值不覆盖、取不到 CID 必须 `exit 1`。
* **厂家固件残留清理**：`Files/etc/uci-defaults/99-h5000m-wifi-scrub`。
  > sysupgrade 会保留 `/etc/config/wireless`，从厂家固件（mt_wifi7 / qmodem 那套）刷过来时
  > 会带一批 mt76/mac80211 **不认识**的私有键：`assocresp_elements`（残留会导致客户端
  > "关联成功但 BA 协商全超时"）、`tx_burst` / `pp_mode` / `pp_bitmap`，以及非 `mac80211`
  > 的 `type`。依据是 v024 固件自己的升级清理脚本（`99-h5000m-clean-defaults` 里逐个 delete
  > 的就是这些键）。本仓只**删私有键 + 修正 type**，绝不重建 wireless、不动 SSID/密码/信道
  > （C13 把这条写成红线）。幂等：没东西可改就不 commit。
* **Wi-Fi 射频校准：审计结论是「不固化」**（2026-09-30）
  > 上面那个"factory 全零"的根因一度让人想把厂家固件的 eeprom 固化进本仓，**逐字节复核后放弃**：
  > ① 本机实际加载的那一槽（`mt7992_eeprom_23_2i5i.bin`）与 mt76 自带默认文件**只差 3 个字节**
  > （2 个是 MAC 字段、1 个落在 mt76 不解析的区域）→ **收益为 0**；② 固化会连带把 Wi-Fi MAC
  > 钉成文件里的值（厂家固件里那份真品带的是 `00:0c:8c` 段）→ 与上面的 MAC 修复相互冲突；
  > ③ "上游改名丢校准"的动机也不成立：mt76 的默认 eeprom 与其驱动**同仓库同版本发布**
  > （`package/kernel/mt76` 从 `$(PKG_BUILD_DIR)/firmware/` 安装）。
  > 详细取证与逐字节对照见 `CHANGELOG.md` 的 2026-09-30 条目。`SelfCheck.sh` 的 **C12** 因此
  > 改为**条件式**：目录在就校验格式（大小 7680 / CHIP_ID 0x7992 / FEM 槽位 / `*.bin binary`），
  > 不在就明确 skip 并打印这条结论 —— 而不是静默通过。
* **USB 网卡重枚举后补设 RPS 与中断亲和**：`Files/etc/hotplug.d/net/30-mt5700-rps`（2026-09-30 扩）
  > 原先只对无线接口名触发。5G 模组重插/复位后 netdev 是**销毁重建**的：新接收队列的
  > `rps_cpus` 回到内核默认 0（net-sysfs 里 rps_map 初始为空），而 `init.d/mt5700-rps` 只在
  > S95 跑一次 → 之后一路没有 RPS，直到重启；USB 侧中断号也会重新分配，`mt5700-smp` 在 S99
  > 的成果同样失效。现按「设备挂在 USB 总线上」判定（不写死 eth2），补跑 `mt5700-rps start`
  > 与 `mt5700-smp restart`（均幂等）。

> ⚠️ 本清单列出的是**显式选中**（`Config/*.txt` 里写了 `CONFIG_PACKAGE_*=y`）的包：
> `Scripts/Packages.sh` 里克隆了但没写 `=y` 的包**不会**因为克隆而进固件，别把它们算作固件能力。
> 但反过来不成立 —— 被这些包 `+DEPENDS` 拉进来的**传递依赖**照样会编进镜像
> （例：`luci-app-partexp` 声明了 `+parted +btrfs-progs +e2fsprogs +f2fs-tools +kmod-loop` 等，
> 它们不在任何 Config 里，却会随包一起进来）。要判断「固件里到底有什么」，
> 以真机 `apk list -I` / `opkg list-installed` 为准（2026-09-28 补注）。

<br>

## 🧪 四、 稳定性体检（2026-09-30 真机实测，192.168.10.1）

> 判断标准只有一条：**会不会掉线 / 抖动 / 复位 / 丢配置**。下面每条都来自真机读数，不是推断；
> 写成文档的目的是**避免以后重复调研同一条**（本项目已经为 WED、mtk-puncture 等做过这种记录）。

### 4.1 已经就位的兜底（正面结论，别再去加）

| 机制 | 真机证据 | 意味着 |
| :-- | :-- | :-- |
| 硬件看门狗 | `mtk-wdt 1001c000.watchdog: Watchdog enabled (timeout=31 sec, nowayout=0)`，`/dev/watchdog0` 存在 | 系统挂死 31 秒会硬复位 |
| 内核崩溃自动恢复 | `kernel.panic=3`、`kernel.panic_on_oops=1` | oops 即 panic，3 秒后自动重启 —— 不会停在半死状态 |
| 崩溃现场留存 | `ramoops` 已注册、`/sys/fs/pstore/` 存在；**当前 0 个转储** | 真发生内核崩溃时重启后能查到现场；现在为空 = 这段时间没崩过 |
| 内存与交换 | `available 734MB`、zram 512M **`Used=0`**、`oom_kill=0` | 没有内存压力；zram 是纯兜底（未用到） |
| 闪存寿命 | eMMC `life_time=0x01`（<10%）、`pre_eol_info=0x01`（正常）、`/overlay` 用 3% | 无磨损担忧 |
| 掉电保护 | `/etc/init.d/umount` 含 `sync`、f2fs 挂 `lazytime,noatime,checkpoint_merge,fsync_mode=posix` | 正常关机路径会把数据落盘；异常掉电后 f2fs 能自恢复（开机日志有 `f2fs_recover_fsync_data`，说明确实发生过非正常关机） |
| 中断负载 | 无线 IRQ 79 ≈ **144 次/秒**、USB IRQ 74 ≈ 15 次/秒、`NET_RX` ≈ 41 次/秒 | 量级极低，4 核 A53 毫无压力 |

### 4.2 已知限制（**不是缺陷，别再花时间**）

| 现象 | 结论 |
| :-- | :-- |
| 无线 IRQ 79 的 `smp_affinity` 改不动（RC=1，5.6M 次中断 100% 落在 CPU0） | MTK PCI-MSI 单向量不支持亲和设置；且按上面量级**根本不需要迁**。文档原先把它列为待优化项，现撤销 |
| `eth2`（USB 网卡）/`phy0.1-ap0`/`br-lan` 的 `xps_cpus` 写入失败 | 这些设备**不支持 XPS**（实测写入直接失败），不是"漏设"。`eth0`/`eth1` 可写且已是 `f` |
| 没有 u-boot 环境分区内容 → `bootcount` 空跑、无自动回滚 | `p1`（512KB，PARTLABEL=u-boot-env）**前 64 字节全零、`strings` 无任何变量**，且 `/etc/fw_env.config` 不存在 → `fw_printenv/fw_setenv` 虽在但不可用。**刷坏的恢复途径只有 U-Boot 的 web recovery（eMMC 里的更U-Boot）或串口** —— 刷机前务必留一条退路 |
| `ubihealthd` 在 eMMC 机型空跑 | 无 MTD/UBI（`/proc/mtd` 为空、`lsmod` 无 ubi），启动即退出，收益≈0，**不动** |
| `radius`/`relayd`/`usbmuxd`/`sqm`/`autoreboot` 等服务 enabled | 逐个查过：`radius.disabled=1`、`sqm.*.enabled=0`、`autoreboot` 计划 `enabled=0`、`relayd` 无配置、`usbmuxd` 无 iOS 设备 —— 都**不生效或无对象**，为微小资源收益去动它们不划算，**保持现状** |

### 4.3 唯一确定该改的一条（已改）：NTP 源里有被 DNS 反绑定保护拦掉的域名

```
真机 nslookup cn.ntp.org.cn 223.5.5.5 →
    Address: 111.203.6.13      ← 公网
    Address: 10.48.49.44       ← 10/8 私网地址
后果：每几分钟一条 daemon.warn dnsmasq: possible DNS-rebind attack detected: cn.ntp.org.cn
     且 ntpd 对该源解析失败（另外三个源正常，设备时间实测准确）
```
`Files/etc/uci-defaults/99-mt5700-sys` 已把该域名从 NTP 列表删除（**不**用 `rebind_domain` 白名单 ——
那会整域放行、削弱反绑定保护；而这条 warn 本身是要当安全信号看的，不能被噪声淹没）。

### 4.4 设备侧（不属于本仓库，但会影响"稳不稳"的观感）

1. **DNS 上游链路**：真机是 `客户端 → dnsmasq(53) → AdGuardHome(127.0.0.1#53335) → 上游`，
   而 AdGuardHome 日志里 `119.29.29.29:53 over udp ... i/o timeout` **每次超时 20 秒**。
   缓存命中的域名没事（`min_cache_ttl=3600` + `use_stale_cache=3600` 正好掩盖了它），
   但**新域名的首次解析会卡很久**，观感就是"有些网站打不开/很慢"。
   建议（属 AdGuardHome 自己的配置，不在本仓）：上游换成 `223.5.5.5` 或 DoH/DoT、
   给多个上游并缩短超时；或让 dnsmasq 直连运营商 DNS。
   ★ 顺带结论：本仓把 `min_cache_ttl` 设成 3600 是**有意为之且现在看是对的** —— 它掩盖了上游抖动；
   代价是域名变更/运营商跳转页会滞后（v024 用 60，那是拿抖动换新鲜度，两者取舍不同）。
2. **LAN IPv6 一直在"自我撤销"**：`odhcpd: No default route present, setting ra_lifetime to 0!`
   每几分钟一条 —— 因为 5G 出口没有 IPv6 默认路由（`ip -6 route show default` 为空），
   odhcpd 只能把 RA 的默认路由寿命归零，客户端侧 IPv6 因此反复失效。
   两条路选一条（**属功能取舍，本仓不擅自改**）：
   - 不用 IPv6 → `uci set dhcp.lan.ra='disabled'; uci set dhcp.lan.ndp='disabled'; uci delete network.lan.ip6assign; uci commit`，抖动消失；
   - 要用 IPv6 → 保持现状，或用 `ra_default='1'`（**不推荐**：那会让客户端把 IPv6 流量丢给一个没有 IPv6 出口的路由器）。
3. **`network.wwan` 是个没有 device 的 dhcp 接口**（`uci show network.wwan`），疑似厂家固件残留；
   它不会导致掉线，但每次 reload 都会被尝试。确认不用可 `uci delete network.wwan && uci commit network`。

<br>

> 📅 *文档更新日期：2026年9月*
> 💡 *本说明文档由项目编译配置与社区开源信息整合生成。*
