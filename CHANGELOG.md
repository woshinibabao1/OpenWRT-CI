# 更新日志

## [2026-09-22 · 常见依赖补全 第二轮] 以 V0.18 + Mwrt 双基线交集再补 14 项，并修掉一处「空 meta」配置

触发：要求以**两套基线固件**（好用的固件 V0.18、Mwrt-H5000M-1139-24）为基准再补全一次。

### 1. 新增第二个基线：Mwrt（opkg 时代）

- 镜像 squashfs 偏移 **4578304**（0x45D000，全盘只有一个 `hsqs` 魔数）；
  包数据库是 `/usr/lib/opkg/status`（**opkg 而非 apk**，651 个包）。
- 三方对比：V0.18 = 361 包，Mwrt = 651 包，我方真机 = 400 包；
  **两基线共有 284 个**，其中我方没有的 68 个逐个判定。
- 判据用**交集**而不是并集：两套来源完全不同的固件都装，才说明不是哪一家的偏好。
  （并集里有 287 项是 Mwrt 单方带的，多数是它自己的产品栈：iStoreOS 应用商店、
  docker/containerd、haproxy、dbus/avahi/openldap 等。）

### 2. ★★ 顺带查出一处**真缺陷**：`xz-utils` 是个空 meta 包，装了等于没装

`Config/GENERAL.txt` 的「常用工具」区一直写着 `CONFIG_PACKAGE_xz-utils=y`，但：

| 证据 | 内容 |
| :-- | :-- |
| 上游 Makefile | `openwrt/packages` 的 `utils/xz/Makefile` 里 `Package/xz-utils` 只有 TITLE、**没有 DEPENDS**；真正带二进制的是 `xz`（模板生成，`DEPENDS:=xz-utils`，即 xz 反过来拉 meta） |
| 真机包库 | `xz-utils-5.8.3-r1` 已装，`D:` 只有 `libc`，包内容只有 `lib/apk/packages/xz-utils.list`（782 字节） |
| 真机文件系统 | `/usr/bin/xz` **不存在** —— 也就是说固件里从来没有 xz 命令 |
| 两套基线 | 装的都是 `xz`，不是 `xz-utils` |

已改为 `CONFIG_PACKAGE_xz=y`，并把它**移进 plugin-deps 断言区**
（"配了等于没配"正是最该被断言的一类）。

### 3. 本轮补的 14 项

| 分组 | 包 | 为什么 |
| :-- | :-- | :-- |
| 修空 meta | `xz` | 见上；两基线都有 |
| 用户态（两基线都有的常用件） | `bash` | 很多插件脚本是 `#!/bin/bash`（`[[ ]]`/数组/`local -n`），busybox ash 跑不了 |
| 〃 | `jq` | 脚本解析 JSON 的事实标准（honk 的依赖里就有 jq） |
| 〃 | `wget-ssl` | busybox wget 不支持 HTTPS；很多脚本写死 `wget` |
| 〃 | `tar` `unzip` `bzip2` `liblzma` `libzstd` | 解包类插件/安装脚本的常见依赖（下载 geo 数据、释放资源包） |
| iptables **用户态**（补上一轮的另一半） | `iptables-nft` `ip6tables-nft` `xtables-nft` `iptables-mod-extra` | 上一轮只补了内核侧 `xt_*` 模块，但没有命令一样跑不起来；两者齐了"走 iptables 模式的插件"才真能用 |
| kmod 配套 | `kmod-nf-nat6` | 与 `kmod-ipt-nat6` 配套的 IPv6 NAT 后端（两基线都有） |

### 4. 明确**不加**（写进 Config 注释，附理由）

- **别的模组驱动**：`kmod-qmi_wwan_f/q/s`、`kmod-usb-serial-qualcomm`、
  `kmod-usb-net-huawei-cdc-ncm`（本机 MT5700 走 CDC-NCM/option；换模组再加）。
- **别的场景**：`kmod-nf-ipvs`（只服务容器编排）、`kmod-crypto-eip`、
  `kmod-mt7987-2p5g-phy`（已被 `kmod-phy-mediatek-2p5g` 覆盖）、
  `kmod-nf-conntrack6`（上游已并入 `kmod-nf-conntrack`）。
- **产品级选择**：docker/containerd/runc/tini、`taskd`/`luci-app-store`/
  `luci-lib-taskd`/`luci-lib-xterm`/`luci-theme-bootstrap`（iStoreOS 那套）、
  `miniupnpd-nftables`（用户已明确移除 UPnP）、QModem 全家桶（已按方案 B 移除）、
  `opkg`（我方用 apk）。
- **传递依赖**：`coreutils*`/`script-utils`/`mount-utils`/`libacl`/`libcap-ng`/
  `libsqlite3-0`/`libpcre2`/`libseccomp`/`libuci-lua`/`libpcap1`/`ndisc6`
  （缺父组件就无意义）、`ca-certificates`（与已装的 `ca-bundle` 冗余，两者都
  PROVIDES `@ca-certs`）。

### 5. 断言补了一个必要分支：TEST 配置必须跳过

第一轮加的断言对**所有**配置生效，但 TEST 配置只叠机型配置、**不叠 `GENERAL.txt`**
（见 `Custom Settings` 的 if/else）—— 照断会整片误报成"缺 30 个包"。
已在同一处加 `DEPS_EXPECT` 标记：只有叠加过 GENERAL 的配置才断言，否则打印跳过。

验证（三情形）：`DEPS_EXPECT=1` + 30 个全 `=y` → rc=0；
故意少一个 → rc=1 并**报出包名**；`DEPS_EXPECT=0` → 跳过且 rc=0。
标记被改名时提取数为 0 → 由"< 10 即报错"拦下。
所有新增包名都在真机的 apk 在线索引里核过存在性（避免 kconfig 静默丢弃）。

## [2026-09-22 · 常见依赖补全] 补 16 个插件常见依赖 + CI 自动断言

触发：装第三方插件时报「依赖缺失 `kmod-inet-diag`」。

### 1. 定位：谁在要它

V0.18 基线固件的 apk 数据库里，**`mihomo-alpha` 的依赖正是**
`ca-bundle ip-full kmod-inet-diag kmod-tun libc`；**`nikki` 的更长**（含同一个
`kmod-inet-diag`）。即上游插件把它写进了依赖，而本固件从来没编过 → 于是"装插件卡住"。

### 2. 为什么这类包必须编进镜像，而不能等缺了再 `apk add`

`kmod-*` 的依赖串里带**内核指纹**（形如 `kernel=6.18.52~<build-hash>`）。
本固件是自编译内核 —— `cat /proc/version` 显示 `runner@runnervmlun5p ... #0 SMP`，
即带我们自己构建的指纹。在线仓库里的同名 kmod 是给**官方内核**编的：
装上去要么被 apk 直接拒绝，要么装上因 vermagic 不一致而 `modprobe` 失败
（症状是"包在、功能没有"）。**用户态包没有这个问题**（可直接在线装），
所以「装插件缺依赖」这类问题，**只有 kmod 这一类需要预置进镜像**。

### 3. 补了什么（16 个，每个都核过上游定义）

选包依据：与 V0.18 基线做差集（基线 113 个 kmod，真机现在 167 个，多数只是版本不同），
差集里属于"第三方插件常见依赖"的那批；并逐个在**上游源码**里核对过符号存在
（immortalwrt master 的 `package/kernel/linux/modules/*.mk`，共 1188 个 KernelPackage 定义）。

