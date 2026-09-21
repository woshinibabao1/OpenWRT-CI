# 更新日志

## [2026-09-21] 深挖厂家基准：无线升 EHT160、conntrack expect 表对齐

本轮把对比从「插件层」下沉到 **内核参数 / sysctl / nft / hotplug / 无线默认值**：
解析 Mwrt 固件 `/etc` 全树（1334 节点，提取 614 个文件）逐项对照，并把 higowrt 的
`defconfig/mt7987_mt7992.config` 与上游 immortalwrt 的 `config-6.18` 做交叉比对。

**改动 1：5GHz 由 HE160/HE80 升到 EHT160**（`Files/etc/uci-defaults/99-mt5700-net`）

| 依据 | 内容 |
|---|---|
| 硬件支持 | `iw phy phy0 info` 列出 `EHT Iftypes: AP` 与 `EHT-MCS Map (BW = 160)`；网卡 `iwinfo` 报 MediaTek MT7992E / HW Mode **802.11be** |
| 厂家基准 | Mwrt 的 `99c-wifi-5g-channel-boardb` 注释写明 "mtwifi.sh hands EVERY board the same 5GHz defaults (**channel 36 + EHT160**)" |
| 频谱不变 | 与原先 HE160 同为 36-64 的 160MHz 块，**不新增 DFS 风险** |
| 收益 | 启用 EHT 4096-QAM，Wi-Fi 7 客户端协商速率约翻倍（HE160 2SS 实测 1441 Mbit/s） |

⚠️ CN 域 `(5150 - 5350 @ 160)` 允许该 160MHz 块，但跨 UNII-2A（52-64）属 DFS；
若某环境雷达检测导致 AP 起不来，htmode 退回 `HE80`（36 起 80MHz，非 DFS）。

**改动 2：给所有 radio 补 `country`**（同节 5a）

原先只设了 `radio1`。厂家 `99-wifi-default-country` 是遍历全部 radio——缺 country 时
reg domain 停在 world(00)，5GHz 信道全标 no-IR（不能发信标），表现为"无线像是禁用的"。
新逻辑遍历所有 wifi-device、已有 country 的跳过（幂等，不覆盖手动选择）。

**改动 3：`net.netfilter.nf_conntrack_expect_max` 992 → 16384**
（`Files/etc/sysctl.d/99-mt5700-conntrack.conf`）

expect 表用于 NAT 环境下的**预测连接**（FTP 数据通道、SIP/VoIP、RTSP）。本机 992 的
来由是内核按"模块加载那一刻的 conntrack_max"推导，而我们后来才用 sysctl 把它提到
100000，expect_max 不会重算。纯上限、不预分配，零风险对齐厂家值。

### 已核对并证伪的项（附证据，别再重复排查）

| 项 | 结论 |
|---|---|
| `CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE` | higowrt 有、**上游 generic config-6.18 也有** → 我们继承的就是 O2，非差异 |
| `CONFIG_HZ_100` / `PREEMPT_NONE` / `LRU_GEN` | 上游本来就是这些值，higowrt 未偏离（交集取值不同项 = **0**） |
| `nf_conntrack_helper=1` | 本机 `/proc/sys/net/netfilter/nf_conntrack_helper` **不存在**（该内核未暴露），无法照搬也不必要 |
| buckets / udp_timeout / udp_timeout_stream / acct / checksum / bpf_jit | 真机实测与厂家**完全一致** |
| `vm.min_free_kbytes` / `accept_ra` / `ipfrag_*_thresh` | 真机 16384 / 0 / 内核默认，与厂家一致 |
| 厂家 RPS 写法（`echo 6`，排 CPU0+CPU3） | 我们的全核掩码经多流实测更均匀，且无线侧已按硬中断核动态排除，更好 |
| `99c-wifi-5g-channel-boardb`（改 149） | 门控在 `NRadio-C2000MAX` 板（board B），H5000M 不执行 |
| `99b-wifi-selfmanaged-2g` / `99-be3600-fixups` | 分别针对 Intel 自管理网卡与 MT7993(BE3600) 板，H5000M 不适用 |
| `98-tom_modem-timeout-wrap` / `20-modem-net` / `99-add-5g-handler` | QModem 体系专用（`tom_modem` 是它的 AT 工具）；我们走自研 at-webserver，不引 QModem |
| `eqos` / `turboacc` | 厂家 eqos 默认 `enabled=0`（未启用）；turboacc 的 fastpath 依赖 `mtkhnat.ko`（我们无 HNAT），其 sysctl 项我们已逐条覆盖 |
| `dnsmasq log-facility=/dev/null` | 会丢掉排障日志；我们 `log_size=128`（内存环形缓冲）本就不写 flash，收益为负 |
| zram 压缩算法 | 两边均为 `lzo`、512MB（真机 `uci show system` 实测），无差异；且真机 Swap used = 0（内存充足从未换出），换 zstd 也无实际收益 |
| 无线 EHT40（2.4G） | 真机已是，无需改 |

## [2026-09-21] 移除 OpenClash / MosDNS；与 higowrt + Mwrt 双基准核准

按用户要求移除 OpenClash 与 MosDNS，并以两个厂家基准做了最优性核准。

**移除（`Config/GENERAL.txt` 5 个符号转 `=n` + `Scripts/Packages.sh` 停克隆）**

| 符号 | 处置 |
|---|---|
| `luci-app-openclash` / `luci-i18n-openclash-zh-cn` | `=n` |
| `luci-app-mosdns` / `luci-i18n-mosdns-zh-cn` / `v2dat` | `=n` |

依据（三条独立证据，非仅凭口头要求）：
1. **厂家基准里就没有** —— Mwrt 固件的 `/etc/init.d`（67 项）与 `/etc/config`（32 项）
   中无 openclash / mosdns（其代理能力走 `sing-box` + `xray`）；higowrt 的
   `defconfig/mt7987_mt7992.config` 里 157 个 `=y` 包同样一个都没有。
2. **真机确实装着**（移除前 `apk list --installed` 实测）：`luci-app-openclash-0.47.165`、
   `luci-app-mosdns-1.7.14-r1` + `mosdns-5.3.4-r14` + `geo2txt`。
3. **两者在真机上都是负面收益** —— openclash 是「僵尸服务」（init 已 enable 但无进程，
   fw4 每次报 unreachable path）；mosdns 被关成 `enabled='0'` 后 dnsmasq 仍指向
   `127.0.0.1#5335` 死端口 → 冷域名解析 ~3 秒（2026-09-21 真事故）。

**`dnsmasq-full` 保留**：它当初是为 OpenClash 的 nftset/ipset 而换的，但真机正在运行
`dnsmasq-full 2.93`，换回精简版是无收益的行为变更，且 nftset 能力日后仍可能用到。
`Config/GENERAL.txt` 的注释已改写，不再声称「因为 OpenClash 才留」。

**双基准核准结论（本轮做的最优性核对）**

| 维度 | 结论 |
|---|---|
| 硬件加速 / 闭源驱动 | 不可搬（vermagic 6.6.94 vs 6.18.52）；MT7987 的 WED 属上游未完成。详见 `CLOSED_SOURCE_AUDIT.md` |
| 内核网络栈 | BBR / CAKE / fq_codel / SQM / flow offload 取舍 / TTL 归一 / conntrack / TCP 参数 —— 齐备且均已真机验证 |
| CPU·中断 | `mt5700-smp`（硬中断亲和）+ `mt5700-rps`（RPS 多核掩码）已取代 irqbalance |
| 插件集 | 与厂家基准比**无缺失项**；多出 zram、ttyd、SQM、argon、风扇控制、netmode、MT5700 插件等实用项 |
| 特有加速 | EIP-197 硬件加密已就位（`kmod-crypto-hw-safexcel` + `eip197-mini-firmware`，真机 `/lib/firmware/inside-secure` 存在） |

**顺带清理一：停掉 14 个「克隆了但从未编入固件」的包**（用户确认）

`Scripts/Packages.sh` 里以下 14 项此前每次构建都在克隆，但 `Config/*.txt` 四个文件全量
扫描无对应 `CONFIG_PACKAGE_*=y`，真机 `apk list --installed` 也确认从未安装
—— 纯浪费时间与 CI 机时（每次 clone 5~30 秒）：

`momo`、`nikki`、`passwall`、`passwall2`、`luci-app-tailscale`、`ddns-go`、`diskman`、
`easytier`、`netspeedtest`、`netwizard`、`openlist2`、`quickfile`、`timecontrol`、`vnt`

停克隆**不影响任何固件产物**（本来就没编进去）。保留的克隆 = 真机确实在用的
（`argon`、`diskmanager`→mini-diskmanager、`partexp`、`h5000m-fancontrol`、
`h5000m-netmode`）+ 纵深防御用途的 `viking`（其内 sing-box/homeproxy 目录需被删除）。

**顺带清理二：移除 irqbalance 三件套（`irqbalance` / `luci-app-irqbalance` / 中文包）**

依据（真机 2026-09-21 实测）：irqbalance 对负载最大的两个中断**毫无作为** ——
无线 mt7996e（IRQ 79，186 万次）与 USB 5G 模组（IRQ 74）从未被迁移，它全程只动了
以太网两个中断（67→CPU1、68→CPU3）；且 `99-mt5700-net` 每次开机都把它停用，
属「编了也永远不跑」。硬中断亲和已由 `mt5700-smp` 接管。

配套删除的死代码 / 过时描述：
- `Files/etc/uci-defaults/99-mt5700-net` 第 3 节的「停用 irqbalance」逻辑（固件里已无该包）
- `.github/workflows/WRT-CORE.yml` 关键包自检列表里的 `irqbalance|luci-app-irqbalance`
  （否则会打印出 `=n` 的行，看起来像包还在）
- `99-mt5700-net` 第 4 节「配合上面的 irqbalance」→ 改为 mt5700-smp

`Files/etc/init.d/mt5700-smp` 里**运行时**停用 irqbalance 的逻辑**保留**：那不是死代码，
而是「用户日后自行安装时」的防护（两者同写 smp_affinity 会互相覆盖）。

## [2026-09-21] 以厂家固件为基准筛查优化项：conntrack 容量 / rpcd 无限重启

以 `Mwrt-H5000M-1139-24-20260921.bin` 为基准做了一轮全量取证（自行解析 squashfs，
偏移 `0x45DC00`，xz，7300 节点），逐项比对后筛出可搬的项。

**新增 `Files/etc/sysctl.d/99-mt5700-conntrack.conf`**
- `nf_conntrack_max` 63488 → **100000**（厂家 `/etc/sysctl.d/11-nf-conntrack.conf` 实测值）。
  表满时会静默丢新连接，日志只有一行 `table full, dropping packet`，极易误判成运营商问题。
- `buckets` **不改**：本机 6.18 实测可写，但写入会重建哈希表，63488 与 65536 只差 3%，不值当。
- `nf_conntrack_tcp_timeout_established = 7440` 显式写出（防止上游默认值漂移）。

**新增 `Files/etc/uci-defaults/99-mt5700-stability`**
- rpcd 改 `procd_set_param respawn 3600 5 0`（厂家 `99-be3600-fixups` 实测取证）。
  procd 默认一小时内崩 5 次就永久放弃，而 rpcd 一死连登录都拿不到 session，
  界面表现为「密码错误」——**密码从来没错**。改后约 5 秒自愈。
- 串口 AT 超时那条**只留注释不改代码**：本固件由 at-webserver 独占串口，不存在抢串口问题。

### 筛查中确认「两边一致、无需改」的项（避免重复劳动）

