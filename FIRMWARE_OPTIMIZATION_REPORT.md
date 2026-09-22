# H5000M-WIFI-YES-MT5700 固件优化报告

> 生成日期：2026-09-18
> 目标产物：**只保留 `H5000M-WIFI-YES-MT5700-immortalwrt-master` 一套**
> 硬件：Hiveton H5000M / MT7987A（Filogic 880，4×A53，实测档位 0.5/1.3/1.6/2.0 GHz）/ 4 核 / DDR4 1GB / eMMC 8GB / MT7996E（Wi-Fi 7）/ 2×2.5G 网口 / M.2 B-Key USB3.2（5G 模组，走 USB CDC-NCM 出 eth2）
> 参考固件：`好用的固件V0.15.bin`（已解出 rootfs 目录表并提取包清单做对照）

---

## 一、先说结论：这台机器的「硬件加速」到底什么状态

我把真机（当前固件 `ImmortalWrt SNAPSHOT r0-3e24625`，内核 6.18.44）做了一轮**只读体检**，结论是：
**硬件转发能力是有的，但处于「引擎在、开关关、还缺一条腿」的状态。**

| 能力 | 实测结果 | 证据 |
| --- | --- | --- |
| MediaTek **PPE**（Packet Processing Engine，硬件转发表） | ✅ 存在且已注册 | `/sys/kernel/debug/ppe0`、`ppe1` 均存在 |
| 以太网口硬件卸载能力 | ✅ 支持 | `ethtool -k eth0/eth1` → `hw-tc-offload: on` |
| **WED**（Wi-Fi 到 PPE 的硬件转发，MTK 的无线加速） | ❌ **不可用** | `/lib/modules/…` 下无 `mtk_wed.ko`、`modules.builtin` 无 wed、`/sys/bus/platform/drivers/` 下无 `mtk-wed`；且缺 WO 固件。完整取证与三条阻断链见 **附A** |
| **HNAT**（`mtk_hnat`，联发科 tree 外驱动） | ❌ 不在本基线 | 无 `mtk_hnat.ko`，`dmesg` 无 hnat 记录 |
| EIP197 硬件加密（SAFExcel） | ✅ 已加载 | `lsmod` 有 `crypto_safexcel`、`cryptodev` |
| 中断均衡 | ✅ 在跑 | `/usr/sbin/irqbalance -f -c 2 -t 10`，`uci irqbalance.enabled=1` |
| 数据包引导（packet steering） | ⛔ **已停用**（2026-09-22 反转，见下） | 与 `mt5700-rps` 抢同一个 `rps_cpus`，且会把它改回最差的单核掩码 |
| BBR 拥塞控制 | ✅ 已生效 | `/etc/sysctl.d/12-tcp-bbr.conf` + `99-mt5700-tcp.conf` |
| CAKE / SQM | ⚪ 默认关闭（不限速） | `sqm.eth1.enabled='0'` |
| flow offload | ❌ **默认关闭**（2026-09-22 反转：软件卸载也关，理由见第八节） | `Files/etc/mt5700/flow-offload` = `MODE=off`（验收见第五节） |

**关键判断**：上网出口是 **eth2（5G 模组，USB CDC-NCM）**，而 PPE 只挂在 SoC 以太网口（eth0/eth1）上，
**管不到 USB 口**；Wi-Fi 侧想走 PPE 又必须要有 WED，而 WED 模块本基线没有。
所以：**硬件卸载在这台机器上几乎命中不到**（只有「有线 LAN ↔ 有线 LAN」这类流量）。

> ⚠️ **2026-09-22 更正**：本段原先接了一句"真正拿得到、且对所有接口（含 5G WAN）
> 都有效的是**软件 flow offload**"，并据此把它设为默认开启 —— **这个结论已作废**。
> 软件卸载确实对所有接口生效，但它和本固件的 **TTL 统一规则互斥**：flow offload 会把
> 连接从 nftables 路径上摘走 → `mangle_ttl_unify` 零命中 → 运营商按「多设备共享」丢弃
> 客户端 TCP 包 → 客户端完全没网（真机实测：卸载开时 HTTP 25 秒超时、conntrack 带
> `[OFFLOAD]`、postrouting 计数器为 0）。**故软件卸载同样默认关闭**，详见第八节。

---

## 二、本次已实施（可直接构建验证）

### A. 产物收敛：只留一套