| 分组 | 包 | 为什么 |
| :-- | :-- | :-- |
| 代理/隧道插件直接声明 | `kmod-inet-diag` | netlink SOCK_DIAG，socket→进程反查；代理插件"按进程分流"必需（本次触发项） |
| 〃 | `kmod-nft-compat` | xtables 老匹配模块接到 nft 的兼容层，iptables-nft 靠它 |
| iptables 兼容层 | `kmod-ipt-core` `kmod-ipt-conntrack` `kmod-ipt-nat` `kmod-ipt-nat6` `kmod-ipt-extra` `kmod-ipt-physdev` `kmod-ip6tables` `kmod-nf-ipt` `kmod-nf-ipt6` | V0.18 基线全带；老插件与社区脚本仍普遍直接用 iptables |
| 〃（走 iptables 模式的代理插件） | `kmod-ipt-tproxy` `kmod-ipt-ipset` | 透明代理（xt_TPROXY）与 ipset 集合匹配；本固件自身用 nft 的 tproxy/set，这两个只为插件按 iptables 模式跑时兜底 |
| 桥接/串口/兜底 | `kmod-br-netfilter` | netfilter 过滤**桥接**流量；真机此前 `/proc/sys/net/bridge` 目录都不存在 |
| 〃 | `kmod-usb-acm` | USB CDC-ACM 串口通用兜底（基线带） |
| 〃 | `kmod-lib-crc32c` | 多个 kmod 的**包级**传递依赖（本机内核把它编成内建 → 功能有、`apk` 找不到该包名） |

**真机核实过"不是白加"**：`/sys/module/inet_diag`、`/sys/module/br_netfilter`、
`/sys/module/nft_compat` 三个都不存在，`/lib/modules/6.18.52` 里也无对应 `.ko`。

### 4. 明确**没**加的（都属于别的设备/场景）

`kmod-crypto-eip`（MTK 老平台加密引擎，本机用 EIP197/safexcel）、
`kmod-mt7987-2p5g-phy`（本机已由 `kmod-phy-mediatek-2p5g` 覆盖，只是包名不同）、
`kmod-qmi_wwan_f/q/s`、`kmod-usb-serial-qualcomm`、`kmod-usb-net-huawei-cdc-ncm`
（别的模组的驱动；本机 MT5700 走 CDC-NCM/option）、
`kmod-nf-ipvs`（IPVS，本机不跑）、`kmod-nf-conntrack6`（新版已并入 `kmod-nf-conntrack`）。

### 5. 配套：CI 自动断言（防止"配了等于没配"）

kconfig 对**不存在或依赖不满足**的符号是**静默丢弃** —— 「defconfig 成功」完全
不能证明包名有效。在 `WRT-CORE.yml` 的 `Custom Settings` 里加了断言：

- **清单从配置里提取，不抄第二份**：`Config/GENERAL.txt` 里用
  `# >>> plugin-deps:begin` / `# >>> plugin-deps:end` 两行圈出标记区，
  CI 用 awk 按**整行**匹配提取区内的所有 `CONFIG_PACKAGE_*`，逐个断言必须为 `=y`。
  以后往这一段加包 = 自动纳入断言（手抄两份清单必然漂移，这是本项目踩过的坑）。
- **标记被改也拦得住**：提取数量 < 10 直接 `::error::`（否则标记丢了就等于断言空跑）。
- **反向验证过**（不是"看起来对"）：正常 16 个全 `=y` → rc=0；故意少一个 →
  rc=1 且**报出具体包名**；把 begin 标记改名 → rc=1 报"提取数为 0"。

## [2026-09-22 · 风扇温控换源] `luci-app-h5000m-fancontrol` 改用自有 fork（补 5G 模组取温）

触发：上游取 5G 模组温度的路在本机是死的（见下），故把编译来源从
`FAN789/luci-app-h5000m-fancontrol` 换成 `woshinibabao1/luci-app-h5000m-fancontrol`。

### 1. 为什么换：上游那条取温路在本机恒空

上游 `find_module_temp()` 只读 `/var/run/mt5700m/temperature` —— 那是**别的模组管理
软件**生成的缓存文件。真机取证：`/var/run/mt5700m/` **目录不存在**，`/tmp/cache_*`
也没有 → `module_temp` 恒为空，**5G 模组温度从未参与过取热**（"最高温度"模式实际
只看 CPU/PHY/Wi-Fi）。

而本机已有现成通道：`ubus call mt5700 at '{"cmd":"AT^CHIPTEMP?"}'` 直接返回 12 路
温度（`401,400,396,402,370,370,400,400,400,410,380,380`，单位 0.1℃）。真机对照：

| | 上游版 | fork 版 |
| :-- | :-- | :-- |
| `module_temp` | **空** | **41** |
| `module_sensor` | 无此字段 | **modem2**（第 10 路最热） |

### 2. 改了什么

| 位置 | 改动 |
| :-- | :-- |
| `Scripts/Packages.sh` | 克隆源改为 `woshinibabao1/luci-app-h5000m-fancontrol`，并写明换源原因与"仅在编入 `luci-app-mt5700` 时才有意义"的前提 |
| `Scripts/Packages.sh`（netmode 行） | 保持 `FAN789` 原版；原注释"与风扇控制同源"已不成立，改为说明两者为何不同源 |
| `README.md` | 致谢链接补 fork；第二节补"5G 模组取温"说明（上游为何取不到、fork 怎么取、取不到时如何回退） |

**包名、Config 符号、UCI 配置文件名全部不变** → `Config/H5000M-WIFI-YES.txt` 的
`CONFIG_PACKAGE_luci-app-h5000m-fancontrol=y` 与真机升级路径都不受影响。版本由
上游 2.1.0 升到 fork 的 **2.2.0**。

### 3. 风险与回退

- fork 是公开仓库（`private=false`、`default_branch=main`），CI 走
  `https://github.com/<repo>.git` 克隆，与其余包同一路径，无额外凭据需求。
- 新增取温通道**只在能拿到 `ubus mt5700` 时生效**；拿不到就退回旧缓存，
  不会让风扇凭空加速，也不会报错。
- 回退：把 `Scripts/Packages.sh` 里该行 repo 改回 `FAN789/...` 即可
  （会退回"模组温度不参与"的旧行为）。

## [2026-09-22 · 文案纠偏] Release 说明混进内部笔记 + flow offload 默认值写反

触发：用户看到 Release 页面顶部顶着一个"改文案的理由"标题，问这是什么。

### 1. Release 正文里的 `#` 不是注释，是内容 —— 已移出

`WRT-CORE.yml` 的 Release 步骤把三条内部工作笔记直接写进了 `body: |` 标量里：

```yaml
body: |
  # 文案按实际产物写：单 profile 编译，只此一个设备；加速只开软件卸载。
  # 原「内含多个设备 / 全系带开源硬件加速」与实际不符 —— …
  本 Release 只含 Hiveton H5000M …
```

`body: |` 是 YAML **块标量**，其内部每一行都是字面内容 —— 注释必须写在标量缩进
**之外**才生效。于是这 3 行原样进了发布说明，而 markdown 里行首 `#` 是一级标题，
Release 页面顶部就顶出一个巨大标题，内容是"当初为什么改文案"这类内部笔记。

**判据**（用解析器，不靠肉眼）：`yaml.safe_load(WRT-CORE.yml)` 后打印
`Release Firmware` 步骤的 `with.body` 前 3 行 —— 改前正是那 3 条笔记，改后消失。

### 2. 文案写"默认开软件 flow offload"，与代码正好相反 —— 已改写

