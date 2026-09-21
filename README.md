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
| **WRT-BUILD** | 手动 `workflow_dispatch` | 手动编译 / 预览配置。可选机型、源码、MT 模式（`MT5700`，唯一在用的模式），默认完整编译并发布固件（`TEST=false`） |
| **H5000M-MT-AUTO** | 每天随 `Auto-Clean` 完成后自动触发，亦可手动 | 自动并行编译 H5000M 的 **MT5700** 单配置并发布 |
| **Auto-Clean** | 每天定时 + 手动 | 清理 Release 与 Workflow 运行记录。Release **默认全部清空**；手动触发时勾选 `keep_latest_per_device` 才改为「每个机型保留最新一个」。运行记录保留 30 天 |
| **Cache-Clean** | 仅手动触发 | 清理 GitHub Actions 编译缓存（已移除每周定时清空：那会让本周第一次构建必然冷启动，配额交由 GitHub 按 LRU 自动回收） |

**手动编译步骤：** 仓库页面 → `Actions` → 选择 `WRT-BUILD` → `Run workflow` → 选择机型与 MT 模式 → 直接运行即完整编译；只想校验配置时把 `TEST` 设为 `true`。

**说明：** `TEST=false`（默认）会完整编译并发布固件；`TEST=true` 只生成 `.config` 配置用于校验，不消耗编译资源。

**产物区分：** 同一机型的两种 MT 配置产物在文件名与 Release Tag 中均嵌入模式标签，例如：

```text
…-MT5700-wifi-yes-26.09.13-….bin
…-MT5700M-wifi-yes-26.09.13-….bin
Tag: H5000M-WIFI-YES-MT5700-…
Tag: H5000M-WIFI-YES-MT5700M-…
```

双配置 Job 名为 `机型-MT模式`（如 `H5000M-WIFI-YES-MT5700`），在 Actions 页面可直接分辨。

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
├── Config/                   # 编译配置
│   ├── GENERAL.txt           # 全设备通用插件与内核配置（不含 MT 插件）
│   ├── MT5700.txt            # MT5700 独立插件层（方案 B）
│   └── H5000M-WIFI-YES.txt   # Hiveton H5000M（带 Wi-Fi）
├── Files/                    # 固件 files 覆盖层（随固件打包，首次开机生效）
│   └── etc/
│       ├── uci-defaults/99-mt5700-net   # 网络调优（flow offload / TCP / 中断均衡 / 5G 无线）
│       ├── uci-defaults/99-mt5700-wan   # 补齐 MT5700M 接口、防火墙 wan 区、关 USB autosuspend
│       ├── uci-defaults/99-mt5700-sys   # zram 512M / 无线 isolate=0 / 国内 NTP
│       ├── sysctl.d/99-mt5700-tcp.conf  # BBR / fq_codel / TFO / rp_filter=0
│       ├── sysctl.d/99-mt5700-lan.conf  # proxy_arp_pvlan（MLO 跨射频互通）
│       ├── nftables.d/12-mangle-ttl-128.nft  # WAN 出包 TTL/hoplimit 统一为 128
│       └── mt5700/flow-offload          # flow offload 编译期选型（MODE=auto|off|on|on-hw）
├── Scripts/                  # 编译前自定义脚本
│   ├── Packages.sh           # 拉取第三方插件与主题（含 MT 模式条件克隆/折叠）
│   ├── ApplyMTMode.sh        # 按 MT_MODE 叠加配置层并写入互斥保护
│   ├── VerifyMTMode.sh       # make defconfig 后校验 MT 包互斥
│   ├── ApplyFlowOffload.sh   # flow offload 选型写入固件覆盖层
│   ├── VerifyNoSingBox.sh    # 编译前后双断言 sing-box / homeproxy 未编入
│   ├── Handles.sh            # feeds 源码修补（主题配色 / 组件冲突 / 软件页安装行为）
│   └── Settings.sh           # 默认 IP / 主机名 / Wi-Fi / 主题
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

固件刷入后默认配置如下（可通过各工作流 `env` 中的 `WRT_*` 变量调整，由 `Scripts/Settings.sh` 在编译时写入）：

| 项目 | 默认值 |
| :--- | :--- |
| Wi-Fi SSID（2.4G / 5G） | `OWRT` |
| Wi-Fi 密码 | `12345678` |
| 加密方式 | WPA-PSK / WPA2-PSK Mixed Mode |
| 管理地址 | `192.168.10.1` |
| 主机名 | `OWRT` |
| 国家码 | `CN` |
| 2.4G 频宽 | 40MHz |
| 5G 频宽 | 80MHz (HE80) |
| Flow Offload | `auto`（SQM 未启用时开软件卸载；刷机后可在「网络 → 防火墙 → 常规设置」或 uci 改） |
| 时区 | `CST-8`（`Asia/Shanghai`） |