| 动作 | 对象 |
| --- | --- |
| 删除工作流 | `AP3000M-MT-AUTO.yml`、`X86-MT-AUTO.yml` |
| 删除配置 | `Config/AP3000M.txt`、`Config/X86.txt`、`Config/MT5700M.txt` |
| 删除专用资源 | `AP3000M-EEPROM/`（EEPROM 模板 + uci-defaults） |
| 删除脚本 | `Scripts/inject_airpi_prebuilt.py`、`Scripts/homeproxy/`、`Scripts/patches/dockerd/` |
| 删除 CI 步骤 | `WRT-CORE.yml` 的「Prebuild AirPi Rust Binary」（AP3000M 专用，省 1.5~3 小时） |
| 收敛手动入口 | `WRT-BUILD.yml` 的机型/源码/MT 模式选项各只留一项 |
| 清理死亡代码 | `Handles.sh` 删掉 HomeProxy 资源预置 + ucode 修复、aurora 样式、AP3000M EEPROM、dockerd 修补四段；`Packages.sh` 去掉 aurora 克隆、HomeProxy 版本约束改写、airpi 克隆 |

> 说明：`ApplyMTMode.sh` / `VerifyMTMode.sh` 里的 **MT5700M 分支保留为守卫**——
> 现在 `Config/MT5700M.txt` 已删除，万一有人手滑选了 MT5700M 会**明确报错终止**，而不是静默编出半残固件。
>
> 补充（2026-09-22）：该文件曾在 2026-09-21 被误当"缺失的 bug"补回一次 —— 补回等于
> **临时拆掉这道守卫**（误选会真的开始克隆 QModem + 折叠 + 出未验证固件）。现已删除还原，
> 并把 `ApplyMTMode.sh` / `VerifyMTMode.sh` 的 MT5700M 分支统一改成**明确报"该方案已停用"**
> （语义比"缺文件"更直白），同时清掉 `Packages.sh` 里随之永不再执行的 QModem 克隆、
> `FIX_QMODEM_VERSION` 与 `FOLD_MT5700M`。

### B. 固件版本标识

`woshinibabao1-26.09.15-17.00.22` → **`OWrt-26.09.15-17.00.22`**

做法：`WRT-CORE.yml` 新增可选输入 `WRT_MARK`（默认 `OWrt`），两个调用方显式传 `OWrt`；
`Settings.sh` 里拼状态页字符串的那行不变（它一直读 `$WRT_MARK`）。

### C. 插件增删（按你的清单）

| 安装 | 说明 |
| --- | --- |
| `luci-theme-argon` + `luci-app-argon-config` | 由 `WRT_THEME: argon` 驱动（`H5000M-MT-AUTO.yml` / `WRT-BUILD.yml` 已改） |
| `luci-i18n-argon-config-zh-cn` | 中文语言包 |
| ~~`luci-app-openclash` + 中文包~~ | **2026-09-21 已移除**（用户要求）。当时同时把 `dnsmasq` 换成 `dnsmasq-full` 以支持 OpenClash 的 nftset/ipset 分流；OpenClash 移除后 `dnsmasq-full` **保留**（真机在用 + nftset 能力备用），见 `Config/GENERAL.txt` |

| 卸载 | 说明 |
| --- | --- |
| `luci-app-homeproxy` / `easytier` / `luci-app-easytier` / `luci-app-gecoosac` / `luci-app-wolultra` / `luci-app-samba4` / `luci-app-upnp` / `luci-theme-aurora` / `luci-app-aurora-config` | 按你的清单 |
| `sing-box`（内核） | **顺带处理孤儿**：它原本只为 HomeProxy 服务，界面一走就是白占空间，一并不编 |
| `luci-app-openclash` + 中文包 / `luci-app-mosdns` + 中文包 + `v2dat` | **2026-09-21 移除**（用户要求）。依据：① 厂家基准（Mwrt 1139-24 的服务集合、higowrt defconfig 157 个 =y 包）二者皆无；② 真机实测装了 `luci-app-openclash-0.47.165`、`luci-app-mosdns-1.7.14`+`mosdns-5.3.4`；③ 二者在真机上均为负面收益（openclash 僵尸服务致 fw4 告警；mosdns 关闭后 dnsmasq 指向 5335 死端口致解析 ~3 秒） |

| **补回** | 说明 |
| --- | --- |
| ~~`luci-app-mosdns` + 中文包 + `v2dat`~~ | 2026-09-15 补回，**2026-09-21 按用户要求再度移除**（原因见上表）。教训：以「真机在跑」为由补回插件前，先确认它是否真的被用户需要 —— 真机在跑可能是因为它当初就是被默认装进去的 |

### D. 网络加速 / 稳定性（核心改动，落在首次开机脚本）

**1）~~默认开启软件 flow offload~~ → 已于 2026-09-22 反转：改为**默认关闭**（两种卸载都关）**