原文案「加速现状（勿误读）：默认开「软件 flow offload」（nf_flow_table）」。
实际默认是 **off**，三处独立取值一致：

| 位置 | 实际值 |
| :-- | :-- |
| `Files/etc/mt5700/flow-offload` | `MODE=off` |
| `Scripts/ApplyFlowOffload.sh` | `MODE="${WRT_FLOW_OFFLOAD:-off}"` |
| `WRT-BUILD.yml` / `H5000M-MT-AUTO.yml` 的 `FLOW_OFFLOAD` 输入 | `default: 'off'` |

**为什么必须关**：任何 flow offload（软件的一样）都会把连接从 nftables 路径上摘走，
而本固件依赖 nft 在 WAN 出口统一改写 TTL → 卸载一开 TTL 规则零命中 → 运营商按
「多设备共享」丢弃客户端 TCP 包 → **客户端完全没网**。
原文案不但说反了，还漏掉了这条最关键的警告 —— 照它做的人开卸载就会断网，
而症状（路由器自己能上网、客户端全断）极易被误判成 DNS 或信号问题。

新文案改为如实陈述：**两种 offload 默认都是关的**，并写清软件卸载为什么默认关
（与 TTL 统一互斥）、硬件卸载为什么在本机没意义（无 `mtkhnat`/`mtk_wed` + 5G WAN 走 USB）。

### 3. 同一处决策被反转后，全仓残留的 5 处旧结论一并修掉

| 位置 | 原文 | 改为 |
| :-- | :-- | :-- |
| `Config/GENERAL.txt` 硬件加速段 | "默认开「软件 flow offload」" | 两种卸载默认都关 + TTL 互斥说明 |
| `FIRMWARE_OPTIMIZATION_REPORT.md` 第一节表格 | "❌ 关闭（本次改为默认开）"（自相矛盾） | "❌ 默认关闭（2026-09-22 反转）" |
| 同上「关键判断」段 | 推荐"软件 flow offload 是对所有接口都有效的路径" | 加更正框：该结论已作废 |
| 同上第二节 D-1 | "默认开启软件 flow offload" | 按该报告既有"反转"体例标注作废 + 写清新取值 |
| 同上第六节改动文件清单 | 无标注 | 加"历史快照"说明 + 该行就地标注已反转 |

报告另新增**第八节**完整记录本次纠偏（含 8.4 的三条可复用教训）。
`CHANGELOG.md` 的历史条目**不改** —— 那是按日期记录"当时是什么"。

### 教训（可复用）

- **YAML 块标量里的 `#` 是内容，不是注释**；想写说明必须放在标量缩进之外，
  验证一律用解析器打印实际取值。
- **"默认值"以代码为唯一准绳**：同一件事在 `Files/`、`Scripts/`、workflow 输入三处
  各写过一次，任何一处改了都要同步校验另外两处。
- **决策反转后要按"结论句"而非参数名全仓 grep**：只搜 `flow offload` 会漏掉
  "默认开…/ 软件 flow offload…" 这类自然语言形态的旧结论（本轮就漏了 5 处）。

## [2026-09-22 · 编译前全仓审查] 5 项加固（含 1 项纯浪费清理）

触发：用户「准备编译了，全面检查优化下我的项目」。方法：配方层／脚本层／CI 层／覆盖层
四路交叉核对 + 真机取证，逐条**回读原文件**核实（不采信扫描结论）。

**总体结论：全仓 LF 无 BOM、Config 无 `=y/`=n` 冲突、workflow 引用的本地文件无缺失、
克隆重试与缓存 save 拆分均已到位。** 本轮发现的 5 项如下。

### 1. `INSTALL_NET_TUNING` 的完整性断言只覆盖 5/12 个覆盖层文件 —— 补齐

原文手写 5 条 `[ -f ]`（net / wan / nft / rps / hotplug-rps），**漏掉 7 个**，
其中包括后来新增的 `sysctl.d/99-mt5700-conntrack.conf` 与 `99-mt5700-tcp.conf`
—— BBR / fq / 16M 缓冲 / NAT 端口段**全在这两份里**，漏铺就整套网络调优静默失效，
而固件照样能编能刷。

改为**逐文件比对源目录**（`find "$SRC_DIR" -type f` → 每个 `REL` 都必须在 `$DST_DIR` 存在），
白名单随 `Files/` 演进自动更新，不会再漏。

### 2. 可执行位从「按目录写死三条 chmod」改为「按 shebang 判定」

原来只 chmod `uci-defaults/`、`init.d/`、`hotplug.d/net/` 三个目录 —— 将来往
`Files/etc` 下新增目录（如 `hotplug.d/iface/`）就会漏，而漏掉的后果**全是静默的**
（rc.common / uci-defaults / hotplug 直接跳过，都不报错）。
现改为：**凡首行是 `#!` 的覆盖层文件一律 +x**，与目录无关；`.conf`/`.nft`/文本保持 0644。

**验证（隔离测试台，非"看起来对"）**：抽出函数在临时目录跑两种情形 ——
正常路径 `rc=0`、识别脚本 `7` 个、12 个文件全到位；故意让一个文件无法就位时
`rc=1` 且报错**指向具体文件名**（`etc/sysctl.d/99-mt5700-tcp.conf`）。守卫确实能检出。

### 3. `Settings.sh` 三处静默失效风险

- **wifi 配置两个分支都没有 `else`**：若上游同时移走 `*set-wireless.sh` 与
  `mac80211.uc`，SSID / 密码 / 加密方式 / 国家码 / 频宽**全部沿用上游默认**且不报错
  —— 正是本文件开头 `EDIT_FILES` 注释要防的那类。现补 `else` → `::error::` + `exit 1`
  （与该文件既有约定一致：`EDIT_FILES` 找不到目标即硬失败）。
- **判据 `[ -f "$WIFI_SH" ]` 是错的**：`find` 可能返回**多个**路径，而 `[ -f "a\nb" ]`
  恒为假 → 会静默掉到 `elif`、甚至两个分支都不进。改为 `[ -n "$WIFI_SH" ]`
  （下面的 `sed -i ... $WIFI_SH` 本来就支持多文件）。
- **`config_generate` 的 4 条 sed 是本文件里唯一没有守卫的**：文件不存在时 sed 报错但
  脚本无 `set -e`、退出码仍是 0；锚点变了时 GNU sed 零匹配也返回 0 —— 两种都 CI 全绿，
  而后果是"刷完默认 IP 不是 `$WRT_IP`"（这台机器整套 LuCI/SSH/部署都按它连）。
  现补：文件缺失 → 硬失败；锚点不匹配 → `::warning::`（与 `Handles.sh` 的 htmode 检查同规）。

  **真机核实过锚点当前有效**（不是凭猜加断言）：固件内 `/bin/config_generate` 实测含
  `set system.@system[-1].hostname='OWRT'`、`timezone='CST-8'`、`zonename='Asia/Shanghai'`、
  `lan) ipad=${ipaddr:-"192.168.10.1"}` —— 4 条 sed 都真的写进去了。故本轮是**纯防御**。

### 4. `.gitattributes` 覆盖不到固件覆盖层（无扩展名脚本）

原规则只有 `*.txt` / `*.sh` / `*.patch`。而 `Files/etc/**` 里大量是
**无扩展名** 的 init.d / uci-defaults / hotplug 脚本，以及 `.conf` / `.nft` ——
一个都不匹配。在 `core.autocrlf=true` 的 Windows 检出上会被翻成 CRLF，
而 `#!/bin/sh\r` 在设备上的失败方式正是"静默不执行"。
新增 `Files/** text eol=lf`，按目录整片声明，新增文件自动纳入。

