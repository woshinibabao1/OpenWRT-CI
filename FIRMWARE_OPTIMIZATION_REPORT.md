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
| **WED**（Wi-Fi 到 PPE 的硬件转发，MTK 的无线加速） | ❌ 缺失 | `/lib/modules/6.18.44/` 下无 `mtk_wed.ko`；`lsmod` 无 `mtk_wed` |
| **HNAT**（`mtk_hnat`，联发科 tree 外驱动） | ❌ 不在本基线 | 无 `mtk_hnat.ko`，`dmesg` 无 hnat 记录 |
| EIP197 硬件加密（SAFExcel） | ✅ 已加载 | `lsmod` 有 `crypto_safexcel`、`cryptodev` |
| 中断均衡 | ✅ 在跑 | `/usr/sbin/irqbalance -f -c 2 -t 10`，`uci irqbalance.enabled=1` |
| 数据包引导（packet steering） | ⛔ **已停用**（2026-09-22 反转，见下） | 与 `mt5700-rps` 抢同一个 `rps_cpus`，且会把它改回最差的单核掩码 |
| BBR 拥塞控制 | ✅ 已生效 | `/etc/sysctl.d/12-tcp-bbr.conf` + `99-mt5700-tcp.conf` |
| CAKE / SQM | ⚪ 默认关闭（不限速） | `sqm.eth1.enabled='0'` |
| flow offload | ❌ **关闭**（本次改为默认开） | 防火墙 defaults 里没有 `flow_offloading` 项 |

**关键判断**：上网出口是 **eth2（5G 模组，USB CDC-NCM）**，而 PPE 只挂在 SoC 以太网口（eth0/eth1）上，
**管不到 USB 口**；Wi-Fi 侧想走 PPE 又必须要有 WED，而 WED 模块本基线没有。
所以：**硬件卸载在这台机器上几乎命中不到**（只有「有线 LAN ↔ 有线 LAN」这类流量），
真正拿得到、且对所有接口（含 5G WAN）都有效的是**软件 flow offload（nf_flow_table 快转路径）**。

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

**1）默认开启软件 flow offload**（`Files/etc/uci-defaults/99-mt5700-net`）

- 之前是**无条件关闭**；现在改成：**SQM 没开就打开软件卸载，SQM 开了就保持关闭**，二者互斥（被卸载的连接绕过 qdisc，CAKE/HTB 会失效）。
- 硬件卸载（`flow_offloading_hw`）**仍然关闭**，理由见第一节：没有 WED、WAN 是 USB，开了命中率≈0 还会让 nft 计数器看不到流量、排障变难。脚本里写清了「等固件带 `mtk_wed` 再开」。
- 回滚：网络 → 防火墙 → 常规设置，取消「Flow Offloading」；或
  `uci set firewall.@defaults[0].flow_offloading=0; uci commit firewall; /etc/init.d/firewall restart`

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
| **turboacc**（`luci-app-turboacc` / `kmod-fast-classifier` / `shortcut-fe`） | 这东西是给 **Qualcomm / 老内核**的树外加速，路径和 `nf_flow_table` 抢同一批 hook。在 6.18 + Filogic 上：① SFE/FC 基本编译不过；② 就算编过，和已开启的 flow offload 并存会互相打架，典型症状是随机断流。而 turboacc 在 filogic 上剩下的「BBR + FullCone」两项**本固件早就默认开了**（BBR 在 sysctl，fullcone 在 firewall defaults=1）。加它 = 纯亏体积 + 引入冲突 |
| **`mtk_hnat`（联发科 HNAT 驱动）** | 这是 **mtk-openwrt-feeds 的树外驱动**，immortalwrt master（你现在的基线）没收录 —— 真机 `/lib/modules` 里根本没这个 .ko。主线用的是新一代 **PPE**（就是 `/sys/kernel/debug/ppe0`、ppe1 那个）。再叠一套 tree 外 HNAT 会和 PPE **抢同一张硬件转发表**，属于教科书级负优化 |
| **WED（Wi-Fi 硬件转发）** | 本基线没有 `mtk_wed.ko`。要拿到需要引入 mtk-openwrt-feeds 的 WED 补丁（你这仓库 2026-08 曾注入过 `999-mtk7987-wed-v31.patch`，后来被移除了），且**必须真机验证 Wi-Fi 起得来**。盲加的风险是 AP 直接起不来 —— 属于「需人工决策 + 真机验证」项，见第四节 |
| **zram / swap** | 1GB DDR4，实测 free 477MB、buff/cache 265MB，没有内存压力。加 zram 是拿 CPU 换内存，在这台机器上净亏 |
| **netdev_max_backlog / TCP 缓冲区放大** | 有 fq_codel 与（可选的）CAKE 兜底，盲目放大 backlog 会加重 bufferbloat，反而更卡。保持默认 |
| **改 CPU 调度器 / 锁定高频** | 实测 governor 已是 `schedutil`，档位 0.5/1.3/1.6/2.0 GHz 正常。锁 `performance` 只增加发热（这台机器还有温控风扇） |