> ⚠️ 原结论「SQM 没开就打开软件卸载」已被实测推翻，**别照着恢复**。
>
> 触发点：当天发现**软件卸载同样会绕过 nftables**，而本固件靠 nft 在 WAN 出口统一
> 改写 TTL（`Files/etc/nftables.d/12-mangle-ttl-128.nft`）。卸载一开，TTL 规则零命中，
> 运营商按「多设备共享」丢弃客户端 TCP 包 —— 症状是「路由器自己能上网、手机电脑全断」，
> 与 DNS 故障、信号问题极像，极难定位。真机实测对照：
> 卸载开 → 客户端 HTTP 25 秒超时、conntrack 条目带 `[OFFLOAD]`、`postrouting` 计数器 0；
> 卸载关 → 同一请求 HTTP 200 / 1.0 秒。
>
> 现在的取值：`Files/etc/mt5700/flow-offload` = `MODE=off`，
> `Scripts/ApplyFlowOffload.sh` 的默认值也是 `off`；想要卸载加速须在编译入口显式选
> `on` / `on-hw`，代价是 TTL 统一失效（该脚本头部写清了这一点）。
> 硬件卸载（`flow_offloading_hw`）**仍然关闭**，理由见第一节：没有 WED、WAN 是 USB，
> 开了命中率≈0 还会让 nft 计数器看不到流量、排障变难。
> 回滚/核对：`cat /etc/mt5700/flow-offload` 期望 `MODE=off`；
> `uci get firewall.@defaults[0].flow_offloading` 期望 `0`。

**2）~~显式兜底 packet steering~~ → 已于 2026-09-22 反转：改为**停用**（同脚本第 4 节）**

> ⚠️ 原结论「必须由 uci 驱动 `packet_steering='1'`」已被实测推翻，**别照着恢复**。
>
> 它和 `mt5700-rps` 都写 `/sys/class/net/*/queues/*/rps_cpus`，而它用的是
> `cpu_mask(cpu) = 1 << cpu`（每队列**单核掩码**），正是实测三档里最差的一档。
> 且它注册了 `network` / `firewall` / `interface.*` 触发器 —— 用户在 LuCI 保存一次
> 「网络」或「防火墙」配置就会 reload，把 `mt5700-rps` 设的 `e`/`f` 改回 `4`/`8`。
>
> 现做法：`uci-defaults`(S10) 删键 + `disable`（管下次开机）；`mt5700-rps`(S95 > S25)
> 写掩码前 `stop` 掉本次开机已起来的实例（rc 序列的 `S*` glob 开机就展开完，`disable`
> 挡不住本次）。实测注册计数 1→0，之后两次 config.change 掩码纹丝不动。
> ⚠️ 不能用 `packet_steering='0'` 当"关掉" —— 那会让 ucode 把 RPS **整个清零**，更糟。
>
> 完整证据与触发手法见 `CHANGELOG.md` 的 `[2026-09-22]` 条目。
>
> 相关但独立的一条（未反转，仍然成立）：硬件中断亲和改由 `mt5700-smp` 接管，
> `irqbalance` 在 `99-mt5700-net` 里被显式停用 —— 实测它对负载最大的无线 IRQ 79
> 与 USB 5G IRQ 74 毫无作为，且两者同写 `smp_affinity` 会互相覆盖，必须二选一。
> 收包软中断那一半由开机启用的 `mt5700-rps` 强制多核掩码兜底。

**3）内核参数补三项低风险项**（`Files/etc/sysctl.d/99-mt5700-tcp.conf`）

| 参数 | 值 | 理由 |
| --- | --- | --- |
| `net.ipv4.tcp_fastopen` | `3` | 省掉一次握手 RTT，对 5G 链路的「点一下要等」观感改善最明显；对端不支持会自动回退 |
| `net.core.somaxconn` / `net.ipv4.tcp_max_syn_backlog` | `1024` | 默认 128/256，几十台设备同时建连会丢 SYN；只增大排队，几乎不吃内存 |
| `net.ipv4.conf.{default,all}.rp_filter` | `0` | **双出口**（eth1 有线 + MT5700M 5G）非对称路由下，`rp_filter=1` 会把「5G 进、有线回」的包当伪造丢掉，症状是部分网站时通时不通 |

**4）编译期补齐硬件相关内核模块**（`Config/GENERAL.txt`）
`kmod-nf-flow`（flow offload 依赖）、`kmod-crypto-hw-safexcel`（EIP197 硬件加密，原本是靠依赖带入，现在显式声明防止被精简掉）。

---

## 三、明确**没有**做的（负优化，不做）