（实测当前工作区**全仓 LF、无 BOM、行尾完整**，即尚无实际故障。）

### 5. git 索引 exec 位落实 100755（14 个文件）

`Files/etc/init.d/*`、`Files/etc/uci-defaults/*`、`Files/etc/hotplug.d/net/*` 与
`Scripts/*.sh` 之前都是 `100644`，靠 CI 的 chmod 兜底。按本仓既有约定
（记忆红线：动过 `init.d/*`、`*.sh` 后核对 100755）已在索引里改为 `100755`；
数据文件（`sysctl.d/*.conf`、`*.nft`、`mt5700/flow-offload`）保持 `100644`。

### 6. 停克隆 `VIKINGYFY/packages`（纯浪费，按其自身标准）

穷举核对：上游 8 个目录里，`axonhub`/`luci-app-axonhub`/`gecoosac`/`luci-app-gecoosac`/
`luci-app-wolultra` 在四个 Config 文件里**一次都没出现**，`sing-box`/`luci-app-homeproxy`
明确 `=n` —— **一个包都不进固件**；且第 5 参数名单里的 `luci-app-timewol`/`luci-app-wolplus`
**上游已不存在**，说明名单本身也已过期。与 momo / nikki / openclash / passwall 同属
「克隆了却不编入」，按同一标准停掉。紧邻的那句 `rm -rf ./packages/sing-box …` 保留并
标注「与 viking 克隆配套，别单独删」（重新启用时必须一起恢复）。

### 本轮检查过、判定**无问题**的项（存档，避免下轮重复挖）

| 项 | 核对结果 |
| :-- | :-- |
| `save-always` 是否还在用 | ✅ 3 处**全在注释里**；实际代码已是 `actions/cache/restore@v4` + 显式 `actions/cache/save@v4`，判据 `if: always() && …cache-hit != 'true'`，与官方 action.yml 的正确用法一致 |
| 并发互踩 | ✅ `concurrency.group` 按 CONFIG+MT_MODE 分组、`cancel-in-progress: false`（排队而非互杀） |
| 定时清理后留空窗 | ✅ `Auto-Clean` 在 `schedule` 触发时强制 `KEEP_LATEST=true`（每机型留最新一个）；`H5000M-MT-AUTO` 的 `workflow_run` 还判了 `conclusion == 'success'` |
| 每周全量清缓存导致冷编译 | ✅ `Cache-Clean` 已从定时改为仅手动 `workflow_dispatch` |
| 网络步骤裸奔 | ✅ `Clone Code` 与 `UPDATE_PACKAGE` 各 3 次重试且重试前清残留；curl 均带 `--retry 5 --retry-all-errors` |
| 覆盖层引用已停用包 | ✅ 提到 `irqbalance`/`qmodem` 的位置**全在注释**；唯一实际调用（`mt5700-smp` 停 irqbalance）有 `[ -x ]` 守卫 |
| Config 自冲突 | ✅ 156 个符号、124 个 `=y`，无同一符号既 `=y` 又 `=n` |
| workflow 引用的本地文件 | ✅ 无缺失 |
| WED / HNAT | ✅ 上一轮已归档（见优化报告「附A」），本轮不再重复 |

## [2026-09-22 · 第二轮] 软件转发收包路径与 NAT 端口段补齐（4 项）

基准同上一轮（`好用的固件V0.18.bin`）。本轮把它的 `/etc` 全部摊开逐文件比对：
`sysctl.d`(5)、`init.d`(47)、`uci-defaults`(44)、`hotplug.d`(11)、`modules.d`(89)、
`board.d`(8)、`rc.d`、`config`(21)、`nftables.d`，外加 `/sbin/smp*.sh`、`/sbin/flowtable.sh`
与 `/lib/apk/db/installed`(361 包)。**结论：基线里已没有新的可搬优化项**，本轮的 4 项
来自"我方已有调优自身没做完的部分"（见下）。基线的 11 项差异判定附在文末。

### 改动（4 项）

1. **`net.ipv4.ip_local_port_range`：`32768 60999` → `10240 65535`**
   （`Files/etc/sysctl.d/99-mt5700-conntrack.conf`）

   这是**我们自己上一轮优化的未收尾处**。上一轮把 `nf_conntrack_max` 提到 100000，
   但 SNAT 可用的源端口区间仍是内核默认的 32768-60999 —— **只有 28232 个**。
   一条出站连接占一个源端口，所以单出口的并发 NAT 连接数被这个区间封顶：
   不改这里，10 万只是账面数字，实际到 2.8 万条就不再建新连接。
   本机是单 5G 出口（eth2，CGNAT 段 100.76.8.240/8），所有客户端的出站连接挤一个端口池。

   真机实测默认值：`net.ipv4.ip_local_port_range = 32768	60999`（68231 个端口区间，
   可用 28232 个）。下限特意取 10240 而非 1024，避开"<1024 为特权端口"的惯例认知
   与部分中间盒对低源端口的过滤。

2. **`net.core.netdev_max_backlog`：默认 1000 → 5000**（`Files/etc/sysctl.d/99-mt5700-tcp.conf`）

   前提三条都是本机已成立的事实：① flow offload 必须关闭（否则 TTL 规则零命中）→
   转发全走软件路径；② 收包靠 RPS 分摊到四核；③ **eth2 真机 ethtool 实测协商
   `Speed: 1280Mb/s`**。

   1280Mb/s 按 1500B 满载约 106kpps，RPS 分到四核后每核约 26kpps ——
   每 CPU 1000 包的积压只够缓冲约 38ms。5G 突发一旦超过它，内核**直接丢包且不打日志**，
   表现为"测速忽高忽低、重传涨了却查不到原因"。提到 5000（约 190ms）代价极小：
   队列里存 skb 指针，不复制数据。

3. **`net.core.netdev_budget`：默认 300 → 600**（同上）

   RPS 把包分散到四核后，每核单轮 300 包成为瓶颈：包没处理完就被下一轮抢占，
   CPU 时间耗在反复进出软中断上。有 `netdev_budget_usecs` 兜底，不会无界占 CPU。
   （⚠️ 2026-09-22 更正：此处原写 2000μs，是照抄内核文档的印象值；本机 6.18.52
   实测 `sysctl net.core.netdev_budget_usecs` = **20000μs**。结论不变，数字已订正。）

4. **修正 `99-mt5700-conntrack.conf` 里一个错误数字**（注释，非功能）

   原文写"`nf_conntrack_buckets = 65536`（本机默认即 65536，两边一致）" ——
   **真机读回是 63488**（`0xF800`）。来由已查明：buckets 在 `nf_conntrack` 模块加载
   那一刻由当时的 `conntrack_max` 推导，之后再 sysctl 抬高 `conntrack_max` **不会**让它重算。
   结论不变（63488 vs 65536 差 3%，不值得在开机阶段重建哈希表），但数字必须写准 ——
   整段推理只依赖这一个数字成立，写错等于把后续判断全部带偏。

### 本轮"判定为不做"的 11 项（附证据，防止以后重复挖）