| 项 | 本机 | 厂家 | 结论 |
|---|---|---|---|
| dnsmasq cachesize / min_cache_ttl / use_stale_cache / ednspacket_max / nonegcache / authoritative / dns_redirect | 8000 / 3600 / 3600 / 1232 / 1 / 1 / 1 | 完全相同 | 都是 ImmortalWrt 上游默认，非厂家优化 |
| conntrack checksum / tcp_timeout_established / acct | 0 / 7440 / 1 | 相同 | — |
| tcp_fin_timeout / tcp_keepalive_time / kernel.panic / igmp_max_memberships | 30 / 120 / 3 / 100 | 相同 | — |
| zram swapon 优先级 | 100 | 相同 | — |
| fullcone | **已为 1** | 1 | 无需改（`nft_fullcone` 已加载、2 条规则在跑） |

### 确认不可搬的项（附证据）

- **闭源内核模块 vermagic = `6.6.94 SMP mod_unload aarch64`，本机 6.18.52** ——
  `insmod` 直接拒绝。依赖链 `mtk_warp→mtkhnat`、`mtk_wed→mtk_warp,mtk_hwifi`、
  `mt7992(3.9MB)→mt_hwifi,mt_wifi_cmn` 缺一不可。详见 README「闭源驱动」小节。
- **H5000M 的 LAN 是 `eth0 hnat`**（`board.d/02_network` 实测）——
  厂家把 hnat 虚拟接口桥进 LAN 才有 s2s（内网到内网加速）。本机无该驱动，s2s 无从谈起。
- HNAT 参数走 debugfs：`echo "7 <bind_rate>" > /sys/kernel/debug/hnat/hnat_setting`
  （**type 7 = bind_rate**，非此前记录的 11），`hook_toggle` 控制开关。本机无此目录。

## [2026-09-21] 四核调度：对照厂家实现重写中断亲和与 RPS

参照 **higowrt 固件的 `/sbin/smp.sh`**（`/etc/init.d/mtk_smp` 只是个壳，真正干活的是它）
重写了四核调度。厂家脚本按平台硬编码物理 IRQ（MT7990_whnat 分支：eth 221~224/229、
usb 204、wifi 237/238）并逐核绑定 —— **这些 IRQ 号属于 MTK 闭源驱动，在本机主线 mt76
上大部分不存在，直接照抄无效**，所以只借鉴其策略，实现改为动态匹配。

**三条实测发现（都是推翻原有认知的）**：

1. **`smp_affinity` 写成全核 `f` 不等于分摊。** 无线 IRQ 79 与 USB IRQ 74 的掩码一直是 `f`，
   计数却 100% 落在 CPU0（186 万次从未迁移）——单条 MSI 每次仍由内核选定的一个核响应。
   要搬走必须写**单核**掩码。
2. **IRQ 79（无线）的亲和根本不可写**：`echo 8 > /proc/irq/79/smp_affinity` 返回 RC=1，
   `affinity_hint=0`、`effective_affinity=0`，停掉 irqbalance 后重试同样失败。
   PCIe MSI 在驱动层没实现 `irq_set_affinity`，属硬件/驱动限制 —— **做不到完全均分**。
3. **RPS 应避开该接口的硬中断所在核**（这条来自厂家：有线 rps=0xe 排除 CPU0、
   无线 rps=0x7 排除 CPU3）。8 条并发流压测 12 秒的对比：

   | RPS 掩码 | CPU0 的 NET_RX 占比 | CPU0 的 softirq 占比 |
   |---|---|---|
   | `f`（全核） | 42% | **47.5%** |
   | `e`（排除 CPU0） | **15%** | **13%** |

**改动**：

| 文件 | 改动 |
|---|---|
| `Files/etc/init.d/mt5700-smp` | 重写：按中断负载贪心分配到最轻的核；**写入必须读回校验**（IRQ 79 那种静默失败不能再被当成成功）；补回厂家有依据的 `disable_gro_fraglist`；移除 RPS 逻辑（`stop()` 会清零 `rps_cpus`，那是 mt5700-rps 的成果） |
| `Files/etc/init.d/mt5700-rps` | 重写：无线接口的 RPS **动态排除无线硬中断所在核**（实测 CPU0 → 掩码 `e`），其余接口全核；XPS 保持全核 |
| `Files/etc/uci-defaults/99-mt5700-sys` | `mt5700-smp` 由默认不启用改为**默认启用** |
| `Files/etc/uci-defaults/99-mt5700-net` | irqbalance 由启用改为**停用**（与 mt5700-smp 互斥） |

真机验证（192.168.10.1）：清零 → 执行 → **CPU0=无线79 / CPU1=USB·5G 74 / CPU2=eth 68 /
CPU3=eth 67**，`phy0.1-ap0` 的 rps 自动设为 `e`，`rx-gro-list: off`；`stop` 可还原。

**踩到的两个 busybox 坑**（都会静默失效，已写进脚本注释）：
① `sort -k2,2nr` 连写不生效，必须拆成 `-k2 -n -r`；
② `sort -o` 写回同一个文件不生效（结果跑到 stdout，源文件保持未排序），须重定向后 `mv`。
## [2026-09-21] 四核负载均衡：RPS/XPS 改全核掩码（实测修复「四核平均分」未达成）

起因：真机体检发现「四核平均分」实际没做到，中断分布 cpu0=190 万 / cpu3=83 万。
本轮做了间隔采样的增量实测（累计值会误导），定位到两个层面：

**1. 硬件中断层面（无法解决，是硬件限制）**
- 无线 `mt7996e`（IRQ 79）累计 **121 万次、100% 落在 CPU0**；
  USB 5G 模组（IRQ 74）累计 2.9 万次、同样 100% 在 CPU0。
- irqbalance 全程只动了以太网的两个中断（67→CPU1、68→CPU3），**没碰无线和 USB**。
- 单个 MSI 中断只能绑一个核，硬件层面劈不开 —— 只能靠 RPS 在软件层面分流。

**2. 软件收包层面（本轮真正修掉的）**
- 固件默认的 `rps_cpus` 是**单核掩码**：`phy0.1-ap0`=4（CPU2）、`eth2`=8（CPU3）。
  单核掩码的含义是「把所有收包处理强制塞给一个核」。
- 根因：`Files/etc/uci-defaults/99-mt5700-net` 第 4 节写的是
  `if [ -f /etc/init.d/packet_steering ]; then enable; fi` —— 但真机
  `uci show network.globals` 里**没有 packet_steering 键**，等于没生效。
  OpenWrt 的 packet steering 是**由 uci 配置驱动**的，不是靠那个 init 脚本。

**改动**
- 新增 `Files/etc/init.d/mt5700-rps`（START=95）：开机后把所有接口的
  `rps_cpus` / `xps_cpus` 强制设为全核掩码（4 核 → `f`），并等 `br-lan` 就绪最多 20 秒。
  它只写 `/sys/class/net/*/queues/*/{rps,xps}_cpus`，**不碰 `smp_affinity`**，
  因此与 irqbalance 不冲突（irqbalance 只写 smp_affinity）。
- `99-mt5700-net` 第 4 节改为显式 `uci set network.globals.packet_steering='1'`
  + 启用 `mt5700-rps` 兜底。
- `Scripts/Packages.sh` 增加 `mt5700-rps` 存在性硬断言（缺了会静默失效，不报错）。

**实测效果**（8 条并发 TCP 流、12 秒窗口）

| | 单核掩码（修复前） | 全核掩码 f（修复后） |
|---|---|---|
| NET_RX 软中断分布 | CPU2 **95%**，其余≈0 | **CPU0 37% / CPU1 27% / CPU3 36%** |
| softirq CPU 时间 | 112 jiffies **全压一个核** | **109 / 80 / 94 分散到三核** |

真机试跑验证：把 RPS 清零后执行脚本 → 8 个接收队列 + 64 个发送队列全部设为 `f`，
日志 `RPS/XPS 已设全核掩码 0xf（4 核）`；`stop` 归 0、`start` 可恢复。

**⚠️ 两个验证方法上的坑（否则会得出错误结论）**
1. **必须用多条并发流压测**：RPS 按 flow hash 选核，同一条 TCP 流的所有包
   必然落在同一个核（这是 RPS 为避免乱序的设计）。单流压测时 CPU0 会占到 92%，
   看起来像「全核掩码反而更差」，实际是测试方法的问题。
2. **rc.common 脚本不能直接 `sh script start`**：那样只会定义函数而不执行它，
   `start` 的调度依赖 shebang `#!/bin/sh /etc/rc.common`。
   正确写法是 `sh /etc/rc.common /path/script start` 或直接执行文件。

## [2026-09-21] TTL 绕过实测落地：flow offload 默认关闭（真机 A/B 实证）

### 结论先行

固件自带的 TTL 统一规则（`Files/etc/nftables.d/12-mangle-ttl-128.nft`）**必须配合关闭
flow offload 才生效**。此前两者并存，规则形同虚设、客户端实际上不了网。本轮真机 A/B
实测后把默认改为 `off`，并在 `auto` 分支加了自动判定。

### 真机证据（H5000M / kernel 6.18.52，客户端 192.168.10.202）

| | flow offload 开 | flow offload 关 |
|---|---|---|
| 客户端 HTTP | **25s 超时，0 字节** | **HTTP 200 / 1.02s / 2381B** |
| conntrack | `[OFFLOAD]` 标记；正向 10 包/951B，**反向仅 1 包/52B**（只有 SYN-ACK） | 无 OFFLOAD；进出各 13 包 |
| postrouting 计数器 | `packets 0` —— 规则一个包都没处理 | 正常计数 |
| 出口 TTL | 未改写 | `IN=br-lan OUT=eth2 ... TTL=128` |

抓包日志（关闭卸载后，eth2 出口）：

```
TTLFIN IN=br-lan OUT=eth2 SRC=100.76.8.240 DST=111.45.11.5 ... TTL=128 ... SPT=62258 DPT=80
```

### 一并结案的两个悬而未决项

- **5G 模组会不会把 TTL 改回去** → **不会**。模组虽再做一层 NAT（eth2 = 100.76.8.240/8，
  CGNAT），但出口实测 TTL 仍是 128，SNAT 重建 IP 头后沿用写入值。
- **IPID 指纹（博客提到的第三个检测维度）** → 本拓扑天然不存在。SNAT 重建 IP 头后
  IPID 由路由器统一生成（实测 12678/12679/12680 递增），`kmod-rkp-ipid` 更无必要。

### 改动

1. `Files/etc/mt5700/flow-offload`：`MODE=auto` → `MODE=off`
2. `Scripts/ApplyFlowOffload.sh`：默认 `${WRT_FLOW_OFFLOAD:-auto}` → `off`
3. 三个 workflow 的 `FLOW_OFFLOAD` input `default: 'auto'` → `'off'`
   （`WRT-CORE` / `WRT-BUILD` / `H5000M-MT-AUTO`），同步更正描述与注释
4. `Files/etc/uci-defaults/99-mt5700-net`：`auto` 分支新增 TTL 规则探测 ——
   只要 `/etc/nftables.d/*.nft` 含 `ip ttl set` 就关闭卸载（优先级高于 SQM 判定），
   保证用户手选 `auto` 时也不会踩坑
5. `12-mangle-ttl-128.nft`：注释里两条「存疑」改为实证结论，并补验证方法

### 代价（如实说明）

关闭软件卸载后转发全部走 CPU。本机型四核 MT7987A，5G 实际速率下未见瓶颈，
但未做满速压测。**若要峰值吞吐，可在构建时显式选 `on`，代价是 TTL 统一失效。**

## [2026-09-21] 全项目审计：设备选择硬断言 / 5G 接口 DNS / 缓存与克隆稳定性 / 文档纠偏

### 背景

上一轮只补了固件调优项。本轮按「先完整分析项目、再优化」把 CI 工程层与文档整体过了一遍，
只改两类东西：**会静默出错**的，和**与实际配置不符**的。固件调优部分保持不动。

### 修复 —— 三处「错了但不报错」