| 你提到的 / 常见的 | 不做的理由 |
| --- | --- |
| **turboacc**（`luci-app-turboacc` / `kmod-fast-classifier` / `shortcut-fe`） | 这东西是给 **Qualcomm / 老内核**的树外加速，路径和 `nf_flow_table` 抢同一批 hook。在 6.18 + Filogic 上：① SFE/FC 基本编译不过；② 就算编过，**一旦启用 flow offload** 两者会互相打架，典型症状是随机断流（注意 flow offload 本固件默认是关的，见第八节）。而 turboacc 在 filogic 上剩下的「BBR + FullCone」两项**本固件早就默认开了**（BBR 在 sysctl，fullcone 在 firewall defaults=1）。加它 = 纯亏体积 + 引入冲突 |
| **`mtk_hnat`（联发科 HNAT 驱动）** | 这是 **mtk-openwrt-feeds 的树外驱动**，immortalwrt master（你现在的基线）没收录 —— 真机 `/lib/modules` 里根本没这个 .ko。主线用的是新一代 **PPE**（就是 `/sys/kernel/debug/ppe0`、ppe1 那个）。再叠一套 tree 外 HNAT 会和 PPE **抢同一张硬件转发表**，属于教科书级负优化 |
| **WED（Wi-Fi 硬件转发）** | 本基线没有 `mtk_wed.ko`。要拿到需要引入 mtk-openwrt-feeds 的 WED 补丁（你这仓库 2026-08 曾注入过 `999-mtk7987-wed-v31.patch`，后来被移除了）。→ ⛔ **2026-09-22 已定案：不做**，三条阻断链与完整取证见 **附A**（不只是"需真机验证"，而是即使补齐也只剩断开 TTL 统一这一条死路） |
| **zram / swap** | 1GB DDR4，实测 free 477MB、buff/cache 265MB，没有内存压力。加 zram 是拿 CPU 换内存，在这台机器上净亏 |
| **netdev_max_backlog / TCP 缓冲区放大** | ⚠️ **2026-09-22 已撤销此结论**（原判据有两处错，详见第七节）：① 范畴错 —— `netdev_max_backlog` 是**每 CPU 的收包积压**（NAPI 与协议栈之间的 skb 指针队列），不是出口 qdisc 队列，fq_codel/CAKE 作用的不是这里；② 前提反转 —— 当时假设「flow offload 默认开、转发走快路」，而现在默认已是 `off`（TTL 统一规则要求），软件转发路径成为常态。已按新前提重新取值 |
| **改 CPU 调度器 / 锁定高频** | 实测 governor 已是 `schedutil`，档位 0.5/1.3/1.6/2.0 GHz 正常。锁 `performance` 只增加发热（这台机器还有温控风扇） |

---

## 四、需要你拍板的三件事

> ℹ️ 本节是**当时**的待决清单。三项此后都已定案，结论见下（详细依据见附A / 第七节）。

1. **要不要 Wi-Fi 硬件转发（WED）？** → ⛔ **已定案：不做**（附A）。
   当时以为"真·加速就靠它"，但真机取证后三条阻断链同时成立：缺 WO 固件、
   缺 `nf_flow_table_hw`/`flow_offload_hw_*` 钩子、且 WED 只在硬件卸载开启时工作
   而硬件卸载会破坏 TTL 统一（=客户端断网）。**别再注入 WED 补丁**（历史见 A.5）。

2. **要不要把 flow offload 的开关做成可见配置？** — 现状已满足需求：
   选型由编译入口 `WRT_FLOW_OFFLOAD`（默认 off）决定并写进 `/etc/mt5700/flow-offload`，
   Release 说明里已写明默认值与代价（第八节）。用户仍可在 LuCI 防火墙页自行改。
   （注意：本次文案纠偏撤掉了原 Release 里"默认开软件卸载"的错误说法。）

3. **sing-box 内核彻底不编，你 OK 吗？**
   已确认并落地：用户本次已回答「要」。`Config/GENERAL.txt` 显式写死 `CONFIG_PACKAGE_sing-box=n` /
   `luci-app-homeproxy=n` / `luci-i18n-homeproxy-zh-cn=n`（见 P04），并由 `Scripts/VerifyNoSingBox.sh`
   在编译前（查 `.config`）+ 编译后（查 `*.manifest`）做双重断言（见 P05）。即便将来某包 DEPENDS 反向
   拉回 sing-box，`=n` + 两道断言也会拦下，不会静默编入。

---

## 五、刷机后怎么验证（建议顺序）