| 项 | 基线做法 | 本机/本仓库 | 判定 |
| :-- | :-- | :-- | :-- |
| **WED**（无线硬件卸载） | `/etc/modules.d/mt7996e` 写 `wed_enable=0`（自己也关） | 无该文件，默认 `N`；`mt7996e.ko` 里 17 处 wed 符号齐全 | ❌ **不可用**：平台设备 `15010000.wed`/`15104800.wdma` 在设备树里，但 `/sys/bus/platform/drivers/` 下**无驱动**、`modules.builtin` 无 wed → 上游未完成，写了也不生效 |
| **MTK `smp_util` / `smp-dispatch.sh`** | `smp-mt76.sh` 在 MT7987 上走 MT7988 分支 → 结果**把所有接口 rps 置 0**，并按硬编码 IRQ `221-224/229` 绑核 | 自写 `mt5700-rps`（实测 e/f 分档）+ `mt5700-smp`（贪心均衡） | ✅ **我方更优**：本机以太网**只有 2 个 IRQ**（`GICv3 229/230`），基线假设的 4 个 RSS ring 不存在 → 它在本机等于"关掉 RPS"；而我方实测 RPS 分摊把 CPU0 的 NET_RX 从 42% 压到 15% |
| `disable_gro_fraglist`（rx-gro-list off） | 有 | **已在 `mt5700-smp` 内** | ✅ 等价（真机 `ethtool -k` 各口均 `rx-gro-list: off`） |
| 风扇温控 | 闭源 `/usr/bin/fancontrol` + uci 曲线 | `luci-app-h5000m-fancontrol 2.1.0` 已装；真机 `cooling_device0=pwm-fan cur=1/3`、`hwmon2 pwm1=128` | ✅ 已有 |
| `10-default.conf` / `11-nf-conntrack.conf`（上游） | 标准内容 | 真机逐行一致（含 `arp_ignore=1`、`kernel.panic=3`、`bpf_jit_enable=1`） | ✅ 一致，不必动 |
| `99-h5000m-network.conf`（BBR/fq/16M） | 8 行 | 我方是**超集**（+`tcp_fastopen`/`somaxconn`/`max_syn_backlog`/`rp_filter`/`no_metrics_save`/`mtu_probing`/`slow_start_after_idle`） | ✅ 已超越 |
| conntrack | 用上游默认（**无 `max` 行**） | 我方 `max=100000` + `expect_max=16384` | ✅ 已超越 |
| 桥接 netfilter（`11-br-netfilter.conf`/`12-br-netfilter-ip.conf`） | 默认关、为 docker 开 iptables | 本机内核**无** `/proc/sys/net/bridge/`（`kmod-br-netfilter` 未编入） | ⚪ 不适用：我们用 nft `inet fw4`，不依赖 iptables 桥接兼容层 |
| **LAN/WAN 物理口定义** | `board.d/02_network` 写 `ucidef_set_interfaces_lan_wan eth1 eth0`（lan=eth1, wan=eth0） | 我方 `lan=eth0(br-lan)`、`wan=eth1` | ✅ **我方对**：真机 `eth1` 的 `phydev` == `mdio-bus:0f`，而该 LED 的名字就是 **`mdio-bus:0f:red:wan`** → eth1 是被 DTS 标注为 WAN 的口。基线与本机 DTS 标注相反 |
| `luci-app-package-manager` + `--allow-untrusted` 补丁 | 有该包 | 包已在（269 依赖链带入），补丁**真的进了固件**：真机 `grep -c allow-untrusted /usr/libexec/package-manager-call` = 1 | ✅ 一致，补丁不是死代码（这是本轮专门去验的一条"CI 补丁会不会静默落空"） |
| `mtk-puncture`（Wi-Fi 7 打孔） | 有 LuCI 包 | 驱动 `mt76*.ko`/`mt7996e.ko` 中 `punctur` **零命中**、netifd 脚本层零命中 | ❌ 不可搬（上一轮已定案） |

### 明确**不采纳**的（那不是优化，是补功能）

基线有、我方没有且本轮判定不做的：UPnP(`miniupnpd-nftables`)、`docker` 全家桶、
`nikki`/`mihomo-alpha`（我方用 openclash）、QModem 全家桶、`bind-dig`/`lsof`/`jq`/`bc` 等
命令行工具、WAN 口 `red:wan` 指示灯（我方 LED 资源已存在但未启用 —— 属新增可见行为，
与本轮"实打实优化"不同类，如需启用另议）。

## [2026-09-22] 以基线镜像为基准的三项实打实优化（qdisc / socket 缓冲 / 停用 packet steering）

基准：`好用的固件V0.18.bin`（OpenWrt 25.12-SNAPSHOT，kernel 6.12.94，MT7987）。
比对方式：解包其 squashfs 读取 `/lib/apk/db/installed`（361 个包）、`99-h5000m-network.conf`、
`99-h5000m-clean-defaults`、sysctl、`/etc/rc.d`，再逐项对照本机（kernel 6.18.52）与本仓库现状。

> 说明：本轮只保留**能实打实改进行为**的项。基线有而我们没有、但纯属功能补齐的
> （UPnP、`tcpdump-mini`、LuCI 界面语言）**一律不做** —— 那是"补东西"不是"优化"。

### 采纳（3 项）

1. **停用 netifd 的 packet steering**（`Files/etc/uci-defaults/99-mt5700-net` + `Files/etc/init.d/mt5700-rps`）
   —— 本轮最实质的一项，是一个**真 bug 修复**。

   两者都写 `/sys/class/net/*/queues/*/rps_cpus`，而 packet steering 用的是
   `cpu_mask(cpu) = 1 << cpu`（**每队列单核掩码**），正是实测三档里最差的一档
   （NET_RX 95% 压在一个核）。更要命的是它注册了 `network` / `firewall` / `interface.*`
   三个触发器：**用户在 LuCI 保存一次「网络」或「防火墙」配置就会 reload 它**。

   实锤（2026-09-22，本机 4 核 MT7987，全程未动真实接口）：

   | 阶段 | 无线 `phy0.1-ap0` | 5G `eth2` |
   | :-- | :-- | :-- |
   | `mt5700-rps` 设完 | `e`（避开无线中断核 CPU0） | `f`（全核） |
   | 触发 config.change（firewall / network 均测） | **`4`** | **`8`** ← 被改回单核最差档 |
   | 停用后再触发同样事件 | `e` 保持 | `f` 保持 |

   修法要两道，缺一不可：
   - `uci-defaults`(S10)：**删掉** `network.globals.packet_steering` 键 + `disable`（管下次及以后开机）
   - `mt5700-rps`(S95 > S25)：写掩码前 `stop` 掉本次开机已起起来的实例（rc 序列的 `S*` glob
     开机就展开完了，`disable` 挡不住本次）。实测注册计数 1→0，之后两次配置变更掩码纹丝不动。

   ⚠️ **不能**用 `packet_steering='0'` 当"关掉"：`reload_service()` 无条件执行 ucode，
   参数 `0` 会让 `set_netdev_cpu()` 写 `val = 0`，把 RPS **整个关掉** —— 比单核更糟。

2. **`net.core.default_qdisc` 由 `fq_codel` 改为 `fq`**（`Files/etc/sysctl.d/99-mt5700-tcp.conf`）
   本文件已把拥塞控制固定为 BBR，而 BBR 自带 pacing；fq_codel 会在其上再叠一层靠丢包控延迟的
   CoDel —— 这个丢包对 BBR 是假信号，会让它误判拥塞而降速。fq 是 BBR 文档推荐的配套 qdisc，
   基线实测同为 `fq`。作用域仅为「默认 qdisc」，启用 SQM 的接口仍由 cake 覆盖。
   已真机验证：`sch_fq.ko` 在镜像内，14 项经设备真实 sysctl 加载器全部 rc=0、回读一致、ping 0% 丢包。