---

## 四、需要你拍板的三件事

1. **要不要 Wi-Fi 硬件转发（WED）？**
   真·加速就靠它（Wi-Fi ↔ 有线走 PPE，CPU 基本不参与）。代价是引入 mtk-openwrt-feeds 的 WED 补丁，
   **有 Wi-Fi 起不来的风险**，必须刷机实测。要做的话我建议单独开一个分支试，别直接进日常产物。

2. **要不要把 flow offload 的开关做成可见配置？**
   现在是「首次开机自动决定」，用户改过就不再覆盖。如果你希望刷完就能在界面上看见/切换，
   我可以把它写进 `/etc/config/firewall` 并在 Release 说明里标注。

3. **sing-box 内核彻底不编，你 OK 吗？**
   已确认并落地：用户本次已回答「要」。`Config/GENERAL.txt` 显式写死 `CONFIG_PACKAGE_sing-box=n` /
   `luci-app-homeproxy=n` / `luci-i18n-homeproxy-zh-cn=n`（见 P04），并由 `Scripts/VerifyNoSingBox.sh`
   在编译前（查 `.config`）+ 编译后（查 `*.manifest`）做双重断言（见 P05）。即便将来某包 DEPENDS 反向
   拉回 sing-box，`=n` + 两道断言也会拦下，不会静默编入。

---

## 五、刷机后怎么验证（建议顺序）

```sh
# 1. flow offload 是否真的生效
uci get firewall.@defaults[0].flow_offloading          # 期望 1
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

| 文件 | 动作 |
| --- | --- |
| `.github/workflows/H5000M-MT-AUTO.yml` | 改：主题 argon、新增 `WRT_MARK: OWrt` |
| `.github/workflows/WRT-BUILD.yml` | 改：选项收敛、`WRT_THEME: argon`、`WRT_MARK: OWrt`、固定 MT5700 |
| `.github/workflows/WRT-CORE.yml` | 改：新增 `WRT_MARK` 输入/env、删 AP3000M Rust 预编译步骤 |
| `.github/workflows/AP3000M-MT-AUTO.yml`、`X86-MT-AUTO.yml` | 删 |
| `Config/GENERAL.txt` | 改：插件增删 + 硬件加速段 |
| `Config/AP3000M.txt`、`X86.txt`、`MT5700M.txt` | 删 |
| `Files/etc/uci-defaults/99-mt5700-net` | 改：flow offload 默认开（SQM 互斥）、packet steering 兜底 |
| `Files/etc/sysctl.d/99-mt5700-tcp.conf` | 改：TFO / backlog / rp_filter 三项 |
| `Scripts/Packages.sh` | 改：去 aurora、homeproxy 改写、airpi |
| `Scripts/Handles.sh` | 改：删 homeproxy / aurora / AP3000M EEPROM / dockerd 四段 |
| `Scripts/inject_airpi_prebuilt.py`、`Scripts/homeproxy/`、`Scripts/patches/dockerd/` | 删 |
| `AP3000M-EEPROM/` | 删 |