```sh
# 1. flow offload 当前模式（默认应为 off —— TTL 统一规则要求）
cat /etc/mt5700/flow-offload                            # 期望 MODE=off
uci get firewall.@defaults[0].flow_offloading          # 期望 0（选 on/on-hw 时才为 1）
nft list ruleset | grep -i flow                        # 期望出现 flowtable / flow add

# 2. 硬件引擎在不在（确认基线没变）
ls /sys/kernel/debug/                                  # 期望有 ppe0 ppe1

# 3. 加速是否真的落到转发路径（跑个下载再看计数）
cat /sys/kernel/debug/ppe0/entries | head             # 硬件卸载条目（有线↔有线才会有）

# 4. 版本标识
#    LuCI 状态页底部应显示：… / OWrt-<日期>

# 5. 中断是否分散
cat /proc/interrupts | head -20                        # 对比 CPU0..CPU3 是否都有计数
```

**A/B 对比建议**：同一点位、同一时段，开/关 flow offload 各跑 3 次 `iperf3` 或 speedtest，
同时看 `htop` 里 CPU 占用。若发现「开了反而慢/断流」，按第二节的回滚命令关掉即可，
其余优化项互不影响。

---

## 六、改动文件清单

> ℹ️ 本节记录**当时那一轮**改了哪些文件，是历史快照。其中 flow offload 与 packet steering
> 两项此后已被实测反转，逐条修正见第八节。

| 文件 | 动作 |
| --- | --- |
| `.github/workflows/H5000M-MT-AUTO.yml` | 改：主题 argon、新增 `WRT_MARK: OWrt` |
| `.github/workflows/WRT-BUILD.yml` | 改：选项收敛、`WRT_THEME: argon`、`WRT_MARK: OWrt`、固定 MT5700 |
| `.github/workflows/WRT-CORE.yml` | 改：新增 `WRT_MARK` 输入/env、删 AP3000M Rust 预编译步骤 |
| `.github/workflows/AP3000M-MT-AUTO.yml`、`X86-MT-AUTO.yml` | 删 |
| `Config/GENERAL.txt` | 改：插件增删 + 硬件加速段 |
| `Config/AP3000M.txt`、`X86.txt`、`MT5700M.txt` | 删 |
| `Files/etc/uci-defaults/99-mt5700-net` | 改：flow offload 默认开（SQM 互斥）、packet steering 兜底 —— ⚠️ **两项均已于 2026-09-22 反转**（改为默认关 / 改为停用），见第八节 |
| `Files/etc/sysctl.d/99-mt5700-tcp.conf` | 改：TFO / backlog / rp_filter 三项 |
| `Scripts/Packages.sh` | 改：去 aurora、homeproxy 改写、airpi |
| `Scripts/Handles.sh` | 改：删 homeproxy / aurora / AP3000M EEPROM / dockerd 四段 |
| `Scripts/inject_airpi_prebuilt.py`、`Scripts/homeproxy/`、`Scripts/patches/dockerd/` | 删 |
| `AP3000M-EEPROM/` | 删 |

---

## 七、2026-09-22 第二轮：软件转发收包路径 + NAT 端口段（基准：`好用的固件V0.18.bin`）

### 7.1 为什么会有这一轮

上一轮以基线镜像为基准筛出 3 项（qdisc/缓冲/packet steering）。本轮把基线固件的
`/etc` **全部摊开逐文件比对**（`sysctl.d`5、`init.d`47、`uci-defaults`44、`hotplug.d`11、
`modules.d`89、`board.d`8、`rc.d`、`config`21、`nftables.d`，外加 `/sbin/smp*.sh`、
`/sbin/flowtable.sh` 与 `/lib/apk/db/installed` 的 361 个包），结论是
**基线里已没有新的可搬优化项**（11 项差异的逐条判定见 `CHANGELOG.md` 同日期条目，
含 WED、MTK smp 派发、风扇、LAN/WAN 口定义、`--allow-untrusted` 补丁是否真进固件等）。

所以本轮的 4 项改动**来自我方已有调优自身没做完的部分**，不是基线差异。

### 7.2 四项改动

| # | 项 | 原值 | 新值 | 依据 |
| :-- | :-- | :-- | :-- | :-- |
| 1 | `net.ipv4.ip_local_port_range` | `32768 60999`（可用 28232） | `10240 65535`（55296） | **上一轮优化的收尾**：`nf_conntrack_max` 提到了 100000，但 SNAT 可用端口仍被默认区间封顶 → 瓶颈从"表容量"转移到"端口段"，实际到 2.8 万条就不再建新连接 |
| 2 | `net.core.netdev_max_backlog` | 1000（内核默认） | 5000 | eth2 **真机实测 1280Mb/s**；flow offload 必须关 → 全软件转发；RPS 分四核后每核 ~26kpps，1000 包只够缓冲 ~38ms，溢出即**静默丢包** |
| 3 | `net.core.netdev_budget` | 300（内核默认） | 600 | 同上场景：每核单轮 300 包成为瓶颈，CPU 时间耗在反复进出软中断。有 `netdev_budget_usecs` 兜底（本机实测 **20000μs**，不是常见文档里写的 2000μs —— 见下「数字更正」），单核不会被长期霸占 |
| 4 | `99-mt5700-conntrack.conf` 注释 | 写"`nf_conntrack_buckets` 本机默认即 65536" | 改为真机实测 **63488** | 这是**错数字**不是错决策：buckets 在模块加载那刻由 `conntrack_max` 推导，之后抬高 max 不会重算。63488 vs 65536 的取舍结论不变，但数字必须写准 |