3. **socket 缓冲上限 4M/8M → 16M**（同上）
   5G 下 RTT 20~80ms、按 500Mbps 算，BDP ≈ 5MB，原上限会在高 BDP 时刻卡住窗口。
   这几项只是天花板，内核按连接实际需求动态分配，不预占内存。基线同为 16M。

### 写成测试/注释以防再补的"证伪项"

- **`Files/etc/hotplug.d/net/31-mt5700-smp`（已删除）**：本想照 `30-mt5700-rps` 那一套，
  给中断亲和也补一个"接口出现时重跑"的触发。前提被真机推翻 —— `dmesg` 显示
  eth 0.98s、xhci 3.0s、mt7996e 10.7s，**所有相关中断在内核阶段就注册完了**，
  远早于 S99；不存在"中断晚于服务启动才出现"的窗口，这个 hotplug 永远修不到任何东西。
- **UPnP / `tcpdump-mini` / LuCI 语言**：属"基线有我们没有"的功能补齐，非优化，已撤。
- **主机名 / 时区**：`Scripts/Settings.sh` 在编译期就把 `config_generate` 的 hostname 改写为
  `$WRT_NAME`（默认 `OWRT`，README 有记录）、并强制写入 `Asia/Shanghai` + `CST-8`。
  uci-defaults 开机后才跑，在这里写会静默覆盖用户入参并与 README 矛盾。要改请改 `WRT_NAME`。

另外只保留了 LuCI **界面语言**（`lang` 由 `auto` → `zh_cn`）与主题 —— 真机实测当前确为 `auto`
（浏览器非中文时首次进 LuCI 是英文），这是真缺口，且无对应编译期设置。设值前用
`uci -q get luci.main` 判段存在，避免没装 LuCI 时凭空建段。

### 验证

- `ash -n` 校验（设备端真实 shell）：5 个脚本全部 RC=0；所有改动文件 CRLF=0。
- sysctl：用设备真实加载器 `sysctl -p` 加载新文件，**rc=0、14 项全部接受**，回读一致；
  `sch_fq.ko` 在镜像内（qdisc 切换有模块自动加载兜底）。改后 ping 0% 丢包。
- 包名核对：5 个新增包与基线 `/lib/apk/db/installed` 中的名字**完全一致**
  （`miniupnpd-nftables` / `luci-app-upnp` / `luci-i18n-upnp-zh-cn` / `tcpdump-mini`），
  无凭空捏造的包名。
- `Config/GENERAL.txt` 全文件重复 CONFIG 行检查：**无重复**。

## [2026-09-22] 还原 MT5700M 的 fail-fast 守卫（删除误补回的配置层 + 清理死代码）

### 背景：一次判断失误的纠正

`Config/MT5700M.txt` 的 git 史是 `f659ca9 建 → 93bb168 删 → 456ed7b 补回`。
第二次"补回"是错的：原设计**故意删掉该配置文件**，让 `ApplyMTMode.sh` 的 MT5700M
分支充当守卫 —— 误选即 `::error::缺少 Config/MT5700M.txt` 终止，避免静默编出半残固件
（见 `FIRMWARE_OPTIMIZATION_REPORT.md` 的「产物收敛」节）。当时把"脚本要求文件存在、
而文件不在"读成了缺文件的 bug，补回去等于**把安全网拆了**：误选 MT5700M 不再立即
报错，而是真的会去克隆 QModem、折叠 `luci-app-mt5700m`、白烧几分钟到几小时，
最后产出一套**从未真机验证**的固件。

### 本次改动

- **删除** `Config/MT5700M.txt`，恢复"缺文件即 fail-fast"的原设计。
- `Scripts/ApplyMTMode.sh`：MT5700M 分支改为**明确报错终止**（报清原因：方案 A 依赖
  QModem 的 `sms-tool_q` / `ubus-at-daemon`，其版本号 `3.4.0-rc.3` 对 apk 非法，
  且功能与方案 B 重复），并删掉第二个 case 里已不可达的叠加分支。
- `Scripts/VerifyMTMode.sh`：MT5700M 分支从"校验必须选中"改为**守卫式报错**
  （防有人绕过 ApplyMTMode 直接手改 `.config` 或 workflow）。
- `Scripts/Packages.sh`：清理**永不执行**的死代码 —— QModem feed 克隆、
  `FIX_QMODEM_VERSION`（为 `-rc.N` 版本号改写写的补丁，随方案 A 一起无用）、
  `FOLD_MT5700M`（75 行 monorepo 折叠 + cargo 交叉编译，整段删除）、
  case 里的 MT5700M 克隆分支；合法值白名单收敛为 `""|MT5700`。
- 注释同步：`Config/GENERAL.txt` 与 `.github/workflows/WRT-CORE.yml` 的 MT_MODE 说明
  标注 MT5700M 已停用 + 守卫语义；`README.md` 显式写明"没有 MT5700M.txt 是有意的，
  别再补回来"。

### 验证（本地 dry-run，非真机）

- `bash -n` 三个脚本均通过。
- `ApplyMTMode.sh`：`MT5700M` → rc=1 且报「已停用」；`MT5700` → rc=0，正确叠加
  `Config/MT5700.txt` 并把 `luci-app-mt5700m` / `sms-tool_q` 置 n；空模式 rc=0；
  非法值 rc=1。
- `VerifyMTMode.sh` 六个场景：MT5700 干净通过；MT5700 被 `mt5700m=y` 或被
  `sms-tool_q=y` 污染时分别拦截；MT5700M 报「已停用」；空模式干净通过、被污染拦截。
- `Packages.sh` 残留检查：`UPDATE_PACKAGE "qmodem"` / `FOLD_MT5700M` /
  `FIX_QMODEM_VERSION` 均为 0 处。

## [2026-09-21] 借鉴分析：ATang007ZH/Action-237-immortalwrt-mt798x-24.10

对该仓库做了全量核查（README、14 个 workflow、6 个 diy 脚本、`files/`、343KB 的
`.config`），结论是**整体不可借鉴，仅采纳 1 项 CI 防护**。依据如下：

### 判定不可借鉴的三条硬理由

1. **源码不含你的 SoC**：它编译的是 `padavanonly/immortalwrt-mt798x-24.10`（237 大佬，
   闭源 MTK 驱动）。其 `target/linux/mediatek/dts` 里最高只有 **mt7988**，
   **没有 mt7987，也没有 hiveton-h5000m**。你的 MT7987A 根本不在支持列表内。
2. **目标机不同代**：360T7 / JCG Q30 Pro / CMCC-A10 全是 **MT7981**（config 里
   `CONFIG_WARP_CHIPSET="mt7981"`、TF-A 只有 mt7981/mt7986 变体可证）。
3. **内容与你的定位相反**：仓库自我定位是"主路由含 **passwall**、ddns-go、vlmcsd"，
   diy-part1 的唯一作用就是插入 passwall 的 feed；diy-part2 只做改默认 IP /
   hostname / IMG_PREFIX。这些与我们已删除代理类的方向正好相反。

### 逐项核查后不采纳的部分