1. **设备选择会被 kconfig 静默丢弃**
   - `Config/H5000M-WIFI-YES.txt` 原来同时写 `CONFIG_TARGET_MULTI_PROFILE=n` 与
     `CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_hiveton_h5000m=y`，而
     `scripts/target-metadata.pl` 生成的 Kconfig 里是
     `menu "Target Devices" depends on TARGET_MULTI_PROFILE`
     —— MULTI_PROFILE=n 时整个菜单不可见，那行设备选择直接被丢弃，
     编译目标退回平台默认 profile：**编出别的机型的固件而 CI 全程全绿**。
     （实测 2026-09-15：`make defconfig` 会把 MULTI_PROFILE 改回 y，属于「碰巧对」。）
   - 改：机型配置改 `=y` 并写明源码依据；`Config/PRIVATE.txt` 里那行实测无效的 `=n` 删除；
     `WRT-CORE.yml` 在 `make defconfig` **之后**加硬断言 —— 至少一个
     `CONFIG_TARGET_DEVICE_*=y`，`CONFIG_TARGET_ALL_PROFILES=y` 时告警。
2. **5G 接口会收下国内不可达的 DNS**（真机事故复现路径）
   - `Files/etc/uci-defaults/99-mt5700-wan` 建接口时写的是 `peerdns='1'`，
     而 5G 模组（CGNAT 段 100.0.0.0/8）在 DHCP 里下发的是 `8.8.8.8 / 8.8.4.4`，
     国内不可达。客户端每解析一个冷域名都要先等这一路超时，
     表现为「WiFi 连上了、信号满格，但就是没网」（2026-09-21）。
   - 改：新建接口直接 `peerdns='0'` + `dns='223.5.5.5 119.29.29.29'`；
     接口已存在（升级而来）时**仅在用户没有自定义 DNS** 的前提下补同样的设置，不覆盖用户配置。
3. **`Scripts/Settings.sh` 的 sed 会静默失效**
   - `sed -i "..." $(find ...)` 在 find 无结果时退化成「从 stdin 读」，返回码仍是 0
     —— 主题 / 登录 IP / 状态页编译日期标记没改但 CI 看不出来，等刷完机才发现。
   - 改：统一走 `EDIT_FILES` 包装，找不到目标文件直接 `::error::` + exit 1。

### 稳定性

4. **缓存 key 去掉源码 commit hash**，改为按 ISO 周滚动（`WRT_CACHE_WEEK`）。
   原来是 `…-${WRT_HASH}`：上游每来一个新提交就多存一份内容几乎相同的缓存
   （工具链 ~1GB + ccache 上限 5G），几天就能撑满 10GB 配额 → GitHub 按 LRU 整批淘汰 →
   「冷编译 → 超时被杀 → 没缓存 → 更冷」的死循环。按周滚动后每周最多一份；
   注意同 key 已存在时 actions/cache 是**跳过保存**而非覆盖，所以一周内保持周初那份。
5. **`Scripts/Packages.sh` 克隆重试 3 次**（间隔 5s，重试前清掉残留目录）。
   GitHub 对 CI 出口 IP 的限流（403 / early EOF）是偶发的；
   单次失败就 exit 1 会让几小时的构建白跑。残留目录不清会让下一次克隆
   直接以 "destination path already exists" 失败，重试等于白试。
6. **`H5000M-MT-AUTO` 只在 Auto-Clean 成功后才编译**：
   `workflow_run` 的 `completed` 同时包含 success / failure / cancelled，不判断的话
   清理失败（如 API 限流）之后仍会照跑一次几小时的编译，而产物很快又被下次清理删掉。

### 文档纠偏（原描述与实际配置不符）

7. Release 说明里「这是个平台固件包，内含多个设备」+「全系带开源硬件加速」→
   改为「只含 Hiveton H5000M 一个设备（单 profile）」+「加速仅软件 flow offload，
   硬件卸载默认关闭（本基线无 mtkhnat / mtk_wed），完整取舍见
   `FIRMWARE_OPTIMIZATION_REPORT.md`」。
8. README：平台写错（MT7986 → 本设备实际是 **MT7987A**）；
   MT5700 插件段删掉 `ubus-at-daemon` / `sms-tool_q` 的描述
   （方案 B 是单包自含，CI 对这两个包显式 =n 并做互斥校验）；
   项目结构补全 `Files/etc` 下新增的 4 个调优文件；
   Auto-Clean 的默认行为写清（默认**全部清空**，手动勾选才保留每机型最新一个）。
9. `99-mt5700-wan` 的兜底列表移除 `mt5700-watchdog`
   —— 该看门狗已在 MT5700 Console 2.3.25 彻底删除，留着只是个永远匹配不到的空名字。

## [2026-09-21] 系统层优化：四核调度 / zram 内存压缩交换 / LAN 二层互通

### 背景

以参考固件（Hiveton H5000M 上的 Mwrt，`192.168.88.1`）为对照做实测取证，它有四项本仓库没有的能力：

| 能力 | 参考固件实测 | 本仓库（官方 immortalwrt master） |
|---|---|---|
| 四核 IRQ/RPS 均摊 | `mtk-smp`（`/sbin/smp.sh` + `/etc/init.d/mtk_smp`） | 无，只有 irqbalance |
| 内存压缩交换 | `zram0` ≈ 494MB，算法 `lzo` | 无 |
| MLO 跨射频 ARP 代答 | 可用 | 未开 |
| 无线客户端互通 | `isolate` 未设置（=0） | 未显式约束 |

本次把四项补齐，并顺带把 NTP 换成国内服务器。

### 新增

1. **`Files/etc/init.d/mt5700-smp`** —— 四核均衡调度服务（**备选方案，默认不启用**）
   - 中断轮询绑定到 CPU0..CPU3；RPS/XPS 摊到全核；关闭 GRO fraglist
   - **不硬编码 IRQ 号**：按 `/proc/interrupts` 的设备名动态匹配。
     mtk 闭源驱动常见 237/245，主线 mt76 是另一套，写死必然失效
2. **`Files/etc/uci-defaults/99-mt5700-sys`** —— 首次开机配置
   - zram 512M + 算法 `lzo`；无线 `isolate=0`；**保持 irqbalance**、`mt5700-smp` 不启用（备选）；NTP 换国内
3. **`Files/etc/sysctl.d/99-mt5700-lan.conf`** —— `proxy_arp_pvlan=1`
4. **`Files/etc/nftables.d/12-mangle-ttl-128.nft`** —— WAN 侧出包 TTL / Hop Limit 统一为 128
   （防共享上网检测，见文末专节）

### 变更

- `Files/etc/uci-defaults/99-mt5700-net`：irqbalance **保持启用**（与 packet steering 配套＝四核均摊）；
  静态中断绑定的 `mt5700-smp` 作备选、**默认不启用**（两者都写 `smp_affinity`，互斥）
- `Scripts/Packages.sh`：`INSTALL_NET_TUNING()` 补 `chmod 0755 etc/init.d/*`
  （git 不保存 exec 位，不补则 init 脚本开机不会被执行）
- `Config/GENERAL.txt`：`CONFIG_PACKAGE_zram-swap=y`
- `.github/workflows/WRT-CORE.yml`：关键包自检加入 `zram-swap`
- `Scripts/Packages.sh`：`INSTALL_NET_TUNING()` 注入后新增 `.nft` 缺失硬断言
  （`.nft` 语法错 → fw4 加载失败 → 刷完没网，不能静默放过）

### 两个易踩的坑（已规避，勿改回）

1. **zram 的 init 脚本名是 `/etc/init.d/zram`，不是 `zram-swap`**
   —— `package/system/zram-swap/Makefile` 里写的是
   `$(INSTALL_BIN) ./files/zram.init $(1)/etc/init.d/zram`。
   真机 `/etc/init.d/` 下只有 `zram`。写错名字会导致整段配置被静默跳过。
   脚本已同时探测两个名字以兼容不同版本。
2. **压缩算法固定 `lzo`** —— OpenWrt 的 `zram.init` 注释明写
   "default to lzo, which is always available"，这是唯一保证存在的算法。
   `lzo-rle` / `zstd` 需先 `cat /sys/block/zram0/comp_algorithm` 确认内核支持。

### 新增：WAN 侧出包 TTL 统一（防共享上网检测）