**回滚**（任一项都独立，互不影响）：

```sh
sysctl -w net.ipv4.ip_local_port_range="32768 60999"
sysctl -w net.core.netdev_max_backlog=1000
sysctl -w net.core.netdev_budget=300
# 或直接删掉 Files/etc/sysctl.d/99-mt5700-*.conf 里对应行后重启
```

### 7.3 与第三节旧结论的冲突处理

第七节第 2 项直接推翻了第三节"`netdev_max_backlog` 保持默认"的旧结论，故该行已就地标注撤销，
两步原因（① 把 `netdev_max_backlog` 当成出口 qdisc 队列是范畴错误；② 前提从"offload 开"
反转为"offload 关"）写在第三节那行里，不留矛盾表述。

### 7.4 本轮确认**不能做**的两项（附硬证据，避免以后再挖）

- **WED**：不是"驱动没做完"这么简单，完整阻断链见 **附A**（结论：WED 与 HNAT 不重叠、
  WED 依赖 HNAT；本机三条阻断链同时成立 —— 缺 WO 固件、缺 `nf_flow_table_hw`/
  `flow_offload_hw_*`、且 WED 只在硬件卸载开启时工作而硬件卸载会破坏 TTL 统一）。
  基线固件同样把 `wed_enable` 写成 0（`/etc/modules.d/mt7996e`）。
- **`luci-app-mtk-puncture`（Wi-Fi 7 前导码打孔）**：驱动 `mt76.ko`/`mt76-connac-lib.ko`/
  `mt7996e.ko` 中 `punctur` **零命中**；`/lib/netifd/`、`/usr/share/hostap/`、`hostapd.uc`
  也零命中 → 即使装了 LuCI 包写进 UCI，**没有任何链路把值传给 hostapd**（hostapd v2.12
  本身有 `puncturing_bitmap`，但没人喂它）。本机无线是 **MT7992E** 且 2.4G 已禁用。

### 7.5 刷机后验证

```sh
# 1. 端口段
cat /proc/sys/net/ipv4/ip_local_port_range        # 期望 10240	65535
# 2. 收包积压 / 单轮预算
cat /proc/sys/net/core/netdev_max_backlog         # 期望 5000
cat /proc/sys/net/core/netdev_budget              # 期望 600
# 3. 积压溢出计数（若持续增长说明 backlog 还不够，见 /proc/net/softnet_stat 第 10 列）
awk '{print $1, $10}' /proc/net/softnet_stat
# 4. NAT 端口是否真的用起来了（并发高时抽样）
cat /proc/net/nf_conntrack | wc -l
```

---

## 附A、WED 与 HNAT 的关系（定论归档，2026-09-22）

**结论：不重叠。WED 与 HNAT 不是二选一，而是同一条硬件加速流水线的上下游；且 WED 严格依赖 HNAT/PPE，单独开 WED 没有任何意义。**

### A.1 三方独立依据

- **OpenWrt 官方 WED 文档**：WED 是 hardware flow offloading 的**扩展**，
  "allowing the Packet Processing Engine (PPE) to handle packets directly to/from the
  WiFi chipset"；并明确写着 **"WED is only working when HW (hardware) offload is enabled.
  It does not work for SW offload or when offload is disabled."**
- **OpenWrt BPI-R4 页面（MT7988，与 MT7987 同代 NETSYS V3）**：WED 是"traffic forwarding
  from/to Wireless"，"It works with the existing flow-offloading aka. **HWNAT engine**
  of MediaTek SoCs"。
- **厂家脚本自证**：基线 `/sbin/smp-mt76.sh` 里只有 `WED_ENABLE=1` 时才调用
  `nftables_flowoffload_enable "$HW_OFFLOAD"`（`HW_OFFLOAD=1`）。
  → **WED 是"开关条件"，HNAT 才是被打开的东西。**

**命名对照（同一件事的三套名字）**：HNAT / HWNAT（厂外树外驱动 `mtk_hnat`）
＝ PPE（主线 `mtk_ppe` + `mtk_eth_soc` offload；Netsys V3 文档里也叫 NPU）
＝ 转发加速引擎。WED（Wireless Ethernet Dispatch，配 WDMA）＝ 把 Wi-Fi 芯片的包
DMA 直送 PPE 的通道。**一句话：HNAT 是引擎，WED 是给引擎接上无线的管子。**