| 项 | 不采纳的理由 |
|---|---|
| 内核 6.6 + 闭源驱动 | 我们已定案：vermagic `6.6.94` vs 本机 `6.18.52` 拒载，且主 WAN 走 USB 口，HNAT/WED 命中率≈0 |
| `files/etc/opkg/distfeeds.conf` | 我们包管理器是 **apk 不是 opkg**，无关 |
| 换 `kenzok8/golang` 1.25 源、删 feeds 自带核心库换 passwall 版 | 纯代理链路，我们不用 |
| `CONFIG_KERNEL_DEBUG_KERNEL/DEBUG_INFO=y` | 反例：开内核调试增大体积、降性能，我们**没有**开，保持 |
| `CONFIG_KERNEL_CGROUP_SCHED / FAIR_GROUP_SCHED / RT_GROUP_SCHED` | cgroup 调度只在跑容器时有用，这台不跑 docker，开了反而增加调度开销 |
| `CONFIG_KERNEL_IPV6_SEG6_LWTUNNEL` | SRv6，用不上 |
| `CONFIG_ZRAM_DEF_COMP_LZORLE` | 真机 Swap used = 0（内存从未换出），换算法收益为 0 |
| `CONFIG_KERNEL_NF_CONNTRACK_TIMEOUT` | 需配套 per-conntrack 超时策略规则，我们没有该需求；且 6.18 与 6.6 的配置符号不保证一致 |
| 工作流**完全没有缓存**、`make -j$(nproc) \|\| make -j1 V=s`、ubuntu-22.04 | 我们已全面更优：三对 restore/save 缓存、失败重试**保持并行**、ubuntu-latest |
| `CONFIG_PACKAGE_eip197-mini-firmware` / `kmod-cryptodev` / `kmod-nf-flow` | 我们**已有**（H5000M-WIFI-YES.txt 里还多了 `kmod-tls`） |

### 采纳的 1 项：`make download` 后清理残缺小文件

`Download Packages` 步骤末尾新增：

```sh
find dl -size -1024c -exec ls -l {} \;
find dl -size -1024c -exec rm -f {} \;
```

抓取失败时 `dl/` 会留下几十~几百字节的 HTML 错误页，**make 看到文件已存在就跳过**，
直到编译阶段才报 checksum mismatch —— 那时已白烧几小时，且失败点离根因很远。
先 `ls` 保留证据再删除。安全性：误删的合法小文件 make 会自动重新下载，
不会破坏构建，代价只是多抓几百字节。

## [2026-09-21] 缓存策略重构：失败也保存 + Rust 产物缓存（上轮留待项落地）

上一轮全仓检测留待的两项缓存问题，本轮核实后落地。

### 改动 1：「失败也保存缓存」从未生效过 → 拆 restore/save 修复

**核实**（直接读 actions/cache@v4 的官方 `action.yml`）：
- 第 33-34 行明确标注 `save-always` 为
  *"does not work as intended and will be removed in a future release"*（deprecation）；
- 第 44 行 `post-if: "success()"` —— post 阶段的自动保存**只认成功**。

也就是说仓库里两处 `save-always: true` 写了等于没写：**编译失败时，当次的所有进展
（ccache 命中、已编好的工具链、下载完成的源码包）全部丢弃**，下次从零开始，
恰好踩中原注释自己担心的「失败 → 无缓存 → 再失败」死循环。

**修复**：`WRT-CORE.yml` 的两处 `actions/cache@v4` 改为 `actions/cache/restore@v4`，
并在 `Compile Firmware` 之后新增三个显式的 `actions/cache/save@v4` 步骤
（`if: always()` → 编译失败也保存）。每条 save 都带
`steps.<id>.outputs.cache-hit != 'true'`：同 key 已存在时跳过 ——
与原 post 行为一致，保证一周内条目不增殖（WRT_CACHE_WEEK 哲学不变）。

配对一致性已脚本核对：三对 restore/save 的 key 与 path 完全一致。
已知边界（注释中写明）：runner 被 6h 硬上限**直接终止**时 save 步骤同样不执行，
该场景只能靠缩短编译时间规避。

### 改动 2：Rust 产物缓存（新增，预计每次构建省 3~5 分钟）

`luci-app-mt5700`（MT5700 Console 后端）每次构建都**全量重编** tokio / serde /
chrono / ureq 依赖树（数分钟）。新增 `Check Caches (Rust)`：

| 缓存内容 | 说明 |
|---|---|
| `./wrt/package/luci-app-mt5700/src/target` | cargo 编译产物。恢复后依赖 crate 直接复用，只重编 at-webserver-rust 自身（源码变更部分，约几十秒） |
| `~/.cargo/registry` + `~/.cargo/git` | 依赖下载（省 30~60 秒） |

实现要点（均已写进 workflow 注释）：
- **必须放在 `Custom Packages` 之后 restore**：target 目录在包内（`src/Makefile` 把
  `CARGO_TARGET_DIR` 写死为 `$(CURDIR)/target`），而包是 `Packages.sh` 刚 `git clone`
  出来的 —— 先 restore 会让克隆目标目录非空而直接失败。为不改上游仓库，
  选择直接缓存包内路径。
- `~/.rustup` **不缓存**：rustup 安装在 `Packages.sh` 里已完成，此处恢复已晚；
  且体积 ~1GB、收益仅 1~2 分钟，不划算。
- key 用 `WRT_CACHE_WEEK`（周）：cargo 自身的增量机制（target 内 fingerprint）已能
  正确处理源码变化，key 只决定「是否跳过 save」，与工具链缓存同一哲学。

### 附：本轮其余核查结论（未改动）

| 项 | 结论 |
|---|---|
| `Config/GENERAL.txt` 116 个 `=y` 包精简 | 逐一过目，**没有**像 irqbalance 那样持有实测反对证据的（分区工具组、smartmontools、libimobiledevice 等各有使用场景）—— 按「不猜测」原则不动 |
| `Cache-Clean.yml` | 用 `gh cache delete --all`（全删），新增的 `rust-mt5700-` key 前缀无需补清单 |
| restore-keys 部分命中的 save 行为 | `cache-hit` 仅在精确命中时为 'true' → 周切换时保存新 key、旧 key 交 LRU 回收，行为正确 |

## [2026-09-21] 全仓检测一轮：修掉 3 处静默失效 + CI 健壮性加固

对 34 个文件做了系统性审查（脚本层 / 固件覆盖层 / workflow 层三路并行），
逐条验证后落地以下改动。

### 修复 1（真 bug）：无线 RPS 一直没生效，且无任何日志

`init.d/mt5700-rps` 的 `wait_ifaces()` 只等 `br-lan` —— 而它由 netifd 极早建立，
于是函数几乎立刻返回；真正要等的无线接口由 wpad 更晚建立
（真机实测 mt7996e 约开机 12 秒 probe、**25 秒**才进入 ap0 模式），
S95 那一刻必然还不存在。

后果被"告警条件"掩盖：告警只在「一个队列都没设上（`wifi_n=0` **且** `other_n=0`）」
时触发，而有线队列已经设上了 → 连日志都没有。真机取证也印证：
`phy0.1-ap0/queues/rx-0/rps_cpus = 0`（完全没设），有线的三个接口都是 `f`。

三处修复：
1. **新增 `Files/etc/hotplug.d/net/30-mt5700-rps`**：接口 `add` 事件上重跑
   `mt5700-rps start`（幂等、毫秒级），从时序上兜住 init.d 的窗口；只对无线接口名触发。
2. `wait_ifaces()` 改为**明确只等 br-lan** 并把超时从 20 秒缩到 10 秒，
   不再"假装在等无线"（注释写明分工）。
3. `wifi_n=0` 时补一条 info 日志，避免下次再静默。
4. `Packages.sh` 的 `INSTALL_NET_TUNING` 增加 hotplug 目录的创建、`chmod 0755`
   与**硬断言**（缺了它同样是"不报错但功能没生效"）。

### 修复 2：CI 健壮性（4 项）