> **Flow Offload 说明**（本固件最易被误解的开关，与 SQM/CAKE 互斥）：
> 1. 四个取值通过 `WRT-BUILD` 手动页的 `FLOW_OFFLOAD` 选择（`auto` / `off` / `on` / `on-hw`），默认 `auto`；定时自动编译（`H5000M-MT-AUTO`）取默认 `auto`。
> 2. `auto` 模式先查 SQM 是否启用：启用则关、未启用则开软件卸载，二者只能二选一（被卸载的连接绕过 qdisc，CAKE/HTB 会失效）。
> 3. `on-hw`（硬件卸载）在本机命中率≈0：本基线无 `mtk_wed`（WiFi 侧硬件转发缺失），且 5G WAN 是 USB CDC-NCM（PPE 管不到 USB 口），开了只会让 nft 计数器看不到流量。

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
> * ❄️ **智能风扇温控**：[luci-app-h5000m-fancontrol](https://github.com/FAN789/luci-app-h5000m-fancontrol)
> * 🔀 **网络模式切换**：[luci-app-h5000m-netmode](https://github.com/LianXia233/luci-app-h5000m-netmode)

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

* **🌡️ 智能监测**：实时读取 CPU 和 MT5700 模组的双路温度传感器数据。
* **🌀 多档调速**：根据设定的温度阈值（如阈值 A、B、C），自动调节风扇的 PWM 转速百分比，兼顾低负载静音与高负载散热。
* **🛠️ 自定义配置**：用户可自由调整启动温度、目标温度，打造个性化的散热策略。

### 3. 网络模式无缝切换 (`luci-app-h5000m-netmode`)
所有配置均包含此插件，用于应对复杂的网络接入环境（5G 蜂窝与传统有线宽带双接入），提供极简的管理体验。

### 4. MT 插件模式（MT_MODE）

固件构建支持独立的 5G 模组插件配置层，当前仅 H5000M 一套产物，唯一在用的模式是 `MT5700`（`WRT-BUILD` 的 `MT_MODE` 选项仅 `MT5700`）：

| MT_MODE | 安装内容 | 状态 |
| :--- | :--- | :--- |
| `MT5700` | `luci-app-mt5700`（单包自含 Rust 后端） | ✅ 现役（默认） |
| `MT5700M` | `luci-app-mt5700m` + `sms-tool_q` + `ubus-at-daemon` | ⛔ 已停用（依赖 sms-tool_q 版本号对 apk 非法，且功能与 MT5700 重复） |

自动编译（`H5000M-MT-AUTO`）只编译 `MT5700` 单配置；产物文件名、配置导出与 Release Tag 均嵌入 MT 模式标签。

配置层文件：

* `Config/MT5700.txt`（方案 B，唯一在用的 MT 插件层）

互斥由 CI 在**配置生成前**（`Scripts/ApplyMTMode.sh`）与**配置生成后、编译前**（`Scripts/VerifyMTMode.sh`）双重校验，冲突时直接失败。

* **🔄 一键切换**：支持在“仅 5G 模式”、“仅有线宽带模式”及“负载均衡/故障转移模式”间快速切换，告别复杂的接口配置。
* **⚡ 链路检测**：搭配 mwan3，实时监测链路连通状态，主链路故障时实现毫秒级无缝切换，确保网络永不掉线。

---

## 🛠️ 三、 固件底层组件与扩展支持

得益于 ImmortalWrt 优秀的底包基础，Hiveton H5000M 不仅具备卓越的基础路由性能，还将扩展性推向极致：

* **内核级加解密加速**：开启 `kmod-cryptodev` 与 `kmod-tls`，大幅提升代理工具（如 OpenClash）和加密隧道的吞吐量，降低 CPU 占用。
* **USB 驱动栈扩展**：包含 `kmod-usb-core`, `kmod-usb3` 及 `kmod-usb-net-qmi-wwan` 等丰富驱动，确保系统准确识别各类移动通信模组。
* **轻量级 NAS 存储**：支持 NVMe 固态硬盘（`kmod-nvme`）挂载，结合 BTRFS 文件系统，轻松打造家庭数据中心。
* **安全异地组网**：内置 Tailscale 等主流 SD-WAN 工具，轻松实现内网设备的远程安全访问。

<br>

> 📅 *文档更新日期：2026年9月*
> 💡 *本说明文档由项目编译配置与社区开源信息整合生成。*