### A.2 本机实测状态（2026-09-22，全部只读）

| 环节 | 状态 | 证据 |
| :-- | :-- | :-- |
| PPE/HNAT 引擎本体 | ✅ 在 | `/sys/kernel/debug/ppe0`、`ppe1`（含 `entries`/`bind`）；符号 `mtk_ppe_init` / `mtk_ppe_start` / `mtk_ppe_debugfs_init` / `mtk_flow_offload_replace` / `mtk_eth_offload_init` 齐 |
| 当前流表条目 | 0 条 | `/sys/kernel/debug/ppe0/entries` 为空（offload 关着，符合预期） |
| WED 硬件节点 | ✅ 在 | DT `wed@15010000`（compatible `mediatek,mt7987-wed`）+ `wdma@15104800`；`/sys/kernel/debug/wed0/`（txinfo/rxinfo/rro/amsdu/rtqm/regidx） |
| WED 驱动符号 | ✅ 在 | 48 个 `mtk_wed*` 符号（`attach`/`flow_add`/`start`/`stop`/`mcu_init`/`tx_ring_setup`…） |
| **WED 是否 attach** | ❌ **没有** | dmesg **无** `platform 15010000.wed: MTK WED WO Firmware Version …`（attach 成功的标志行）；`wed0/txinfo`、`rxinfo` 读出为空；`15010000.wed/driver` 无绑定，`/sys/bus/platform/drivers/` 下无 `mtk-wed` |
| **WO 固件** | ❌ **缺失** | `/lib/firmware` 下 `find -iname '*wo*' -o -iname '*wed*'` **零命中**；`mediatek/mt7987/` 只有 2.5G PHY 的 `i2p5ge-phy-*.bin`。MT7987（Netsys V3）执行 WED 需要 WO 固件 |
| **硬件流表钩子** | ❌ **未编入** | `nf_flow_table_hw.ko` 不在 `/lib/modules`、不在 `modules.builtin`；kallsyms 里**连 `flow_offload_hw_*` 符号都没有**（只有软件路径 `nf_flow_offload_add/del/hook/stats`）。而 `/etc/modules.d/nf-flow` 里却写着 `nf_flow_table_hw` 一行 → **死引用**，kmodloader 加载失败且不报错 |
| 桥接 BPF 组件 `bridger` | ✅ 已装但无用 | 已装、`bridge_local_tx=1`/`rx=0`。它只在 WED 生效时才有意义（dumb-AP 下跟踪桥接流） |

### A.3 本机 WED 不可用的阻断链（三条同时成立）

1. **缺 WO 固件**（`mt7987_wo.bin`）→ WED 无法 attach；
2. **缺 `nf_flow_table_hw` / `flow_offload_hw_*`** → PPE 接不上 nft 流表；
3. **即使前两条补齐，WED 也只在硬件卸载开启时工作** → 必须 `flow_offloading_hw=1`
   → 而这会绕过 nft 的 postrouting → **TTL 统一失效 → 运营商丢弃客户端 TCP
   → 客户端完全没网**（2026-09-21 已实测：offload 开时客户端 HTTP 25 秒超时、
   conntrack 条目带 `[OFFLOAD]`、`mangle_ttl_unify` 的 postrouting 计数器为 0）。

### A.4 取舍的实质与结论

需要同时取舍的不是 "WED vs HNAT"，而是 **"硬件加速 vs 客户端能不能上网"**。
本机 WAN 是 5G 模组（eth2），客户端数量有限、上行普遍 <200Mbps，软件转发（四核 RPS）
足以覆盖；而 TTL 统一是**硬前提**（缺了它客户端完全不通）。
→ **结论：保持现状（flow offload 关、`flow_offloading_hw=0`、`wed_enable=N`）。**

### A.5 历史存档：别再重新注入 WED 补丁

本仓库 2026-08 曾注入 MT7987 WED V3.1 补丁（`Scripts/patches/wed/999-mtk7987-wed-v31.patch`
与 `998-mt76-wed-hwrro-enum.patch`），经 `d1d718d` → `313909a` → `9069348` → `6e2e650`
→ `f2096b6` → `a678400` 多轮修编译，最终以 `341b87c`、`0b10213`
（"Remove kernel-side WED v3.1 patch that broke mt76 build"）移除。
**别再重来** —— 就算编译过了，A.3 的三条阻断链依然成立。

---

## 八、文档纠偏：Release 说明泄露内部笔记 + flow offload 文案与代码相反（2026-09-22）

### 8.1 问题一：Release 正文里混进了 3 行"内部工作笔记"