| 位置 | 问题 | 改法 |
|---|---|---|
| `WRT-CORE.yml` core job | 5 个 workflow 全都没有 `concurrency`。定时链（Auto-Clean → H5000M-MT-AUTO）与手动 WRT-BUILD 会重叠，两者共用同一套缓存 key，而 `actions/cache` 对已存在的 key 是**跳过保存** → 后完成的那次白编；且 Tag 含日期，同一天产出两个 Release | 加 `concurrency`，`cancel-in-progress: false`（后来者排队，不杀前一个） |
| `WRT-CORE.yml` Clone Code | 整条流水线第二步是裸奔的 `git clone`，一次瞬时抖动就让后续几小时构建归零（上面的 curl 早就有 `--retry 5`） | 加 3 次重试（重试前先清理残目录，否则会因 path already exists 直接失败）+ 失败即 error |
| `WRT-CORE.yml` 打包 | `WRT_KVER` 用 `find ... -exec` 可能输出**多行**，多行值写进 `$GITHUB_ENV` 会以 `Invalid format` 让该步骤失败（旁边的 `WRT_LIST` 早就用 `tr` 收敛过） | 末尾加 `\| head -n 1` |
| `Auto-Clean.yml` | 定时触发时 `inputs` 为空 → 判定为"不保留" → **先删光所有 Release**，随后构建要 3~6 小时；这段窗口仓库里一个固件都没有，想刷回上一版都做不到 | schedule 事件一律按 keep-latest 处理，每个机型至少留最新一个 |

### 修复 3：5 处 sed「假成功」（GNU sed 零匹配也返回 0）

`Handles.sh` 里所有 `if sed -i ...; then echo "xxx has been fixed!"` 都是假的：
零匹配照样返回 0，于是永远打印成功。上游一旦改版，修补不会写入但 CI 全绿。

改为**先 grep 锚点再动手**，并区分三种情况（文件不存在 / 锚点不匹配 / 已是最新）。
覆盖 argon 配色、mini-diskmanager 菜单位置、tailscale `/files`、rust `ci-llvm`、honk `/var`。
其中 **PMC（package-manager-call）那条后果最重**：失效会让真机上 LuCI「软件 → 安装」
装不上任何自编译 apk，错误信息只有一句 untrusted，极难定位到是 CI 这一步没生效。
该条失效时输出 `::warning::`（不 `exit 1`：它只影响手动装包这一次要能力，
为它中断几小时构建不划算）。

### 修复 4：补上缺失的 `Config/MT5700M.txt`

`ApplyMTMode.sh` 的 MT5700M 分支要求该文件存在，缺了直接
`::error::缺少 .../Config/MT5700M.txt` + `exit 1` —— 但它**此前并不存在**，
意味着切到 MT5700M 必失败，且 `Packages.sh` 会先克隆 + 折叠 + cargo 编 Rust 后端
白烧几分钟才报错。已按上游 Makefile 核实的依赖补齐（已确认
`LUCI_DEPENDS := +luci-base +ubus-at-daemon +sms-tool_q`，kmod 侧 GENERAL.txt 齐备），
文件内注明"自 2026-09-15 起未用于出固件，未经真机验证"。

### 清理与修正

- `VerifyMTMode.sh`：MT5700/MT5700M 两个分支各有一段 `grep -qE '...=[ym]'` 的
  "反向依赖探测"，与上一行 `check_must_not` 判据**完全相同**（`pkg_selected` 用的就是
  `=[ym]`），且只 `echo ::error::` 却不置 `FAIL=1` → 已删除，拦截统一走 `check_must_not`。
- `Packages.sh`：`HONK` 段的 `WRT_FILES` 回退路径 `$(pwd)/..` → `$(pwd)/../..`
  （cwd 是 `wrt/package`，原写法得到 `wrt/wrt/files`；Actions 里 `GITHUB_WORKSPACE` 恒有值，
  所以只在本地调试时暴露）。
- 注释不实修正：
  - `99-mt5700-net` 头部说软件卸载"默认打开（MODE=auto…）" → 实际**默认 off**
    （`Files/etc/mt5700/flow-offload` 与 `ApplyFlowOffload.sh` 都是 off），
    且 auto 分支里的 TTL 探测只在显式选 auto 时才走到；
  - `99-mt5700-conntrack.conf` 说 buckets "本机默认 63488"，与该文件自己第 41 行
    （也是实测值 65536）自相矛盾 → 已更正为 65536；
    🔴 **2026-09-22 第二次更正：这次改反了。** 当时是"以文件里的另一句话为准"来消矛盾，
    没有回真机复核。真机读回确实是 **63488**（`0xF800`），第一次写的才是对的 ——
    来由是 buckets 在 `nf_conntrack` 模块加载那一刻由当时的 `conntrack_max` 推导，
    之后再用 sysctl 抬高 `conntrack_max` **不会**让它重算。现已改回 63488 并写明机制。
    **教训：同一份文件里两处数字冲突时，必须回真机量一次，不能靠"哪句话更可信"来裁决。**
  - `mt5700-rps` 里 IRQ 累计次数写 140 万、另两个文件写 186 万 → 统一改为"百万次量级"，
    避免三个文件三个数字；
  - `Packages.sh` 的 viking 注释说"避免它们出现在 package/ 里"，实际删除循环只 find
    `../feeds/...`，克隆出来的 `./packages/` 里那些包仍在 → 已按真实行为改写。
- `Handles.sh` 的 honk 段补标注：honk 已停用（`INSTALL_HONK_PREBUILT` 被注释），
  这段目前恒不命中，属"随它一起启用"的配套修补，勿删。

### 评估后未改动（附理由）

| 项 | 理由 |
|---|---|
| `Packages.sh` 的 `UPDATE_VERSION()` 无调用点 | 它是上游模板函数、注释里带用法示例，删掉会让 fork 用户少一个工具；且不是错误逻辑，不算残留 |
| `mt5700-rps` 对非无线接口统一用全核掩码 `f` | 与它注释里"应避开硬中断核"的原则不完全一致，但无线侧已按硬中断核动态排除；有线/USB 侧实测全核分散更好，改动需重新压测，本轮不动 |
| `12-mangle-ttl-128.nft` 依赖 fw4 的 `$wan_devices` | 若 wan 区被改名会导致符号未定义、整表加载失败。真机 `nft -c` 当前通过；写死 `{ eth1, eth2 }` 会失去动态性，暂保持现状并记录风险 |
| `WRT_TEST` 在两个调用方类型不一致（boolean vs 字符串） | 靠隐式转换，当前行为正确；统一会动到调用契约，收益低于风险 |
| `actions/cache@v4` 的 `save-always` 无效 | 官方已标注该输入不按预期工作（其 `post-if` 仍要求 `success()`）。正确改法是拆 `cache/restore` + `cache/save`，涉及缓存策略重构，单独一轮做更稳 |

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

**真机实测（2026-09-21 20:38，用 setsid 自动回滚守护执行，与 SSH 会话解耦）**：
改 `htmode=EHT160` → `wifi reload` → **5 秒**后 AP 恢复，`iwinfo` 报
`Mode: Master  Channel: 36  HT Mode: EHT160`（Center Channel 50，即 36-64 的 160MHz 块），
**未触发 DFS 阻塞**。已关联的客户端自动重连；其中一个 **Wi-Fi 6** 客户端仍按
`160MHz HE-MCS 11 HE-NSS 2` 协商（tx 2401.9 Mbit/s），证明**向下兼容无损** ——
EHT 的 4096-QAM 收益将在 Wi-Fi 7 客户端接入时体现。

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