来源：[《OpenWrt 预防校园网多设备检测配置》](https://www.cnblogs.com/z-addone/p/19855795)。
不同系统的初始 TTL 不同（Windows 128 / Linux·Android 64），逐跳递减后出口侧会同时出现
63/64/127/128 等多种值，DPI 据此判定「出口后面挂了多台设备」。5G CPE 共享上网属同一类检测。

新增 `Files/etc/nftables.d/12-mangle-ttl-128.nft`：
`type filter hook postrouting priority 300` + `oifname $wan_devices ip ttl set 128`。

**没有照抄原方案的两处**：

1. **接口名不能用 `"wan"`** —— 原方案是 x86 软路由的习惯命名。本机 `fw4 print` 实测
   `define wan_devices = { "eth1", "eth2" }`（eth1 有线 WAN、eth2 5G 模组），写死 `"wan"`
   一条都匹配不上、规则会静默失效，故改用 fw4 生成的 `$wan_devices` 宏。
   宏可见是因为 `include "/etc/nftables.d/*.nft"` 位于 `table inet fw4` 内且在 define 之后；
   已在真机 `fw4 print | nft -c -f -` 校验通过（只检查语法，未加载、未重启防火墙）。
   ⚠️ `nft list ruleset` **看不到** define（宏已展开），验证宏必须用 `fw4 print`。
2. **128 这个值没有厂家参考值可抄** —— 参考固件的 `/etc/config/firewall` 里有
   `config include 'qmodem_ttl'` 指向 `/etc/firewall.d/qmodem_ttl`，但该文件不存在
   （`fw4 print` 报 `unreachable path ... ignoring`），厂家的 TTL 功能实际未生效。

**两个已知前提（待拍板，未擅自处理）**：

- 与默认开启的**软件 flow offload 冲突**：快转连接绕过 nftables（与 UA2F 必须关卸载同理）。
  要 TTL 稳定生效需关 `flow_offloading`，代价是失去软件卸载加速，二者只能选一个。
- **5G 侧（eth2）效果未验证**：参考固件 `wan_subnets = 100.0.0.0/8` 是 CGNAT，模组自身还做一层
  NAT；路由器改完的 TTL 会不会被模组重建 IP 头时重置，需抓包确认。eth1 有线 WAN 一定生效。

**IPID（kmod-rkp-ipid）：已备好但默认不编译**（2026-09-21「一切以稳定为主」决策）：

- 上游 `CHN-beta/rkp-ipid` 已 archived、最后提交 2020-10-21，是**树外内核模块**，
  对 6.18 内核没有兼容性保证：编不过＝整次构建失败（几小时机时）；
  编过了若在新内核上 OOPS＝整机重启。风险高于收益。
- 该模块还只处理带 `mark 0x10`（`mark_capture` 模块参数）的包，**装上默认不改写任何流量**，
  要生效还需一条给出方向包打 mark 的防火墙规则，本仓库未加。
- 故 `Config/GENERAL.txt` 写 `# CONFIG_PACKAGE_kmod-rkp-ipid is not set`，
  `Scripts/Packages.sh` 里 `UPDATE_PACKAGE "rkp-ipid" ...` 保持注释。
  能力保留在仓库里，需要时两处同时打开即可。

UA2F 按「只加编译项」的要求**未加**。

### 未做：mtkhnat 的 s2s（内网到内网转发）

`uci set mtkhnat.global.s2s='1'` 本轮**没有落地**，原因是实测三条证据：

1. 参考固件 `uci show mtkhnat` → `Entry not found`，且无 `/etc/init.d/mtkhnat`；
   其 `mtkhnat.ko` 里 `strings | grep s2s` 无结果
2. 参考固件的 hnat 走 debugfs（`echo [type] [option] > /sys/kernel/debug/hnat/hnat_setting`，
   已知 type 8=IPv6、11=bind_rate、12=macvlan），没有 UCI 配置层
3. 本仓库用官方 `immortalwrt/immortalwrt` master，`target/linux/mediatek/files/.../mtk_hnat` 不存在

补充：Hiveton 的 higowrt 文档提到 OpenWrt 25.12 起主线自带 mtkhnat 内核 patch
（`999-274x`，`CONFIG_NET_MEDIATEK_HNAT=m`），但它与 `Files/etc/uci-defaults/99-mt5700-net`
里为 SQM/CAKE 而**关闭 flow offload** 的策略直接冲突——硬件加速会绕过 qdisc，
CAKE 整形失效。若要 s2s，需先决定放弃 CAKE，属另一次权衡。

另有资料指出 mt798x 每 PPE 仅 16K entry，开 s2s 会让 LAN 内网流量挤占条目、
削弱 WAN 加速，家用场景不推荐。

### 验证（真机 dry-run，未写入、未 commit）

在参考固件（H5000M，4 核）上跑通：

```
ncpu=4  mask_all=f
irq=66 cpu=0  15100000.ethernet     irq=77 cpu=1  mt7992-vec_data0
irq=67 cpu=1  15100000.ethernet     irq=79 cpu=2  xhci-hcd:usb1
irq=68 cpu=2  15100000.ethernet     irq=84 cpu=3  mt7992-wed
irq=69 cpu=3  15100000.ethernet
irq=71 cpu=0  15100000.ethernet
合计 8 个中断参与轮询绑定；rps 队列 13 / xps 队列 58；ethtool 可用
zram init 探测命中 /etc/init.d/zram
```

`sh -n` 语法检查：`mt5700-smp`、`99-mt5700-sys`、`99-mt5700-net` 全部通过。
## [2026-09-19] 三条硬需求落地（flow offload 可见配置 / sing-box 断言 / 产物保留 sha256sums）

对应 Orchestrator 提案（proposer）P01–P20。取舍与未采纳项见 `FIRMWARE_OPTIMIZATION_REPORT.md`。

### flow offload 可见配置（P01/P02/P03）
- 新增 `Scripts/ApplyFlowOffload.sh`：构建期把 `WRT_FLOW_OFFLOAD`（auto/off/on/on-hw，默认 auto）写入固件覆盖层
  `wrt/files/etc/mt5700/flow-offload`；非法值编译期 `::error::` + `exit 1`。
- `WRT-CORE.yml` 新增 `WRT_FLOW_OFFLOAD` input（默认 auto，保证老调用方不传也能跑）+ env；`WRT-BUILD.yml` /
  `H5000M-MT-AUTO.yml` 增加 `FLOW_OFFLOAD` 选项并透传。
- `Files/etc/uci-defaults/99-mt5700-net` 读取 `/etc/mt5700/flow-offload` 决策矩阵（auto+SQM关→软卸载；
  auto+SQM开→关；off→关；on→软；on-hw→软+硬），SQM 扫描永远执行（红线2 互斥判定保留）。
- 默认文件 `Files/etc/mt5700/flow-offload`（MODE=auto）保证脚本不跑时也是 auto。
- `Config/GENERAL.txt` 显式 `CONFIG_PACKAGE_luci-app-firewall=y`，确保「页面上改」的防火墙页存在。

### sing-box 彻底不编（P04/P05）
- `Config/GENERAL.txt` 显式写死 `CONFIG_PACKAGE_sing-box=n` / `luci-app-homeproxy=n` / `luci-i18n-homeproxy-zh-cn=n`
  （沿用既有 =n 风格，而非只留注释），防将来被别的包反向依赖拉回。
- 新增 `Scripts/VerifyNoSingBox.sh` 做编译前（.config）+ 编译后（manifest）两道硬断言；`WRT-CORE.yml` 在
  `make defconfig` 后加 `pre` 步骤、在产物 manifest 读取后（iregex 删除前）加 `post` 步骤。
- 口径：硬需求「sing-box 内核彻底不编」指的是**不进固件**；`VerifyNoSingBox(post)` 只查 `bin/targets/*/*.manifest`
  （最终进固件的包清单），`bin/packages` 下的 ipk 仓库不在断言范围内（pre 阶段的 `viking` 克隆树清理见 `Packages.sh` P06）。

### 产物与健壮性（P09/P10/P15/P16 等）
- 产物保留 `sha256sums`（P10）：`WRT-CORE.yml` 的 iregex 删除规则去掉 `sha256sums`。
- `WRT_TARGET` / 产物改名 `NAME` 取值失败即 `::error::` + `exit 1`（P09）。
- 初始化脚本 `curl` 失败不再静默成功（P15）。

## [2026-09-19] 软件页安装默认允许未签名包

- `Handles.sh` 新增一段：给 `luci-app-package-manager` 的 `/usr/libexec/package-manager-call`
  在 **install**（apk 下映射为 `add`）时默认追加 `--allow-untrusted`，
  最终命令形如 `apk --allow-untrusted add <pkg>`
- 动机：自编译出来的 apk 不带仓库签名，原先在「系统 → 软件」页点安装会被签名校验挡下，
  错误信息只有一句 untrusted
- **只改后端脚本**：前端 `package-manager.js` 不管传什么参数都会被脚本参数解析的
  `-*)` 分支 shift 丢弃（apk 分支只认 `--force-removal-of-dependent-packages` 与
  `--force-overwrite`），改前端无效
- 追加到 `cmd` 而非 `$@`：`--allow-untrusted` 是 apk 的全局选项，放在子命令前才一定生效
- 仅作用于 apk 的 `add`：opkg 默认不校验包签名故不加；`update` / `upgrade` / `remove` 保持原样
- 幂等：文件已含 `allow-untrusted` 时跳过，重复执行不会叠加

### 其它
- `WRT-BUILD` 的 `TEST` 默认值由 `true` 改为 `false`：手动触发通常就是要出固件，
  默认的 `true` 只生成 `.config`，跑完没产物容易误以为失败（README 同步）
## [2026-09-18] 收敛为 H5000M 单产物 + 网络加速 / 稳定性优化

只保留 `H5000M-WIFI-YES-MT5700-immortalwrt-master` 一套产物，并按真机实测重排加速策略。
完整取舍与未采纳项见 `FIRMWARE_OPTIMIZATION_REPORT.md`。

### 产物收敛
- 删除 `AP3000M-MT-AUTO.yml` / `X86-MT-AUTO.yml` 及 `Config/AP3000M.txt`、`Config/X86.txt`、`Config/MT5700M.txt`
- 删除 `AP3000M-EEPROM/`、`Scripts/inject_airpi_prebuilt.py`、`Scripts/homeproxy/`、`Scripts/patches/dockerd/`
- `WRT-CORE.yml` 删除 AP3000M 专用的 Rust 预编译步骤（省 1.5~3 小时机时）
- `WRT-BUILD.yml` 机型/源码/MT 模式选项各收敛为一项
- `Handles.sh` 删除四段死代码：HomeProxy 资源预置 + ucode 修复、aurora 样式、AP3000M EEPROM、dockerd 修补
- `Packages.sh` 去掉 aurora 克隆、HomeProxy 版本约束改写、airpi 克隆
- MT5700M 分支在 ApplyMTMode / VerifyMTMode 中保留为守卫：配置已删，误选会明确报错终止

### 版本标识
- 新增 `WRT_MARK`（默认 `OWrt`），状态页尾缀由 `woshinibabao1-…` 改为 `OWrt-…`

### 插件
- 装：`luci-theme-argon` + `luci-app-argon-config` + 中文包、`luci-app-openclash` + 中文包
- 装：`dnsmasq-full`（OpenClash 的 nftset/ipset 分流依赖它，替换默认 dnsmasq）
- **补回** `luci-app-mosdns`：真机在用但配方已丢，不补回来下次刷机即功能回退
- 卸：homeproxy / easytier / gecoosac / wolultra / samba4 / upnp / aurora（主题 + 配置页）
- 卸：`sing-box`（HomeProxy 走后成孤儿，只剩内核无界面）

### 加速与稳定性（真机实测依据，见报告第一节）
- **默认开启软件 flow offload**：原先无条件关闭。改为「SQM 未启用则开、启用则关」，
  二者互斥（被卸载的连接绕过 qdisc，CAKE/HTB 会失效）
- 硬件卸载（`flow_offloading_hw`）保持关闭：本基线无 `mtk_wed`，5G WAN 又是 USB CDC-NCM，
  PPE 管不到，开了命中率≈0 且会让 nft 计数器看不到流量
- 首次开机脚本显式兜底 packet steering
- sysctl 补三项：TCP Fast Open、`somaxconn`/`tcp_max_syn_backlog` 1024、`rp_filter=0`（双出口非对称路由）
- `Config/GENERAL.txt` 显式声明 `kmod-nf-flow`、`kmod-crypto-hw-safexcel`

### 未采纳（避免负优化，理由详见报告第三节）
- turboacc / SFE / shortcut-fe：与 nf_flow_table 抢 hook，6.18 + Filogic 上编不过或随机断流
- `mtk_hnat`：mtk-openwrt-feeds 树外驱动，本基线无此 .ko，且与主线 PPE 抢同一张硬件表
- WED / zram / backlog 放大 / 锁频：均需真机验证或有明确负收益

## [2026-09-15] 修复 luci-app-homeproxy 的 sing-box 版本约束导致的构建失败

### 故障现象

- 2026-09-15 定时触发的 `H5000M-MT-AUTO`、`X86-MT-AUTO`、`AP3000M-MT-AUTO` 全部失败，`Compile Firmware` 步骤终止，`make world` 整体中断。09-13 同样配置构建成功。
- 第一层错误签名（`package/install` 阶段，Error 3）：
  ```
  ERROR: unable to select packages:
    sing-box-1.15.0_alpha3-r1:
      breaks: luci-app-homeproxy-20260914-r2[sing-box>=1.15.0]
      satisfies: world[sing-box]
  ```

### 根因

1. 上游 `VIKINGYFY/packages` 的 `luci-app-homeproxy` 升级到 `20260914-r2`，新增 `LUCI_EXTRA_DEPENDS:=sing-box (>=1.15.0)`。
2. 同一 feed 的 `sing-box` 为 `1.15.0_alpha3`。apk 版本比较规则中 `_alpha3` 属 pre-release 后缀，排在「无后缀」之前，故 `1.15.0_alpha3 < 1.15.0`，依赖不可满足。
3. 上游 `SagerNet/sing-box` 当前最新稳定版是 v1.14.1，1.15.0 系列仍为 alpha（alpha.4 于 2026-09-15 发布），**不存在**可升级到的 1.15.0 正式版，因此只能调整约束而非升级 sing-box。
4. `Config/GENERAL.txt` 对全机型启用 homeproxy，故三个机型工作流同时受影响。

### 关键约束（决定修复方式）

- 首次尝试「删掉版本约束」不可行：OpenWrt 的 apk 打包器 `include/package-pack.mk` 要求 `EXTRA_DEPENDS` 每一项必须是「包名 + 空格 + 版本约束」，无约束会直接报错并终止：
  ```
  luci.mk:398: *** "Extra dependencies must have version constraints. sing-box seems to be unversioned.".  Stop.
  ```

### 修复

- `Scripts/Packages.sh` — 新增 `FIX_HOMEPROXY_SINGBOX`（模式与既有 `FIX_QMODEM_VERSION` 一致），在克隆 viking feed 之后执行：
  1. 读取同一 feed 内 `sing-box/Makefile` 的实际 `PKG_VERSION`；
  2. 仅当约束下限在 apk 语义下**高于**该实际版本时才改写 `LUCI_EXTRA_DEPENDS` 的 sing-box 版本下限（主版本段相同但 feed 为 pre-release、或 feed 主版本段更高时不动，避免收紧已满足的约束或写反语义）；
  3. 版本串做字符白名单校验（`[0-9A-Za-z._-]`），防止脏数据进入 sed 表达式；
  4. 幂等，上游发布 1.15.0 正式版或调整约束后自动跳过。

### 验证

- 用上游真实 `luci-app-homeproxy/Makefile` 与真实 `sing-box` 版本，模拟 CI 目录结构实测 6 种边界场景：需下调（改写）、约束已满足（不动）、约束等于 feed 版本（不动）、feed 为正式版（不动）、无约束（跳过）、feed 版本更高（不动）——行为均符合预期。
- `bash -n` 语法检查通过；首轮修复后重跑构建，`unable to select packages` 已消失，失败点前移至后续的 `luci.mk` 校验，据此完成第二轮修正。

### 变更文件

- `Scripts/Packages.sh` — 新增 `FIX_HOMEPROXY_SINGBOX` 修复函数并在 `UPDATE_PACKAGE "viking"` 之后调用

## [2026-09-13] 云编译双 MT 配置并行、工作流重命名与产物区分

### 变更（云编译）

- **双配置并行**：各机型 AUTO 工作流改为矩阵同时编译 `MT5700` + `MT5700M`（`fail-fast: false`），Job 名为 `机型-MT模式`。
- **工作流重命名**：
  - `H5000M-AUTO.yml` → `H5000M-MT-AUTO.yml`（name: `H5000M-MT-AUTO`）
  - `AP3000M-AUTO.yml` → `AP3000M-MT-AUTO.yml`（name: `AP3000M-MT-AUTO`）
  - `OWRT-ALL.yml` → `X86-MT-AUTO.yml`（name: `X86-MT-AUTO`）
- **产物区分（WRT-CORE）**：
  - 固件文件名嵌入 MT 模式：`…-<MT5700|MT5700M>-wifi-yes-….bin`
  - 配置导出：`Config-<机型>-<MT模式>-….txt`
  - Release Tag：`<机型>-<MT模式>-<源码>-<分支>-<日期>`
  - Release 正文增加 `MT模式` 字段

### 变更文件

- `.github/workflows/H5000M-MT-AUTO.yml` — 新增（替代 H5000M-AUTO）
- `.github/workflows/AP3000M-MT-AUTO.yml` — 新增（替代 AP3000M-AUTO）
- `.github/workflows/X86-MT-AUTO.yml` — 新增（替代 OWRT-ALL）
- `.github/workflows/H5000M-AUTO.yml` / `AP3000M-AUTO.yml` / `OWRT-ALL.yml` — 删除
- `.github/workflows/WRT-CORE.yml` — WRT_MT 标签写入产物名 / Tag / 说明

## [2026-09-13] 重构 MT5700M 配置，新增独立 MT5700 配置与 MT_MODE 互斥

### 变更（配置架构）

- **原 MT5700M 配置迁移**：`Config/GENERAL.txt` 中的 MT5700M 段（`luci-app-mt5700m` / `luci-i18n-mt5700m-zh-cn` / `ubus-at-daemon` / `sms-tool_q`）整体迁出为 `Config/MT5700M.txt`，`Packages.sh` 的 `FOLD_MT5700M` 逻辑保留并改为仅在 `MT_MODE=MT5700M` 时执行。
- **新增 `Config/MT5700.txt`**：方案 B，仅 `luci-app-mt5700` + 中文语言包，不含 `sms-tool_q` / `ubus-at-daemon` / `luci-app-mt5700m`。
- **新增 `MT_MODE` 独立配置层**（全机型复用，不绑定 H5000M）：
  - `""` / `NONE` — 不安装任何 MT 插件
  - `MT5700` — 仅 luci-app-mt5700
  - `MT5700M` — luci-app-mt5700m + sms-tool_q + ubus-at-daemon
  - 其他值在 `Packages.sh` / `ApplyMTMode.sh` / `VerifyMTMode.sh` 中 `::error::` 并终止
- **双重互斥校验**：
  - 配置生成前：`Scripts/ApplyMTMode.sh` 叠加配置层并写入对侧包 `=n`
  - 配置生成后、编译前：`Scripts/VerifyMTMode.sh` 检查最终 `.config`
- **Workflow**：`WRT-CORE.yml` 增加 `MT_MODE` 输入；`WRT-BUILD.yml` 增加模式选择；`H5000M-AUTO` / `AP3000M-AUTO` / `OWRT-ALL` 默认 `MT_MODE=MT5700M`，保持原固件内容。

### 真实冲突点（来自插件仓库实测，非猜测）

- 同路径 init 服务：`/etc/init.d/at-webserver`
- 同路径 UCI：`/etc/config/at-webserver`
- 同菜单父节点：`admin/modem`
- MT5700M 另依赖 QModem feed 的 `sms-tool_q`、`ubus-at-daemon`；MT5700 的 `LUCI_DEPENDS` 为空，单包自含 Rust 后端

### 变更文件

- `Config/MT5700M.txt` — 新增（由 GENERAL 迁出）
- `Config/MT5700.txt` — 新增
- `Config/GENERAL.txt` — 移除 MT5700M 包
- `Scripts/ApplyMTMode.sh` — 新增
- `Scripts/VerifyMTMode.sh` — 新增
- `Scripts/Packages.sh` — MT 插件克隆/折叠按 MT_MODE 条件执行；QModem feed 仅 MT5700M 需要
- `.github/workflows/WRT-CORE.yml` — 增加 MT_MODE 输入与验证步骤
- `.github/workflows/WRT-BUILD.yml` — 增加 MT_MODE 选择
- `.github/workflows/H5000M-AUTO.yml` / `AP3000M-AUTO.yml` / `OWRT-ALL.yml` — 传入 MT_MODE=MT5700M

## [2026-09-10] 修复 QModem 包版本号非法导致的构建失败（apk Error 99）

### 修复（构建）

- **问题**：今日（09-10）三连发构建（OWRT-ALL #68 / H5000M-AUTO #24 / AP3000M-AUTO #18）全部在 `Compile Firmware` 步骤失败。根因：`Scripts/Packages.sh` 克隆的 QModem feed（`FUjr/QModem`）共享 `version.mk` 声明 `QMODEM_VERSION:=3.4.0-rc.3`，OpenWrt 新版 apk 打包器不接受 `-rc.N` 版本段——版本串被拼成 `3.4.0-rc.3-r1` 后，`apk mkpkg` 报 `package version is invalid`（Error 99），`sms-tool_q` 打包失败进而终止整个固件构建。三目标共享 `Config/GENERAL.txt`（`CONFIG_PACKAGE_sms-tool_q=y`），全部命中，编译脚本首败（rc=2）自动重试后仍被同一版本号拒绝。
- **修复**：`Scripts/Packages.sh` 在克隆 QModem feed 后新增 `FIX_QMODEM_VERSION`，将 `X.Y.Z-rc.N` 改写为 apk 合法的 `X.Y.Z_rcN`（`3.4.0-rc.3` → `3.4.0_rc3`）。QModem 各包源码均内嵌 feed 仓库 `src/`，无版本化下载依赖，改写仅影响版本元数据；上游若已改为合法版本则自动跳过。

### 变更文件

- `Scripts/Packages.sh` — 新增 `FIX_QMODEM_VERSION`（克隆 QModem 后改写共享版本号）

## [2026-09-09] 修复 luci-app-mt5700m 集成：折叠 Rust 后端与 WebUI

### 修复（插件）

- **问题**：此前 `luci-app-mt5700m` 的集成存在两处错误，导致编译出的固件里 MT5700M 管理页缺少 AT 后端、无法正常使用：
  - `Scripts/Packages.sh` 把 `mt5700webui-openwrt-server/at-webserver`（Rust 源码 crate，**没有 OpenWrt Makefile**）当作独立包 `mv` 进 `package/`，并在 `Config/GENERAL.txt` 写了 `CONFIG_PACKAGE_at-webserver=y`。但 OpenWrt buildroot 不会把它识别为软件包，于是 `/usr/bin/at-webserver`（及其软链 `/usr/sbin/mt5700m-at`）与 `/www/5700` WebUI 根本不会被编进固件——管理页的 AT 终端、拨号、状态查询全部失效。
  - `Config/GENERAL.txt` 误加 `CONFIG_PACKAGE_sms-tool=y`（该包来自 packages feed，与本插件无关）；插件真正依赖的是 QModem 的 `sms-tool_q` 与 `ubus-at-daemon`。
- **修复**：复刻上游 `scripts/build-release.sh` 的「折叠」流程，在 `Scripts/Packages.sh` 新增 `FOLD_MT5700M`：
  - 把 LuCI 壳（仓库内同名子目录）提升到 `package/` 一级；
  - 按编译目标用 cargo + rust-lld（自包含 musl，无需 OpenWrt 交叉工具链）交叉编译 Rust 后端 `at-webserver`：mediatek → `aarch64-unknown-linux-musl`，x86 → `x86_64-unknown-linux-musl`；
  - 把 `www/5700` 前端、`/usr/bin/at-webserver` 二进制、`at-webserver` init.d 折叠进 LuCI 壳后一起编译。
- `Config/GENERAL.txt` 移除 `CONFIG_PACKAGE_at-webserver=y` 与 `CONFIG_PACKAGE_sms-tool=y`，保留 `luci-app-mt5700m` / `luci-i18n-mt5700m-zh-cn` / `ubus-at-daemon` / `sms-tool_q`。
- `TEST=true`（仅生成配置）时跳过 Rust 后端编译；正式编译若后端构建失败会直接报错终止，避免静默产出缺少 AT 后端的固件。

## [2026-08-31] 编译提速：缓存重构、并行重试与 Rust 预编译（PR #5）

### 优化（编译提速）

- **基线实测：上一次 `H5000M-AUTO`（Run #33341410294）总耗时 225.9 分钟，其中 `Compile Firmware` 独占 211.8 分钟，四个缓存检查步骤（`Toolchain` / `Ccache` / `Feeds` / `Download`）耗时全部为 0.0 分钟——即一次零缓存冷编译。** 这说明 08-28 / 08-29 两轮引入的缓存体系当时并未生效，本次针对其失效原因逐项修整。
- **① 停止每周定时清空缓存（本次最大收益项）**：`Cache-Clean.yml` 原 `schedule: 0 20 * * 0` 每周一 04:00（CST）执行 `gh cache delete --all`，之后第一次构建必然全量重编。证据：当时仓库 8 条缓存全部创建于 08-31（即清理动作之后），而 211.8 分钟的那次构建正好在清理之后启动。现改为**仅保留 `workflow_dispatch` 手动触发**——GitHub 会按 LRU 自动回收超配额缓存，定时全量清空只会人为制造每周一次的冷启动。
- **② 工具链与 ccache 合并为一份缓存，并加 `save-always: true`**：原 4 个缓存步骤均无 `save-always`，编译失败 / 超时 / 被取消时 post 保存会被整段跳过，陷入「超时 → 无缓存 → 再超时」死循环（08-29 有两次 `WRT-BUILD` 失败、一次 345 分钟被取消）。工具链（含最耗时的 host tools）在头 1~2 小时就已编好，现在即使后续失败也会保存，下次可直接续用。
- **③ 缓存键由 `WRT_CONFIG` 改为 `WRT_TARGET`，path 收窄为 `host*` / `tool*`**：
  - 键改为按目标平台共享后，`H5000M` 与 `AP3000M` 同为 `mediatek/filogic`，可共用同一份工具链，不再每天各白编一次。
  - path 由整个 `staging_dir/` 收窄为 `staging_dir/host*` + `staging_dir/tool*`（含 `.ccache`）。这是**对 08-28 改动的回退**：`make clean` 对应 Makefile 中的 `_clean: FORCE` → `rm -rf $(BUILD_DIR) $(STAGING_DIR) $(BIN_DIR) ...`，而 `rules.mk` 里 `STAGING_DIR:=$(TOPDIR)/staging_dir/$(TARGET_DIR_NAME)`，即 `staging_dir/target-*` 在缓存上传前就注定被删——打包它纯属浪费带宽，且内容随配置漂移，会污染共享给另一机型的缓存。
- **④ `dl` 缓存键去掉机型维度，按「源码 + 分支」共享**：下载的源码包与机型无关，原 key 带 `WRT_CONFIG` 导致 `H5000M` / `X86` 各存一份 2.1GB；`AP3000M` 一旦日常启用就是 3 × 2.1GB ≈ 6.3GB，叠加每机型一份工具链与 ccache 后必然突破 GitHub 约 10GB 上限，触发 LRU **连锁淘汰**——这比定时清空更隐蔽，会让所有缓存一起失效。
- **⑤ 删除 `feeds` 缓存（对 08-29 改动的回退）**：实测 `feeds update -a` 仅需约 1.0 分钟，而缓存体积 51.9MB 且 key 绑定 `WRT_HASH` 几乎必然 miss。为其付出的两次上传 / 下载开销大于收益，属净亏损，故移除。
- **⑥ 编译失败重试保持并行**：原 `make -j$(nproc) || make -j1 V=s` 一旦偶发失败就把几小时的编译从 4 线程降到 1 线程，几乎必然拖过 6 小时上限被取消。现改为重试仍用 `-j$(nproc) V=s`，输出写入 `build.log`，失败时提取首个出错包并以 `::error::` 注解上报（可经 check-runs API 直接读取，无需下载原始日志）。
- **⑦ 新增 AP3000M 的 `airpi-fanctl` Rust 预编译步骤**：`Config/AP3000M.txt` 中的 `luci-app-airpi-fancontrol` 带 `PKG_BUILD_DEPENDS:=rust/host`，OpenWrt 会从源码构建整套 rustc + cargo + LLVM，约 1.5~3 小时。现用 runner 自带的 rustup 配合已构建好的 aarch64 musl 交叉链接器直接 `cargo build`，再通过 `AIRPI_PREBUILT=1` / `AIRPI_PREBUILT_BIN` 交给包 Makefile（新增 `Scripts/inject_airpi_prebuilt.py` 负责注入）。上游 `LianXia233/luci-app-airpi3000m-fancontrol` 的 Makefile 已原生支持该分支；预编译失败会自动回退到源码构建，不影响出包。
- **⑧ 其他**：job 增加 `timeout-minutes: 345`，避免撞上平台 6 小时硬上限被强杀（强杀时 runner 直接终止，缓存 post 保存同样会被跳过）；`apt` 初始化去掉 `full-upgrade` 与 `autoremove --purge`（托管 runner 每次全量升级要数分钟，对编译零收益）；移除 runner 预置的 google-chrome apt 源（其镜像偶发哈希不一致会让 `apt update` 返回非零并中断初始化）；`make download -j$(nproc)` 仅在失败时才做串行兜底，不再每轮跑两遍全量校验；显式 `echo "CONFIG_CCACHE=y" >> .config` 并在编译步骤 export `CCACHE_DIR` / `CCACHE_MAXSIZE=5G` / `CCACHE_COMPRESS=true`（上限由 08-29 设定的 2G 放宽到 5G，在 10GB 总配额内换取更高命中率）。

### 预期效果

参照 `LianXia233/H5000M-CI-Qmodem` 在同源码（`immortalwrt master db5c5de`）、同 4 vCPU 标准 runner 下的实测：`MTK-AUTO` 99.4 / 102.0 分钟，`OWRT-ALL` 44.3 / 45.6 分钟。

- `H5000M` 稳态（缓存命中）：约 212 分钟 → **25~45 分钟**
- `AP3000M` 稳态：约 230 分钟 → **40~70 分钟**（Rust 预编译单独省 90~180 分钟）
- `X86` 稳态：约 150 分钟 → **20~35 分钟**
- 冷启动（首次 / 上游大版本）：仍是约 212 分钟，不可避免
- 每周冷启动次数：≥1 次 → **0 次**

整体降幅约 **70%~85%**。

### 注意

- **缓存键前缀变更**：`toolchain-` / `dl-` / `ccache-` 改为 `wrt-tc-` / `wrt-dl-`，旧缓存不会被复用，将由 GitHub LRU 自动回收。**合并后的第一次构建仍是冷启动**，收益自第二次起显现。
- **两个天花板**：4 vCPU 是免费标准 runner 的硬上限，`-j4` 冷编整套 ImmortalWrt 就是 2~3 小时，要再往下压只能上付费 larger runner（16 核，约降到 1/3，按分钟计费）或改用自托管；此外缓存命中依赖 `WRT_HASH` 稳定，上游频繁提交时仍会有增量重编。
- 本次仅改动工作流与脚本，不涉及 `Config/` 与固件内容，产物应保持一致。

## ## [2026-08-29] 编译提速：新增 dl / feeds 缓存并限制 ccache 体积

### 优化（编译提速）

- **WRT-CORE 新增两份缓存，补齐「下载源码」与「feeds 更新」阶段的复用（继 08-28 toolchain / ccache `restore-keys` 之后的进一步提速）**：原缓存只覆盖 `staging_dir/`（toolchain）与 `.ccache`（编译产物），而 `make download` 拉取的上游源码包、`feeds update -a` 克隆的软件源索引每轮都从零获取；在 toolchain 已可复用后，这两项成为新的主要耗时来源。
  - 新增 `Check Download Cache`：缓存 `./wrt/dl/`，key `dl-<CONFIG>-<INFO>-<HASH>`，配 `restore-keys: dl-<CONFIG>-<INFO>-` 前缀回退。上游 `WRT_HASH` 一更新精确 key 必然 miss，回退 key 命中同机型上一次的 `dl` 缓存后，`make download` 直接跳过已存在的源码包，不再重复拉取数百 MB～数 GB 的 tarball。
  - 新增 `Check Feeds Cache`：缓存 `./wrt/feeds/` 与 `./wrt/package/feeds/`，key `feeds-<CONFIG>-<INFO>-<HASH>`，同样配 `restore-keys` 回退，避免 `feeds update -a` 每轮完整克隆 / 拉取全部软件源索引。
  - 两个新缓存步骤均带 `if: env.WRT_TEST != 'true'`，与既有 toolchain / ccache 缓存逻辑一致：`TEST=true`（默认，仅生成 `.config` 校验）不受影响，只有真正出包时才读写缓存。
- **限制 ccache 体积**：顶层 `env` 新增 `CCACHE_MAXSIZE: 2G` 与 `CCACHE_COMPRESS: 'true'`。此前 ccache 无上限，缓存持续膨胀会拖慢缓存的恢复与上传；限幅并压缩后缓存更小，命中与回传更快。`Config/GENERAL.txt` 中 `CONFIG_CCACHE=y` 已启用，无需改动编译配置。
- 说明：`dl` / `feeds` 缓存首次运行仍为冷启动，需先各写入一次，自第二轮起才开始显著省时间；仓库缓存总额受 GitHub 约 10GB 上限约束，多份缓存按 LRU 自动淘汰，若出现挤占可调小 `CCACHE_MAXSIZE` 或让 `Cache-Clean.yml` 清理更激进。

## [2026-08-29] 源码切换：H5000M / AP3000M 改用 ImmortalWrt 主线
### Changed
- H5000M-AUTO / AP3000M-AUTO 工作流的 `SOURCE` 由 `VIKINGYFY/immortalwrt` 切换为 `immortalwrt/immortalwrt`，`BRANCH` 由 `owrt` 调整为 `master`；X86（OWRT-ALL）保持 `immortalwrt/immortalwrt` + `master` 不变。
- WRT-BUILD 手动编译默认源码/分支同步调整为 `immortalwrt/immortalwrt` + `master`。
- README 鸣谢保留 VIKINGYFY（OpenWRT-CI 编译框架），设备源码说明统一为 ImmortalWrt 主线。



本仓库的所有重要变更都会记录在此文件中。

## [2026-08-28]

### 优化（编译提速）

- **重构 WRT-CORE 缓存策略，消除 toolchain 全量重建（Run #33119462534 分析）**：原 `Check Caches` 的精确 key 含上游 commit（`WRT_HASH`），上游一推送精确 key 必然 miss，而 miss 时「Update Caches」还会**先删光旧缓存再重建**——失败 run 的完整时间线显示 toolchain（gcc initial+final 两轮）+ 宿主 tools 全量重建占去约 1.9 小时（21:56 → 00:11 才开始编内核），是编译耗时的最大单一来源。
  - `Check Caches` 拆为两份独立缓存并各配 `restore-keys` 前缀回退：
    - `toolchain-<CONFIG>-<INFO>-<HASH>`：整份 `staging_dir/`（原 `host*`/`tool*` 通配改为整目录，含 `staging_dir/target` 的内核头/mac80211 存根，避免遗漏）；
    - `ccache-<CONFIG>-<INFO>-<HASH>`：`wrt/.ccache`（`CONFIG_CCACHE=y` 已启用，单份持久化后对上游 mt76/mac80211 这类频繁变动的树外包命中率显著提升）。
    - 上游更新时 `restore-keys` 命中同机型最近一次缓存，OpenWrt 依据自身 stamp 只增量重编变化的组件，不再从零编译 gcc。
  - 移除「Update Caches」中按 miss 删除旧缓存的逻辑（`gh cache list/delete` 段）：restore-keys 命中的旧缓存正是本次构建的复用基础，删除它会导致下次构建退回全量重建；容量由 GitHub 10GB 上限自动按 LRU 淘汰。
  - `Download Packages` 追加 `make download -j1` 串行兜底：补齐并行下载偶发失败的源码，避免 `Compile Firmware` 中途因下载失败中断重来（该阶段重启的代价远大于多跑一次已全部命中的 download）。

## [2026-08-28]

- **永久移除 `999-mtk7987-wed-v31.patch`（Run #33119462534）**：`Compile Firmware` 阶段 `package/kernel/mt76` 编译失败，`mt7996/mmio.c:517` 与 `mt7996/mmio.c:543` 报错 `error: assignment to expression with array type`，随后 `ERROR: package/kernel/mt76 failed to build.`。
  - 根因：内核侧 `999-mtk7987-wed-v31.patch` 将 `include/linux/soc/mediatek/mtk_wed.h` 中 `wlan.wpdma_tx` 由标量 `u32` 改为数组 `u32 wpdma_tx[MTK_WED_TX_QUEUES]`、`wlan.hw_rro` 由 `bool` 改为枚举 `enum mtk_wed_hwrro_mode`，并新增 `rro_3_1_rx_ring_setup` 等接口；但上游 mt76（`2026.08.08~503c643b`）仍按旧标量 API 赋值 `wed->wlan.wpdma_tx`，且此前配套的 mt76 侧补丁（`998-mt76-wed-hwrro-enum.patch`）已因 mt76 上游更新而移除，内核补丁与 mt76 源码的 API 断裂无法在 CI 侧低风险弥合。
  - 处理：删除 `Scripts/patches/wed/999-mtk7987-wed-v31.patch` 与 `Scripts/patches/wed/` 目录；`Scripts/Handles.sh` 中彻底移除内核侧 WED 补丁注入段（`WED_PATCHES_SRC` / `WED_APPLIED` 逻辑及注释）。VIKINGYFY/immortalwrt `owrt` 分支回到上游原生 WED 代码路径，mt76 按上游默认行为编译，编译恢复。
  - 影响：H5000M（MT7987）机型的 WED 硬件加速回落到上游默认支持状态（如上游未启用则 `mtk_wed_device_attach` 不挂载、走普通收发路径，功能不受影响，仅硬件路径加速不可用）；后续如需重新启用，需基于当时的内核与 mt76 commit 同步重做内核侧与 mt76 侧两套补丁并经 `git apply --check` 双向验证。

## [2026-08-28]

### 变更

- **H5000M / AP3000M 源码切换**：`MTK-AUTO.yml` 编译矩阵的 `SOURCE` 由 `immortalwrt/immortalwrt` 切换为 [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt)，`BRANCH` 由 `master` 调整为 `main`（VIKINGYFY 仓库仅有 main/owrt/test 三个分支，无 master）。仅影响 5000M 与 3000M 两个机型的自动编译；OWRT-ALL（X86）、手动编译入口 WRT-BUILD 及 Config/Scripts 均保持不变。
- 风险提示：现有 WED V3.1 补丁（`999-mtk7987-wed-v31.patch` / `998-mt76-wed-hwrro-enum.patch`，仅注入 H5000M-WIFI-YES）此前基于 immortalwrt/immortalwrt master（内核 6.18.x）验证；VIKINGYFY/immortalwrt 的内核与 mt76 版本若与其不同，首次构建可能需要重新校准补丁。
- **分支再次调整**：按最新要求，`MTK-AUTO.yml` 编译矩阵的 `BRANCH` 由 `main` 调整为 `owrt`（使用 VIKINGYFY/immortalwrt 的 owrt 分支）。其余配置不变。

### 变更（永久移除）

- **永久移除 mt76 侧 WED hw_rro 枚举补丁（Run #33100607008）**：`Compile Firmware` 阶段 `package/kernel/mt76` 编译失败，根因为 `Scripts/patches/wed/998-mt76-wed-hwrro-enum.patch` 应用失败——上游 mt76 已更新至 `2026.08.08~503c643b`，`mt7996/mmio.c` 第 488 / 518 行附近上下文与补丁基线不一致，2 个 hunk 全部 FAILED（生成 `.rej`），mt76 包构建中断（`ERROR: package/kernel/mt76 failed to build`）。
  - 处理：删除 `Scripts/patches/wed/998-mt76-wed-hwrro-enum.patch`；`Scripts/Handles.sh` 中彻底移除 mt76 侧注入逻辑（`MT76_PATCH_DIRS` 段）并同步清理相关注释，保留内核侧 `999-mtk7987-wed-v31.patch` 注入不变。
  - 影响：H5000M（MT7987）机型不再注入 mt76 侧 hwrro 枚举映射修正，WED 维持上游默认行为；不影响编译。该补丁已确认不再需要，永久移除、不再恢复。

### 变更

- **MTK-AUTO 重命名为 H5000M-AUTO**：`.github/workflows/MTK-AUTO.yml` 更名为 `H5000M-AUTO.yml`，工作流 `name` 同步改为 `H5000M-AUTO`（原 MTK-AUTO 仅编译 H5000M-WIFI-YES，为与机型命名保持一致而重命名）。同步更新：`WRT-CORE.yml` / `AP3000M-AUTO.yml` 顶部注释、`README.md` 工作流表格与项目结构（补充 AP3000M-AUTO 条目）。编译矩阵、触发方式与参数均不变。
- **拆分 AP3000M 与 H5000M 自动编译**：`MTK-AUTO.yml` 编译矩阵由 `[H5000M-WIFI-YES, AP3000M]` 收敛为仅 `[H5000M-WIFI-YES]`；新增独立工作流 `AP3000M-AUTO.yml`（同样监听 `Auto-Clean` 完成后触发 + 支持手动 `workflow_dispatch`，参数与 MTK-AUTO 保持一致），两个机型从此分开编译、互不影响，Release 与构建日志按机型独立呈现。

## [2026-08-25]

### 新增

- **TTYD Web 终端**：全机型默认集成 [ttyd](https://github.com/tsl0922/ttyd) 网页命令行终端，LuCI「系统 → TTYD 终端」页面可在浏览器直接操作设备 Shell。`Config/GENERAL.txt` 新增并默认启用 `ttyd`、`luci-app-ttyd`、`luci-i18n-ttyd-zh-cn` 三个软件包。

### 修复

- **修复 MTK-AUTO H5000M-WIFI-YES 编译失败（Run #32827814718）**：`Compile Firmware` 阶段 `mt7996/mmio.c` 编译报错 `assignment to expression with array type`（491 / 527 行），`ERROR: package/kernel/mt76 failed to build.`。
  - 根因：内核侧 `999-mtk7987-wed-v31.patch` 将 `include/linux/soc/mediatek/mtk_wed.h` 中 `wlan.wpdma_tx` 由标量改为数组 `u32 wpdma_tx[MTK_WED_TX_QUEUES]`、`wlan.hw_rro` 由 `bool` 改为枚举 `enum mtk_wed_hwrro_mode`，但 mt76 侧补丁未同步适配 `mt7996/mmio.c` 中两处按标量赋值的语句（对照联发科官方 `mtk-openwrt-feeds` 的 `0049-mtk-mt76-mt7990-add-mt7987-wed-hw-path-support.patch` 确认了正确写法）。
  - 修复：重写 `Scripts/patches/wed/998-mt76-wed-hwrro-enum.patch`——`wpdma_tx` 两处赋值改为 `wpdma_tx[0]`（hif2 分支与主分支），主分支补齐 V3.1 所需的 `wpdma_tx[1]`（`MT_TXQ_RING_BASE(1) + MT7996_TXQ_BAND1 * MT_RING_SIZE`），`hw_rro` 改为 `(enum mtk_wed_hwrro_mode)dev->mt76.hwrro_mode` 直接映射（mt76 与内核枚举数值一一对应）；同时预防性修正 `mt7915/mmio.c` 两处同类赋值。已基于 CI 实际使用的 mt76 commit（`5967691`）通过 `git apply --check` 验证。

## [2026-08-24]

### 新增

- **MT7987 WED V3.1 硬件路径支持（内核 6.18）**（commit `d1d718d`）：将 MT7987 WED（Wireless Ethernet Dispatch）V3.1 硬件路径支持补丁移植到 6.18 内核 API 并注入 CI 构建流程，解决 MT7987 平台因设备树（DTS）缺少 `wo-ccif` 节点导致内核报 `failed to attach wed device`、无线硬件加速不可用的问题。
  - `999-mtk7987-wed-v31.patch`：内核侧补丁（6329 行），将 WED V3.1 硬件路径支持适配至 6.18 内核 API。
  - `998-mt76-wed-hwrro-enum.patch`：mt76 驱动侧 `WED_HWRRO` 枚举修正，与内核补丁配套。
  - `Scripts/Handles.sh`：新增注入段，将上述补丁在构建时自动拷入对应源码目录并应用。

### 修复

- **修复 MTK-AUTO 编译失败（Run #32730137693）**：首次推送的 `999-mtk7987-wed-v31.patch` 基于无提交记录的本地基线生成，被 git 当作 **new-file 格式**（整个文件为新增行），而 OpenWrt 构建时目标文件已存在，导致补丁应用全部 hunk 失败，`Compile Firmware` 阶段中断。
  - 根因：补丁基线（`wed618` 临时目录）从未建立 git 基线提交，`git diff` 输出为全新增文件；且 Windows 侧 CRLF 污染曾使 diff 整文件漂移。
  - 修复（commit `313909a` 后追加提交）：重新以 **6.18.44 官方内核源文件 + immortalwrt patches-6.18（940/942/943/944）** 建立真实基线（`wedreal`），基于该基线重新生成补丁（1825 行，778 增 / 259 删，与原厂补丁规模一致），在本地 `git apply --check` 验证通过；同时修正 `998-mt76-wed-hwrro-enum.patch` 的 hunk 行数错误并对照 CI 实际使用的 mt76 commit（`5967691`）验证可应用。补丁统一为 LF、标准 `diff --git` 格式。

- **修复 MTK-AUTO 编译失败（Run #32737139044）：** 修复提交 `9069348` 后 `999-mtk7987-wed-v31.patch` 在 `Compile Firmware` 阶段 `mtk_wed.c` 编译失败，报错 `struct <anonymous> has no member named 'wed_rev_id'` 及 `MTK_WED_REV_ID_MAJOR/MINOR undeclared`。
  - 根因：移植 6.18 的补丁只合并了联发科 `999-wed-10-add-mt7987-hwpath-support.patch` 的核心逻辑，但漏掉同系列 `999-wed-08-extended-wed-debugfs.patch` 中配套的定义：`struct mtk_wed_soc_data` regmap 缺 `u32 wed_rev_id;` 成员、`mtk_wed_regs.h` 缺 `MTK_WED_REV_ID_MAJOR (GENMASK(31,28))` / `MTK_WED_REV_ID_MINOR (GENMASK(27,16))` 宏。
  - 修复：在 6.18.44 基线（wedreal）上补齐上述定义，并为 mt7622/mt7986/mt7988 的 `soc_data.regmap` 补上 `.wed_rev_id` 初始化（与联发科 6.12 一致：0 / 0x4 / 0x4）；重新生成补丁（1855 行，784 增 / 259 删），本地 `git apply --check` 验证通过。

- **WED 补丁仅对 H5000M 机型注入（commit `f2096b6`）**：此前 `Scripts/Handles.sh` 的 WED 注入段对所有目标机型无条件注入 `999-mtk7987-wed-v31.patch` 与 `998-mt76-wed-hwrro-enum.patch`，导致其他机型编译失败：X86 目标（AP3000M）的 mt76 应用 `998-mt76-wed-hwrro-enum.patch` 时 hunk 不匹配报错，MTK-AUTO 的 AP3000M（MT7981）机型也因 SoC/WiFi 芯片不同而不适用该补丁。
  - 修复：在 `Scripts/Handles.sh` 的 WED 注入段增加 `WRT_CONFIG` 判断，仅当配置为 `H5000M-WIFI-YES`（MT7987）时注入上述两个补丁，其余机型（AP3000M / X86 等）完全跳过，不影响构建。

## [2026-08-18]

### 修复

- **修复 OWRT-ALL / X86 编译失败（Run #32071207860）**：`Compile Firmware` 阶段报错 `bash: line 1: ./hack/make.sh: No such file or directory`，`make[3]: *** [Makefile:168: .../dockerd-29.6.1/.built] Error 127`，`ERROR: package/feeds/packages/dockerd failed to build.`。
  - 根因：`Scripts/Handles.sh` 中 Python 注入 `fix-binary-daemon.sh` 调用时，替换出的行**未保留 Makefile 的 `\` 续行符**，把原本连续的 recipe 拆成两条独立 shell 命令——`cd $(PKG_BUILD_DIR); ... . fix-binary-daemon.sh ...` 在源码目录执行并成功打补丁，但 `./hack/make.sh binary` 退化为独立 recipe 行，在**包目录**（`feeds/packages/utils/dockerd`）执行，该目录下不存在 `hack/make.sh`，故报 Error 127。
  - 修复（`Scripts/Handles.sh`）：注入行改为 `cd $(PKG_BUILD_DIR) && . "$(CURDIR)/fix-binary-daemon.sh" "$(PKG_BUILD_DIR)" && \` 以 `&& \` 续行符结尾，确保 `cd`、补丁脚本、`./hack/make.sh binary` 在同一条 make recipe（同一 shell、同一工作目录）中顺序执行。已用上游 `openwrt/packages` 的 dockerd Makefile 本地模拟验证注入结果正确。

### 变更

- **默认 Wi-Fi SSID 回退为 `OWRT`**：`OWRT-ALL.yml` / `MTK-AUTO.yml` / `WRT-BUILD.yml` 三个工作流的 `WRT_SSID` 环境变量由 `OWRT_2.4G` 回退为默认值 `OWRT`（2.4G 与 5G 频段默认 SSID 一致，由 `Scripts/Settings.sh` 在编译时写入）。默认密码仍为 `12345678`，加密方式 WPA-PSK/WPA2-PSK Mixed Mode、国家码 `CN` 等保持不变。同步更新 `README.md`「默认配置」小节中的 SSID 记录。

## [2026-08-15]

### 修复

- **修复 OWRT-ALL / X86 编译失败（Run #31842487773）**：`Compile Firmware` 阶段报错 `make[3]: *** [Makefile:166: .../dockerd-29.6.1/.built] Error 1`（失败 job：94902144731，SOURCE=immortalwrt/immortalwrt）。根因为 `dockerd 29.6.1` 的 moby 构建脚本 `hack/make/binary-daemon` 中 `copy_binaries()`：当 CI runner 预装 Docker（存在 `/usr/local/bin/runc`）且目标架构与宿主一致（linux/amd64）时，会尝试从宿主 PATH 拷贝 `containerd`/`runc`/`rootlesskit`/`dockerd-rootless.sh` 等“嵌套可执行文件”；但 GitHub Actions runner 上这些并不在 PATH，`command -v` 返回空串导致 `cp -f ""` 报错，配合脚本 `set -e` 直接中断编译。这些二进制本就由独立的 OpenWrt 包在运行时提供，无需打入 dockerd bundle。
  - 为何原有补丁未生效：仓库既有 `Scripts/patches/dockerd/999-fix-nested-binaries.patch` 内容正确（同样将拷贝改为条件拷贝），但本次构建日志中**没有出现任何 `patching file hack/make/binary-daemon` 输出**，说明 OpenWrt 未触发对该文件应用补丁，故仅依赖补丁机制不可靠。
  - 修复（双保险，绕过补丁机制）：
    - 保留 `999-fix-nested-binaries.patch` 拷入 `feeds/.../dockerd/patches/`（OpenWrt 标准机制，能用时生效）；
    - 新增 `Scripts/patches/dockerd/fix-binary-daemon.sh`：在 dockerd 源码解包后、编译前对 `hack/make/binary-daemon` 做就地 sed 修正，将 `cp -f "$(command -v "$file")" "$dir/"` 改为「仅当该文件存在于 PATH 时才拷贝，缺失则跳过」（`bin="$(command -v "$file" 2>/dev/null || true)"; [ -n "$bin" ] && cp -f "$bin" "$dir/"`）。
    - 修改 `Scripts/Handles.sh` dockerd 段（约 300–368 行）：把补丁与修正脚本一同拷入 dockerd 包目录并 `chmod +x`，再用 Python 在 dockerd `Makefile` 的 `Build/Compile` 中、`./hack/make.sh binary` 之前注入 `bash "$(CURDIR)/fix-binary-daemon.sh" "$(PKG_BUILD_DIR)"; \`（幂等，已注入则跳过）；`find` 同时覆盖拷贝安装与软链安装两种 feeds 路径。

## [2026-08-12]

### 修复

- **修复默认无线密码和时区不生效问题**（`Scripts/Settings.sh`）：默认无线加密设为 WPA-PSK/WPA2-PSK Mixed Mode、地区 CN、2.4G 频宽 40MHz、5G 频宽 160MHz，并在 `config_generate` 中强制写入 `timezone='CST-8'` + `zonename='Asia/Shanghai'` 确保时区生效。同时兼容旧式 `set-wireless.sh` 和新型 `mac80211.uc` 两套无线默认配置路径。
- **HomeProxy ucode 兼容性修复**：ImmortalWrt master 已移除 `luci.sys.init_action` 且 ucode 不含 `math` 模块，导致订阅更新与客户端配置生成失败（sing-box 无法启动，页面报 "URLTest: 无效节点"）。在 `Scripts/Handles.sh` 中加入自动覆盖修复，CI 构建时替换上游的两个脚本：
  - `update_subscriptions.uc`：移除 `import { init_action } from 'luci.sys'`，将 `init_action('homeproxy', 'restart')` 替换为 `system('/etc/init.d/homeproxy restart >/dev/null 2>&1')`，修复订阅拉取后无法更新节点列表的问题。
  - `generate_client.uc`：移除 `import { isnan } from 'math'`，将 `isnan(int(i))` 替换为 `type(int(i)) === 'double'`（ucode 中 `int("abc")` 返回 double 类型 `NaN`），修复 sing-box 客户端配置生成失败导致服务无法启动的问题。
  - 修复脚本存放于 `Scripts/homeproxy/`，不包含节点信息。
- **修复 OWRT-ALL / X86 编译失败（Run #31556891052）**：`Compile Firmware` 步骤报错 `exit code 2`。根因为 `kmod-nft-fullcone`（fullconenat，`llccd/netfilter-full-cone-nat`）为树外内核模块、直接补丁 nftables 核心，其源码停留在 `PKG_SOURCE_DATE=2023-01-01`，未适配 immortalwrt master 内核 **6.18.41**，导致内核模块编译失败（`make download` 已成功，故为编译期而非下载期错误）。在 `Config/GENERAL.txt` 中暂时禁用 `CONFIG_PACKAGE_kmod-nft-fullcone`（全机型通用配置），待上游提供 6.18 兼容版本后取消注释即可恢复 Fullcone NAT 支持。

### 变更（临时禁用）

- **暂时禁用 Honk 插件**：按需求临时关闭，未删除任何逻辑，可一键恢复。
  - `Scripts/Packages.sh`：将 `INSTALL_HONK_PREBUILT` 调用注释（函数体保留）。
  - `Config/GENERAL.txt`：将 Honk 运行时依赖（`ca-bundle`/`jq`/`nsenter`/`tc-full`/`v2ray-geoip`/`v2ray-geosite`/`kmod-sched-core`/`kmod-sched-bpf`）与 `CONFIG_KERNEL_DEBUG_INFO_BTF=y` 全部注释。
  - 恢复方法：取消 `Packages.sh` 中 `INSTALL_HONK_PREBUILT` 的注释，并取消 `GENERAL.txt` 中上述 `CONFIG_*` 行的注释即可。

## [2026-08-11]

### 新增

- **全机型集成 Honk eBPF 透明代理插件**（[breeze303/openwrt-honk](https://github.com/breeze303/openwrt-honk)，`main` 分支），默认启用，覆盖全部编译机型（X86 / AP3000M / H5000M-WIFI-YES，均为 x86_64 / aarch64，满足插件平台要求）：
  - `Scripts/Packages.sh`：新增 `UPDATE_PACKAGE "honk"`，以 `pkg` 模式从上游仓库提取 `honk`、`luci-app-honk`、`luci-app-honk-legacy` 三个软件包（自动跳过 docs/locks/tests 等非包目录）。
  - `Config/GENERAL.txt`：默认启用 `CONFIG_PACKAGE_honk=y` 与 `CONFIG_PACKAGE_luci-app-honk=y`（新版 LuCI 管理界面；旧版 `luci-app-honk-legacy` 作为回滚备用，默认不编译进固件）。

### 依赖处理

- **运行时依赖**（`Config/GENERAL.txt` 显式启用）：`ca-bundle`、`jq`、`nsenter`、`tc-full`、`v2ray-geoip`、`v2ray-geosite`、`kmod-sched-core`、`kmod-sched-bpf`；`ip-full`、`kmod-veth`、`curl`、`luci-base`、`luci-compat` 此前已在通用配置中启用。`libstdcpp` 等由软件包 `DEPENDS` 自动解析。
- **内核依赖**：显式启用 `CONFIG_KERNEL_DEBUG_INFO_BTF=y`，满足 eBPF 程序的 BTF 需求（BPF/BPF_JIT/CGROUP_BPF/NET_CLS_BPF 等由 `kmod-sched-bpf` 等内核模块依赖自动带出）。
- **主机编译依赖**（`Scripts/Packages.sh` 新增 `INSTALL_HONK_DEPS`，在 Custom Packages 阶段自动执行）：
  - 系统组件：`clang`、`llvm`、`libbpf-dev`、`libclang-dev`、`pkg-config`、`cmake`、`zstd`（bindgen 与 eBPF 编译所需）；
  - Rust 工具链：通过 rustup 安装上游锁定的 `nightly-2026-07-20`（含 `rust-src` 组件，用于 `-Zbuild-std=core` 编译 `bpfel-unknown-none` 目标）；
  - eBPF 链接器：安装 `bpf-linker 0.10.4`（下载后执行 SHA-256 校验，校验失败立即中断，避免引入被篡改的工具链），并写入 `GITHUB_PATH` 保证后续编译步骤可用。
### 修复（构建超时）

- **修复 MTK-AUTO 构建被 GitHub 6 小时上限取消的问题（Run #31472548184）**：MTK-AUTO 构建 `08:17` 开始，`14:17`（正好 6 小时）被 GitHub 强制取消，日志中无编译报错（仅 Kconfig `recursive dependency` 警告与已成功的依赖安装步骤），取消时 cargo/rustc 正在编译 honk。根因为 honk 为 Rust/eBPF 架构，从源码编译极重，使总耗时超过 GitHub 标准 runner 的单 job 6 小时硬上限。
- **honk 改为上游预编译 APK 注入**（不再从源码编译）：
  - `Scripts/Packages.sh`：移除 `UPDATE_PACKAGE "honk"` 与 `INSTALL_HONK_DEPS`（主机 Rust/eBPF 工具链），新增 `INSTALL_HONK_PREBUILT()`——按目标架构从上游最新 release 下载 `honk` 与 `luci-app-honk` 的 `openwrt-25.12` APK（与 `immortalwrt/immortalwrt@master` 默认 `USE_APK=y` 匹配），放入固件 `files/etc/honk/`，并写入 `files/etc/uci-defaults/99-honk-install`，在设备**首次开机时离线 `apk add --allow-untrusted`** 安装（依赖由 `GENERAL.txt` 编入镜像，无需联网）：
    - 架构映射（优先用 `WRT_TARGET`，回退 `WRT_CONFIG`）：`x86`→`x86_64`；**`mediatek`→`aarch64_cortex-a53`**（MT798x / MT7622 等 MTK 机型专用，Cortex-A53 架构）；其余→`aarch64_generic`。
  - `Config/GENERAL.txt`：移除 `CONFIG_PACKAGE_honk=y` / `CONFIG_PACKAGE_luci-app-honk=y`（APK 构建中无对应源码符号，会被 defconfig 丢弃），保留全部运行时依赖（`ca-bundle`/`jq`/`nsenter`/`tc-full`/`v2ray-geoip`/`v2ray-geosite`/`kmod-sched-*`）与 `CONFIG_KERNEL_DEBUG_INFO_BTF=y`。

### 修复
- **修复 honk 包编译失败（Run #33）**：AP3000M / H5000M-WIFI-YES 两个机型均在 `Compile Firmware` 阶段报错 `cp: cannot overwrite non-directory '.../root-mediatek/./var' with directory '.../.pkgdir/honk/./var'`。
  - 根因：honk 上游 `Makefile` 的 `Package/honk/install` 中执行 `$(INSTALL_DIR) $(1)/var/share/honk`，在 pkgdir 下创建了 `var/` 目录；而 OpenWrt rootfs 中 `/var` 是指向 `/tmp` 的符号链接，构建系统复制 pkgdir 到 rootfs 时 `cp` 无法用目录覆盖符号链接。
  - 修复（`Scripts/Handles.sh` 新增 honk 修复段）：在 Custom Packages 阶段自动移除 honk `Makefile` 中 `/var/share/honk` 的创建与 `chmod 0700`；运行时数据目录由 `honk.init` 的 `prepare_subscription_store()` 在启动时通过 `mkdir -p` 自动创建，不影响功能。