`WRT-CORE.yml` 的 Release 步骤原先写成：

```yaml
body: |
  # 文案按实际产物写：单 profile 编译，只此一个设备；加速只开软件卸载。
  # 原「内含多个设备 / 全系带开源硬件加速」与实际不符 —— …（另 1 行）
  本 Release 只含 Hiveton H5000M …
```

**这里的 `#` 不是 YAML 注释。** `body: |` 是块标量（literal block scalar），
其内部每一行都是**字面内容** —— 注释必须写在标量的缩进之外才生效。
所以这 3 行会原样进入发布说明；而 markdown 里行首 `#` 是一级标题，
Release 页面顶部会顶出一个巨大的标题，内容是"改文案的理由"这类内部笔记。

**判据（可直接复用，别靠肉眼）**：

```python
import yaml
d = yaml.safe_load(open('.github/workflows/WRT-CORE.yml'))
body = [s for s in d['jobs']['core']['steps'] if s.get('name') == 'Release Firmware'][0]['with']['body']
print(body[:200])
```
改前打印出的前 3 行正是那 3 条笔记；改后消失。

**修法**：把笔记移出 `body`（要留就留在 `body:` 键的上一行、缩进与键对齐），
标量内部只放面向使用者的正文。

### 8.2 问题二：文案写"默认开软件 flow offload"，与代码相反

同一段文案写着「加速现状（勿误读）：默认开「软件 flow offload」（nf_flow_table）」。
实际默认值是 **off**，三处独立取值可证：

| 位置 | 实际值 |
| :-- | :-- |
| `Files/etc/mt5700/flow-offload` | `MODE=off` |
| `Scripts/ApplyFlowOffload.sh` | `MODE="${WRT_FLOW_OFFLOAD:-off}"` |
| `WRT-BUILD.yml` / `H5000M-MT-AUTO.yml` 的 `FLOW_OFFLOAD` 输入 | `default: 'off'` |

**为什么必须关**：任何 flow offload（软件的一样）都会把连接从 nftables 路径上摘走，
而本固件依赖 nft 在 WAN 出口统一改写 TTL → 卸载一开，TTL 规则零命中 → 运营商按
「多设备共享」丢弃客户端 TCP 包 → **客户端完全没网**（真机实测：卸载开时客户端
HTTP 25 秒超时、conntrack 带 `[OFFLOAD]`、`postrouting` 计数器为 0；关掉后同请求
HTTP 200 / 1.0 秒）。

原文案不但说反了，还**漏掉了这条最关键的警告** —— 照它做的人把卸载打开就会断网，
而症状（路由器自己能上网、客户端全断）极易被误判成 DNS 或信号问题。

### 8.3 一并修掉的其他残留（同一处决策被反转、文档没跟上）

| 位置 | 原文 | 改为 |
| :-- | :-- | :-- |
| `Config/GENERAL.txt` 硬件加速段 | "默认开「软件 flow offload」" | 明确两种卸载默认都关 + 说明与 TTL 互斥 |
| 本报告第一节表格 flow offload 行 | "❌ 关闭（本次改为默认开）"（自相矛盾） | "❌ 默认关闭（2026-09-22 反转…）" |
| 本报告第一节"关键判断"段 | 推荐"软件 flow offload 是对所有接口都有效的路径" | 加更正框：该结论已作废 |
| 本报告第二节 D-1 | "默认开启软件 flow offload" | 按本报告既有"反转"体例标注作废 + 写清新取值 |
| 本报告第六节改动文件清单 | 无标注 | 加"历史快照"说明 + 该行就地标注两项已反转 |

`CHANGELOG.md` 里的历史条目**不改**（那是按日期记录"当时是什么"），纠偏只记在本轮新增条目里。

### 8.4 教训（可复用）

- **YAML 块标量里的 `#` 是内容，不是注释。** 想在 `body: |` 里写说明，必须放在标量
  缩进之外；否则会跟着一起发布出去（本例还是一级标题，最显眼）。
  验证一律用解析器打印实际取值，别靠肉眼看 YAML。
- **"默认值"这类事实要以代码为唯一准绳。** 同一件事在 `Files/`、`Scripts/`、workflow
  输入三处各写过一次默认值 —— 任一处改了都必须同步校验另外两处，否则用户读到的说明
  会和产物行为分叉。（本次三处取值一致，分歧只在文案，属于"只改了代码没改说明"。）
- **决策反转后要按"结论句"而非参数名全仓 grep。** `flow offload` 默认值反转后一天，
  仍有 5 处文档写着旧结论。搜索关键词不能只用参数名，还要搜旧结论的自然语言形态
  （`默认开` + `offload`、`软件 flow offload`），否则漏得干干净净。


