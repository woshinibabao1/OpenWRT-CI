# 更新日志

## [2026-10-07 凌晨 2] WED 补丁 v2：修掉 CI 实测炸掉的 modpost 失败

上一条提交（`eb294c0`）的补丁**经 CI 实测编译失败**（run `37503259547`，
在 `Compile Firmware` 阶段，烧了 24 分钟）。守卫 C1~C23 全绿却没拦住 ——
因为它们只查"补丁长什么样"，没查"补丁引入的符号能否被外部模块解析"。

### 失败原因

    ERROR: modpost: "wed_debug" [mt7996/mt7996e.ko] undefined!
    make[7]: *** [scripts/Makefile.modpost:147: Module.symvers] Error 1

事实链：

- `mtk_wed.c` 编进 **`mtk_eth.ko`**（Makefile 第 8 行 `mtk_eth-y += mtk_wed.o`），
  `wed_debug` 是它的模块参数，未 EXPORT_SYMBOL。
- `mtk_wed.h` 被 **`mt7996e.ko`**（mt76 驱动，外部模块）也 include。
- 头文件里的 `static inline mtk_wed_device_attach()` 是**展开进那个模块**的，
  于是它去引用 `mt_eth.ko` 里不可见的 `wed_debug`。

铁律：**模块之间不能用未 EXPORT 的变量通信。头文件里新增的任何标识符，
都必须是所有消费者都能解析的符号。** 我 v1 只想到"符号会不会被 GC"，
漏了"这个符号在别的模块可见吗"—— 两件事完全不同。

### 修法

头文件里**完全移除** `wed_debug`（不留任何间接引用），只剩一条无条件
`pr_info`。它只在 probe 时触发一次、不是热路径，量级可忽略。
其余诊断全部放回 `mtk_wed.c`（那里可以随意读自己的模块参数）。

否决过的替代方案：给 `wed_debug` 加 `EXPORT_SYMBOL_GPL`。
那会让 `mt7996e.ko` 硬依赖 `mtk_eth.ko` 加载 —— `mtk_eth` 起不来时
WiFi 直接瘫，对一台要一直在线的 CPE 来说风险远大于当前问题。

### 顺带发现并补上的静默失败点

读真实源码时发现 `mtk_wed_attach()` 里 `if (ret) return ret;`
（`try_module_get` / `pci_domain > 1` 失败）**完全不打任何日志**，
是比 `mtk_wed_assign()` 更靠前、也更难猜的失败出口。已补 `wed_diag`。

另外诊断宏 `wed_diag` 定义处的注释现在写明了"头文件不得引用它"及原因，
避免后人（或未来的我）再犯同一个错。

### 闸门

C22 新增两条断言，把这次的真实故障钉死：

- **C22-e** 头文件 hunk 里不得出现 `wed_debug`（`sed -n '/^diff --git a\/include\/linux\/soc\/mediatek\/mtk_wed\.h/,$p'` 之后不得有 `^+.*\bwed_debug\b`）
- **C22-f** `wed_debug` 的定义与 `module_param` 必须都还在补丁里
  （后者是刷机后判定"补丁有没有进固件"的唯一可靠依据
  `cat /sys/module/mtk_eth/parameters/wed_debug`）

反向变异 6 组（M0 基线 / M10 复现本次故障 / M11 删定义 / M12 删 module_param /
M13 去 __used / M14 重复链接 / M9 复原），并给变异脚本加了
**开跑前基准自检**（备份里必须已有 `__used` 且头文件 hunk 必须干净，
否则直接 ABORT）—— v1 变异脚本就栽在"备份被上一轮污染"上。

## [2026-10-07 凌晨 1] 把 WED 补丁正式入库：修掉一个会让编译失败的错误改法

用户刷了新固件后我上机验收，四条判据（`wed-diag` 日志 / `mtk_soc_wed_ops` 符号 /
WED 中断 / `attaching wed device`）全部与刷机前一致 —— 无线硬件加速没变化。
追查发现：**补丁此前只躺在本地 `.workbuddy/tmp/`，从未进过仓库**，
所以「本仓 CI 编出的固件」在定义上就不可能包含它。
（本轮顺带更正我自己上一次的措辞：说它是「上游原版」是不准确的 ——
固件确实是最新的、含本仓全部改动，缺的只是这个从未提交的补丁。）

### ★ 一、上一版补丁是**错的**，会直接让编译失败

v1 版补丁改了 `drivers/net/ethernet/mediatek/Makefile`：

```diff
 obj-$(CONFIG_NET_MEDIATEK_SOC_WED) += mtk_wed_ops.o     ← 第 12 行，原本就有
+mtk_eth-$(CONFIG_NET_MEDIATEK_SOC_WED) += mtk_wed_ops.o ← 我加的
```

两行并存 ⇒ 同一个 `mtk_wed_ops.o` 同时进 `vmlinux` 与 `mtk_eth.ko`
⇒ `EXPORT_SYMBOL_GPL(mtk_soc_wed_ops)` 被定义两次
⇒ 链接期 **multiple definition** ⇒ **内核阶段编译直接失败**，
且失败点离根因很远（已烧掉几十分钟）。

**正确做法**：不碰 Makefile 的 `obj-y` / `mtk_eth-y` 关系，
只给那个唯一的数据符号加 `__used`。对照真实源码确认：

```
mtk_wed_ops.c 全文只有 5 行（v6.18.54）：
    const struct mtk_wed_ops __rcu *mtk_soc_wed_ops;
    EXPORT_SYMBOL_GPL(mtk_soc_wed_ops);
```

整个单元**没有任何代码**，只有一个数据符号 —— 这正是
`--gc-sections` 会把它丢掉的形态，也印证了「WED 断因是链接期丢失」这个工作假设的合理性。
（`__used` = `__attribute__((__used__))`，定义在 `include/linux/compiler_attributes.h:349`。）

### 二、本仓从来没有打补丁的能力，本次新增

CI（`WRT-CORE.yml`）此前**只有** `cat >> .config`，没有任何拷贝/打补丁动作，
仓库里也没有补丁目录 —— 补丁文件放进仓库也不会生效。
本次新增：

| 新增 | 作用 |
| :-- | :-- |
| `Patches/0980-wed-diag.patch` | 强制 `__used` + `wed_debug` 诊断日志 |
| `Scripts/ApplyPatches.sh` | 把 `Patches/*.patch` 注入 openwrt 内核补丁队列 |
| CI 步骤 `Apply Kernel Patches` | 在 `Custom Settings` 之后、`Compile Firmware` 之前调用它 |

`ApplyPatches.sh` 沿用本仓纪律：找不到 `Patches/` 或内核 `patches-*` 目录**直接 `exit 1`**，
不静默跳过（静默跳过 = CI 全绿但固件里没补丁）。提供 `WRT_PATCHES=off` 一键关。

### ★ 三、诊断补丁要一次编译给出答案

`wed_debug` 默认开（`echo 0 > /sys/module/mtk_eth/parameters/wed_debug` 可关）。
三种日志对应三种结论：

| 日志表现 | 含义 | 下一步 |
| :-- | :-- | :-- |
| 一条都没有 | CONFIG 没生效 | Makefile 改动无用，要去改 config |
| 有 `add_hw`、无 `attach` | `.o` 确实被 `--gc-sections` 丢掉 | 假设成立，转做真修复 |
| 有 `add_hw`+`attach`、无 `attaching wed device` | `mtk_wed_assign()` 拒绝 | 新日志会打出 `hw_list[]` 与 version |

### 四、验收清单（刷机后按顺序看，第 1 条最关键）

```sh
dmesg | grep -i 'wed-diag'                  # 看是上面哪一种
cat /sys/module/mtk_eth/parameters/wed_debug   # 期望存在（= 补丁确实编进来了）
grep -c mtk_soc_wed_ops /proc/kallsyms     # 期望 >= 1
grep -i wed /proc/interrupts               # 期望有条目
dmesg | grep 'attaching wed device'        # 期望: version 3
```

★ 第 2 条是「补丁有没有进固件」的**唯一可靠判据**。
上一轮我曾拿 `uname -a` 的内核构建时间当判据 —— 方向对但理由错
（内核没重编是因为补丁没改配置，与固件新旧无关）；
`/etc/openwrt_release` 的 mtime 更不能用，它是 buildroot 基础镜像时间戳。

### 五、变更清单与闸门

- `Patches/`（新）、`Scripts/ApplyPatches.sh`（新）、CI 步骤（新）
- `Scripts/SelfCheck.sh` 新增 **C22 / C23**：
  - **C22** 补丁必须用 `__used` 而非重复链接（+ 必须 LF + 必须像内核 diff）
  - **C23** 注入链完整（`ApplyPatches.sh` 在册 + CI 在 defconfig 后/编译前调用）
- README 结构树补 `Patches/` 与 `ApplyPatches.sh`（C9 抓到的）；`C1~C10`/`C1~C7` 过期描述更正为 `C1~C21`
- `.gitattributes` 增 `Patches/** text eol=lf`

⚠️ **风险**：WED 走网卡 DMA 通路，配错会表现为 Wi-Fi 收发异常、掉流甚至看门狗重启。
务必**保留有线回退路径**，先在有线连接下验证再回归 Wi-Fi。

### 六、本轮两次「自己写错、自己抓出」的记录

1. **补丁会让编译失败**（Makefile 重复链接）—— 提交前对着真实 v6.18.54 源码才发现。
2. **新闸门 `pass` 永不触发** —— 我把本仓约定的 `N=$FAIL` 写成 `N=$((N + 1))`，
   于是 `[ "$FAIL" -eq "$N" ]` 恒假，闸门**只会判红、永不显示绿**。
   若只看「RC=0 全部通过」会被完全骗过 ⇒ 闸门必须用 `set -x` 或直接看输出确认它真在跑。



上一轮（`27df209` / `2495016`）把 WED 断因写成「内核缺 `CONFIG_NET_MEDIATEK_SOC_WED`」。
**这条结论本身是错的，本条撤回。** 本轮改用固件的精确上游基底
（ImmortalWrt `8735c68` = 设备内核 `r0-8735c68`；linux `6.18.54`，
树哈希 `9df30b02dd81…`）重查源码，v2 与 v1 一样不成立。

### 三代归因对照

| 代 | 说法 | 判定 | 依据 |
| :-- | :-- | :-- | :-- |
| v1 | 旧说法：「MT7987 没有 SoC 寄存器表」 | ✗ 已推翻 | 补丁 750 的 `mt7987_data` 存在，`.version = 3`，走 `mtk_wed_add_hw()` 的 `case 3` 拿 `mt7988_data` |
| v2 | 旧说法：「内核缺 `CONFIG_NET_MEDIATEK_SOC_WED`」 | ✗ 已推翻 | 上游 `filogic/config-6.18` 明写 `CONFIG_NET_MEDIATEK_SOC_WED=y`；真机 `mtk_wed.o` 的 60 个符号全在、`wed0` debugfs 已建 |
| v3 | 内核未链接 `mtk_wed_ops.o` | ✓ 现行 | 见下 |

### v3 的判定链

- `mt7996e.ko` 的 undefined 符号里**有** `mtk_soc_wed_ops`（模块在等它）
- 内核 `/proc/kallsyms` 里该符号**计数 = 0**（内核没有）
- 全仓唯一定义处是 `drivers/net/ethernet/mediatek/mtk_wed_ops.c`，
  整个单元只做一件事：`EXPORT_SYMBOL_GPL(mtk_soc_wed_ops)`
- 由 `Makefile` 的 `obj-$(CONFIG_NET_MEDIATEK_SOC_WED) += mtk_wed_ops.o` 编入
- ⇒ 掉的是**这一个 `.o`**，其余 WED 单元都在 ⇒ 不是 CONFIG 开关问题

### ★ 为什么 dmesg 里一条日志都没有（排查时最大的坑）

```c
/* mt7996/mmio.c */
if (mtk_wed_device_attach(wed)) {
        dev->mt76.hwrro_mode = MT76_HWRRO_OFF;
        return 0;                    /* 失败路径，不打任何日志 */
}
```

而 CONFIG 关掉时该函数整体 `#else return 0` —— **外部行为完全一致**。
所以光看 dmesg 永远无法区分「config 没开」与「attach 失败」，
唯一可分辨的是符号表对照。

### 守卫变更（C20 重写）

- 判据从「禁止写 v1 那句」扩到**同时禁止写 v2 那句**（新增 `PAT_CFG_OFF`）
- 自证要素从 3 项增到 4 项，新增 `wed0` 留档，**且要求 GENERAL.txt 与
  CHANGELOG.md 各自都有**（只要求「某个文件有」是弱断言，反向验证已证明会漏）
- 反向验证扩到 8 组，全部判红、复原全绿：
  M1 = v1 归因复活 / M2·M2b·M2c = 三种「CONFIG 未生效」的中文与符号写法 /
  M3·M4 单独删两个文件里的 `wed0` / M5 删 `mtk_soc_wed_ops` / M6 删 `mtk_wed_ops`

### 排查方法留档

- `openwrt/linux` 仓库**不存在**，别去那儿找 6.18；内核要查 stable 的 `v6.18.54` tag
- 内核源码哈希在 `target/linux/generic/kernel-6.18`（不在 mediatek 目录里）
- `wed_enable` 已能正常生效：写 `/etc/modules.d/mt7996e` 内容为
  `mt7996e wed_enable=1`，读回 `/sys/module/mt7996e/parameters/wed_enable` 为 `Y`。
  直跑 `modprobe mt7996e wed_enable=1` 会被 procd 按 modules.d 重载覆盖，
  这是 OpenWrt 正常行为不是 bug。


## [2026-10-06 晚] WED 断点归因最终更正：不是「缺 SoC 表」，是内核缺 CONFIG

起因：被要求「打破固有认知」去查 WiFi 硬件加速，于是把上一轮当成定论的
「MT7987 缺 SoC 寄存器表」重新查了一遍。**结论：那条归因是错的**，已推翻。

### 一、错在哪

上一轮只 grep 了 `mtk_wed_soc_data` 的**变量名定义**，看到只有
mt7622_data / mt7986_data / mt7988_data 三张，就断定 MT7987 没有表。
但 `mtk_wed_add_hw()` 并不查表名，它按 **version 数字**分派：

```c
hw->version = eth->soc->version;
switch (hw->version) {
case 2:  hw->soc = &mt7986_data; break;
case 3:  hw->soc = &mt7988_data; break;
default:
case 1:  hw->mirror = syscon_regmap_lookup_by_phandle(eth_np, "mediatek,pcie-mirror");
        hw->hifsys = syscon_regmap_lookup_by_phandle(eth_np, "mediatek,hifsys");
        ... hw->soc = &mt7622_data; break;
}
```

而 OpenWrt 补丁 `750-net-ethernet-mtk_eth_soc-add-mt7987-support.patch` 里
**mt7987_data 明确写着 `.version = 3`** ⇒ MT7987 走 `case 3`，拿到 `mt7988_data`。

**旁证**：`mtk_wed_hw_add_debugfs(hw)` 是在 switch **之后**无条件调用的，
而真机 `/sys/kernel/debug/wed0/` 有 7 个文件（amsdu / regidx / regval / rro /
rtqm / rxinfo / txinfo）⇒ `mtk_wed_add_hw()` 完整走完了，probe 成功。
这本身就否定了「表不存在所以挂不上」。

### 二、真正的断点（符号表级取证）

mt76 拿到 WED 硬件的**唯一**入口是全局指针 `mtk_soc_wed_ops`
（`mt7996/mmio.c` 的 `mt7996_mmio_wed_init()` 里 `rcu_dereference(mtk_soc_wed_ops)`）。
该符号的唯一编译单元 `mtk_wed_ops.c` **全文 10 行**：

```c
const struct mtk_wed_ops __rcu *mtk_soc_wed_ops;
EXPORT_SYMBOL_GPL(mtk_soc_wed_ops);
```

由 `drivers/net/ethernet/mediatek/Makefile` 第 12 行决定是否编入：
`obj-$(CONFIG_NET_MEDIATEK_SOC_WED) += mtk_wed_ops.o`

真机四处实测互相印证：

| 检查项 | 结果 | 说明 |
| :-- | :-- | :-- |
| `grep mtk_soc_wed_ops /proc/kallsyms` | **0 命中** | 唯一跨模块入口不存在 |
| `mtk_wed_attach` in kallsyms | 小写 **`t`** | 未 EXPORT |
| `mtk_wed_wo_init` in kallsyms | 大写 **`T`** | 已 EXPORT（对照组） |
| 系统里有没有 `mtk_wed.ko` | **没有** | mtk_wed 全内建于 vmlinux |

⇒ 单独掉的只有 `mtk_wed_ops.o`，`mtk_wed.o` 仍在内核里。
**这就是「硬件层看起来完好、但 mt76 拿不到接口」的原因。**

### 三、为什么 `wed_enable=Y` 无效

`wed_enable`（`mt7996/mmio.c` 第 17-18 行 `module_param(wed_enable, bool, 0644)`，
且是**主线内核自带**，非 OpenWrt 补丁）门控的是 `mt7996_mmio_wed_init()`，
该函数在 `#ifdef CONFIG_NET_MEDIATEK_SOC_WED` 内、且第一步就
`rcu_dereference(mtk_soc_wed_ops)` —— 接口不存在，函数直接失败返回。
**参数能写、读回 `Y`，但永远不会走到 `mtk_wed_attach()`。**
实测三处都验证过：sysfs 直写有效；`/etc/modules.d/mt7996e` 改成
`mt7996e wed_enable=1` 后带参数 `modprobe` 仍读回 `N`（procd 按 modules.d 重载覆盖）；
`dmesg | grep -ic wed` = 0（连一次 attach 都没尝试）。

### 四、修复方向（两处缺一不可）

1. **内核 config 显式 `CONFIG_NET_MEDIATEK_SOC_WED=y`**，让 `mtk_wed_ops.o` 进内核。
   注意 Kconfig 里它是 `def_bool NET_MEDIATEK_SOC != n`（**自动派生、不可手动赋值**），
   而本机 `NET_MEDIATEK_SOC` 选的是 `y`（内建，系统里没有 `mtk_eth.ko`）。
   这就是「mtk_wed.o 在、mtk_wed_ops.o 不在」的机制。
   → 需改内核 config 并重编固件，**属于固件构建变更**。
2. **`/etc/modules.d/mt7996e` 写 `mt7996e wed_enable=1`**，让 procd 带参数加载。

验收判据（三项，缺一不可）：
- `grep mtk_soc_wed_ops /proc/kallsyms` 命中
- `dmesg | grep "attaching wed device"` 有输出
- `wc -c /sys/kernel/debug/wed0/rxinfo` 不再是 0

### 五、同时撤掉的一个错误论断

此前记忆里记着「MT7992 的 WED 必绑 PPE（`mtk_wed_wo_init()` 末段
`mtk_wed_get_rx_capa()` 为真 ⇒ 进 `mtk_wed_wo_init()` ⇒ 需 PPE）」。
**不成立**：`mtk_wed_wo.c` 全文**零 PPE 引用**，`mtk_wed_wo_init()` 只做
`wo_hardware_init + mcu_init + exception_init`；`mtk_wed.c` 里唯一碰 PPE 的
是 `mtk_wed_ppe_check()` —— 一个 `void` 返回的数据面回调（只有 PPE 报
`MTK_PPE_CPU_REASON_HIT_UNBIND_RATE_REACHED` 时才把包还给软件栈），
**attach 路径根本没调用它**。PPE 有无不影响 WED attach 成功。

### 六、守卫

- **C18 改写归因**并放宽结论措辞（「当前不可用」而非「不可用」），
  同时在标题下写明：日后若开了 CONFIG 并实测 attach 成功，**可以**推翻，
  但必须同时给出「kallsyms 有 `mtk_soc_wed_ops`」与「dmesg 有
  `attaching wed device`」两项证据。
- **新增 C20**：禁止把断因写回「缺 SoC 表」，且强制 `mtk_soc_wed_ops` /
  `CONFIG_NET_MEDIATEK_SOC_WED` 的自证判据留在仓内。
  ★ 判据的 `--include` 必须含 `'*.txt'` —— `Config/GENERAL.txt` 是记这些结论
  的地方，漏了会恒红（C19 第③项已踩过同族坑）。

SelfCheck 20 门全绿；C20 已做反向验证（变异均判红、复原后全绿）。

**本次未改设备任何配置**（`/etc/modules.d/mt7996e` 已被改成带参数形式并保留，
对当前状态无副作用；等固件开了 CONFIG 之后它才会真正生效）。

## [2026-10-06] 刷机后复测：软件 flow offload 确认生效，硬件侧三项判据全为零

上一节把「WiFi 没有硬件转发」查清了，但那次结论依赖的是 dmesg 与节点存在性。
本次在**新固件（kernel 6.18.54 / r0-8735c68）**上造真实转发流量复测，
把三层加速各自的**生效判据**都落到数值上。

### 一、实测方法（这次修正了取证方式）

前几轮踩过的坑这次一并避开：
- 开发机双网卡，有线 `192.168.8.103`（跃点 25）优先于 Wi-Fi `192.168.10.202`（跃点 30），
  流量会走另一台路由器 → 这次 **绑定源地址 `192.168.10.202`** 才确保经过 H5000M。
  （Windows `curl --interface <IP>` 无效，直接失败 `http=000`；改用 Python `socket.bind()`。）
- 只用国内明文 HTTP 源（`mirrors.tuna.tsinghua.edu.cn`）。`mirrors.aliyun.com` 的
  80 端口返回 302、443 端口因明文请求返 400，ustc 返 403 —— 都不能当流量源。
- 并发 3 路 × 40 MB，采样器在设备端 `setsid` 后台跑（设备无 `nohup`，`/tmp` 是 tmpfs）。

### 二、层一：软件 flow offload —— 确认生效

流量证据：设备端 `eth2` 的 `rx_bytes` 从 14883 涨到 138393751（**138 MB**），
`/proc/interrupts` 的 IRQ 74（xhci USB）从 643 涨到 14698，PC 侧三路各收 40 MB 全部成功。

conntrack 里带 `[OFFLOAD]` 的正是这三条流：

```
src=192.168.10.202 dst=101.6.15.130 sport=59416 dport=80 packets=15246 bytes=851345
  src=101.6.15.130 dst=10.27.158.102 sport=80 dport=59416 packets=32584 bytes=46196152 [OFFLOAD]
src=192.168.10.202 dst=101.6.15.130 sport=59417 dport=80 packets=14054 bytes=778849
  src=101.6.15.130 dst=10.27.158.102 sport=80 dport=59417 packets=32890 bytes=46700436 [OFFLOAD]
```

nft 侧形态与 `MODE=on` 一致，且**这次确认了它挂在 ingress**：

```
flowtable ft { # handle 184
	hook ingress priority filter
	devices = { "br-lan", "eth1", "eth2" }
	counter
}
```

UCI 侧 `firewall.@defaults[0].flow_offloading=1` / `flow_offloading_hw=0`，
`/etc/mt5700/flow-offload` = `MODE=on`，服务是 `/etc/init.d/firewall`（`S19firewall`，
**没有** `firewall4`）—— 三处一致，没有出现「UCI 写了 1 但 nft 里没有 flowtable」那种假象。

#### ★★ 顺带更正一条会误导人的判据

第三路流（`sport=59415`）传了 **45 MB**，`conntrack` 里留下的是 `[ASSURED]` 而**没有**
`[OFFLOAD]`，且在流进行中就已经是终态。⇒ **「`grep -c OFFLOAD` 的数字」不能当作
"卸载命中了多少"的度量** —— 流量最大的一条反而没有标记。原因是 flow 已经进了快转路径、
后续包不再逐个过 conntrack 表，条目形态随连接生命周期变化。

⇒ 正确判据是**组合式**（本次三项同时成立才算 SFO 真在工作）：
1. `nft list table inet fw4` 里有 `flowtable ft` 且 `devices` 含出口 `eth2`；
2. 打真实流量后，`/proc/net/nf_conntrack` 里**至少有一条**本次连接带 `[OFFLOAD]`；
3. 设备端 `eth2` 的 `rx_bytes` 确实随流量上涨（证明流量真的过了这台路由器）。

第 ③ 条正是本节开头绑定源地址的理由 —— 少了它，第 ② 条可能是在另一台路由器的
conntrack 里数出来的。

### 三、层二：PPE 硬件 NAT —— 判据全零，且当前拓扑下改不动

```
ppe0/entries = 0 字节    ppe0/bind = 0 字节    ppe1/entries = 0 字节
```

三条硬件卸载判据**同时为零**，即没有任何一条 flow 进过硬件转发表。
引擎本身是在的（`dmesg`: `eth0/eth1: mediatek frame engine at 0xffffffc081900000, irq 67`），
但 `flow_offloading_hw=0`，且出口是 `eth2`（USB CDC-NCM）。

补充一条本次才拿到的旁证：`ethtool -k eth2` 显示 `rx/tx-checksumming: off [fixed]`、
`scatter-gather: off [fixed]`、`tcp-segmentation-offload: off` —— USB CDC-NCM 这条链路
连基本的 checksum/TSO 卸载都标了 `[fixed]`，PPE 就算接上也拿不到可卸载的包形态。

### 四、层三：WED —— 仍然从未 attach

```
/sys/module/mt7996e/parameters/wed_enable = N
dmesg | grep -ci wed = 0
/sys/kernel/debug/wed0/{rxinfo,txinfo,amsdu} = 0 字节
```

`wed0` 节点与 7 个 debugfs 文件都在（平台设备 probe 成功），但**从未 attach**，
与上一节「MT7987 缺 `mtk_wed_soc_data`」的结论一致。

### 五、本次未改任何配置

三层状态与 `Config/GENERAL.txt`、`Files/etc/uci-defaults/99-mt5700-net` 里写的
默认选型（软件开、硬件关）完全吻合，**上游配置无需改动**。本次新增的是一条守卫
（见下）与上述判据的记录。

### 六、新增守卫 C19

「用 `grep -c OFFLOAD` 的计数当作卸载命中量」这个错误判据，在本仓注释里出现过
（2026-10-05 那次写的是「开 → OFFLOAD 标记 42」，把计数当成了命中量）。
C19 禁止再把该计数表述成命中量/命中率，也禁止只凭计数就断言 SFO 生效。

## [2026-10-06] WiFi 硬件转发加速取证：三层机制逐一查清，全部走不通

起因：刷机验收时注意到 `mt7996e` 模块参数 `wed_enable = N`，而 WED 硬件节点
（`/sys/kernel/debug/wed0`、平台设备 `15010000.wed`）**确实存在且已 probe 成功**。
这与前几轮"WED 因缺固件 blob 而失败"的说法冲突 —— 既然硬件在、胶水层在、只是没开，
那就必须查清是"没开"还是"开了也没用"。

### 一、三层机制与各自的断点

| 层 | 是什么 | 本机状态 |
| :-- | :-- | :-- |
| **WED** | WiFi DMA ↔ 以太网 MAC 直通，绕过 CPU | 硬件节点在、驱动实现全在、SoC 表**有**，但**内核缺 `CONFIG_NET_MEDIATEK_SOC_WED`** ⇒ 不可用（见文末「更正」） |
| **PPE 硬件卸载** | PPE 引擎做 NAT | 引擎已 attach（`ppe0`/`ppe1`），但**只接 SoC 以太网口**，WiFi netdev 进不去 |
| **软件 flow offload** | nft flowtable 快转 | ✅ **已开且生效**（这是目前 WiFi 转发唯一真正在用的加速） |

### 二、~~决定性证据：上游 `mtk_wed.c` 里 MT7987 出现 0 次~~ —— **本节归因已被推翻，见文末「更正」**

> 下面是当时的推理链，留档是为了说明错在哪：
> `grep -n "mtk_wed_soc_data"` 只列出了 mt7622_data / mt7986_data / mt7988_data
> 三张表，于是得出「MT7987 没有 SoC 寄存器表」。
> **错在只 grep 了符号定义处的变量名，没查 `hw->version` 的赋值来源。**
> 真实路径是 `mtk_wed_add_hw()` 的 `switch (hw->version)`，
> 而 `hw->version = eth->soc->version`，MT7987 的这个值由 OpenWrt 补丁 750 提供。

实测（当时）：
- `echo 1 > /sys/module/mt7996e/parameters/wed_enable` 写入成功、读回 `Y`；
- 但 `/sys/kernel/debug/wed0/` 下 `rxinfo`/`txinfo`/`amsdu` 全部仍为 **0 字节**、
  `dmesg` 无任何 attach 日志。

⇒ 「翻 `wed_enable` 就能开」确实是错的 —— **但原因不是当时猜的那个。**


### 三、PPE 侧：WiFi netdev 走不通的那一行代码

`mtk_ppe_offload.c` 的 `mtk_flow_set_output_device()` 其实**有**接受 WiFi 的分支：

```c
if (mtk_flow_get_wdma_info(dev, dest_mac, &info) == 0) {   /* ← 硬件 WDMA 路径 */
        mtk_foe_entry_set_wdma(eth, foe, info.wdma_idx, ...);
        pse_port = PSE_WDMA0/1/2_PORT;                     /* 专为 WED 预留的端口 */
        *wed_index = info.wdma_idx;
        goto out;
}
/* ↓ 非 WDMA 路径：只认 SoC 以太网口 */
if      (dev == eth->netdev[0]) pse_port = PSE_GDM1_PORT;
else if (dev == eth->netdev[1]) pse_port = PSE_GDM2_PORT;
else if (dev == eth->netdev[2]) pse_port = PSE_GDM3_PORT;
else                           return -EOPNOTSUPP;
```

而 `mtk_flow_get_wdma_info()` 的唯一判据是：

```c
if (!IS_ENABLED(CONFIG_NET_MEDIATEK_SOC_WED)) return -1;
...
if (path->type != DEV_PATH_MTK_WDMA) { err = -EINVAL; goto err_out; }
```

`DEV_PATH_MTK_WDMA` 这种 forward path **只由 WED 注册**。所以三层是串联的：
WED 不通 → 没有 WDMA path → PPE 拿 WiFi 设备只能撞 `EOPNOTSUPP`。

⚠️ 这里也纠正一处说法：前几轮说「PPE 只接 SoC 以太网口」**对但不完整** ——
代码**预留了** `PSE_WDMA0/1/2_PORT` 给 WiFi，只是那条路要 WED 先跑起来。
结论（WiFi 进不了 PPE）不变，但原因是串联链条的第一环断了，不是白名单本身。

### 四、本机客观事实（一律实测，不靠推断）

```
$ lsmod | grep wed                → 无独立 mtk_wed 模块（胶水层在 mtk_eth 里内联）
$ cat /sys/module/mt7996e/parameters/wed_enable    → N
$ ls /sys/kernel/debug/wed0/     → amsdu regidx regval rro rtqm rxinfo txinfo（7 个节点都在）
$ cat /sys/devices/platform/soc/15010000.wed/uevent
  OF_COMPATIBLE_0=mediatek,mt7987-wed  OF_COMPATIBLE_1=syscon   ← DT 节点完整、probe 成功
$ ls -d /sys/kernel/debug/ppe*    → ppe0 ppe1（两个引擎）
ethtool -k phy0.1-ap0            → rx-checksumming on / tx-checksumming **off [fixed]**
                                    tx-tcp-segmentation off [fixed]、SG off [fixed]
$ nft ... flowtable devices      → { br-lan, eth1, eth2 }   ← **不含 phy0.1-ap0**
```

⚠️ `ethtool` 那两行值得单独说：`tx-checksumming` / `tx-tcp-segmentation` / `SG`
全是 **`off [fixed]`** —— `[fixed]` 意味着**驱动写死了关、无法打开**，不是配置问题。
即 WiFi 出方向连软件 checksum/TSO 都没有，所有这些都由 CPU 做。

### 五、结论

**WiFi 侧硬件转发加速在本机（MT7987A + MT7992E + 上游内核 6.18）不可用**，
且不是"少开一个开关"：

1. **WiFi 硬件 NAT（PPE 卸载）**：需要 WED 提供 WDMA path → MT7987 无 soc_data → 断。
2. **WED 直通**：需要 SoC 寄存器表 → 上游没有 → 断（实测改 `wed_enable` 无任何效果）。
3. **MT7992 芯片自身的独立 NAT 引擎**：`/proc/device-tree/soc/` 下只有
   `ethernet@15100000` 与 `wed@15010000`，**无 hnat/ppe 节点** → 不存在。
4. **当前真正在生效的只有软件 flow offload**（`flowtable ft`，已确认
   `devices = { br-lan, eth1, eth2 }`）。它对 WiFi 转发同样有效 —— 因为流量
   从 `phy0.1-ap0` 收进来后已进 flowtable，只是**省的是 CPU 遍历协议栈，不是硬件 NAT**。

**已经做到的（软件侧）**：WiFi RPS 避开硬中断核（`phy0.1-ap0 rps_cpus=0xe`）、
`generic-receive-offload: on`、`mq` 队列参与分摊。这些都是 CPU 分摊，不是硬件卸载。

### 六、若将来想走通，需要同时满足（缺一不可）

1. 内核侧：给 `mtk_wed.c` 增加 `mt7987_data`（V3.1 寄存器图：wpdma 环偏移、
   reset 掩码、`hw_rro` 枚举 …）。本仓历史上做过（`999-mtk7987-wed-v31.patch`），
   但因**内核侧改了 `wlan.wpdma_tx` 标量→数组、mt76 侧未同步**导致编译失败，
   已于 Run #33100607008 永久移除（见本文件 2600~2660 行）。重做需两侧同 commit 校准。
2. 驱动侧：mt76 侧配套的 `hw_rro` 枚举补丁，且必须与内核补丁同一基线。
3. 设备树：WED 的 DLM 节点（`wo-dlm`）与 `wo-ccif` 缺失会报 `failed to attach wed device`。
4. DTS：SoC 侧需与 MT7992 的双 WDMA 环匹配。

⇒ **代价与风险远高于收益**（要维护跨仓双补丁 + 每次内核/mt76 升级都要重新校准），
**维持软件 flow offload 方案**。

### 七、守卫：把这三条结论钉住，防止被反复重查

本次取证花了多轮，而"WiFi 硬件加速能不能开"这个问题会周期性地被再问一遍。
已加 **C18** 钉住三条可静态验证的事实（SoC 表只有 3 个 SoC / 不含 MT7987；
`ethtool` 的 `[fixed]` 项不可改；flowtable devices 不含 WiFi 时不得声称硬件卸载生效）。

### 八、这次踩的坑（方法论）

★ **`/sys/module/*/parameters/` 里能写的参数 ≠ 运行中生效。**
`wed_enable` 写入成功、读回 `Y`，看起来成功了，但驱动只在 probe 时读一次，
且真正的前提（SoC 寄存器表）根本不存在。
**参数写入成功只是"必要条件之一"，不是"生效"。**

★ **"硬件节点存在"与"驱动实现了该硬件"是两件事。**
`/sys/kernel/debug/wed0/` 七个节点齐、平台设备 probe 成功、驱动符号 130 个且地址非零 ——
全都在，但缺一张 SoC 表就一步都走不出去。**取证必须查到"驱动侧的结构体表"这一层**，
只数符号个数会被彻底误导（本项目此前就因此得出过错误结论）。

---

## [2026-10-05] flow offload 默认值改回「开」——原先「必须关」的实测依据已被证伪

### 一、结论

| 项 | 改前 | 改后 |
| :-- | :-- | :-- |
| `Files/etc/mt5700/flow-offload` | `MODE=off` | **`MODE=on`** |
| `Scripts/ApplyFlowOffload.sh` 兜底 | `${WRT_FLOW_OFFLOAD:-off}` | **`:-on`** |
| `WRT-CORE.yml` / `WRT-BUILD.yml` / `H5000M-MT-AUTO.yml` 的 `FLOW_OFFLOAD` | `default: 'off'` | **`default: 'on'`** |
| `flow_offloading_hw`（硬件卸载） | 关 | **仍关**（理由已更新，见下） |
| `99-mt5700-net` 的 `auto` 分支 | 遇 TTL 规则即强制关 | **删掉该阻断**，只留 SQM 互斥 |

### 二、为什么改：原依据的实测流量根本没经过这台路由器

原注释（2026-09-21 真机实证）称：「卸载开 → 客户端 HTTP 25 秒超时、conntrack 条目带 `[OFFLOAD]`、
正向 10 包只回收 1 包（仅 SYN-ACK）；卸载关 → 同一请求 HTTP 200 / 1.0 秒」，据此定默认 `off`。

**那次测试的公网流量走的是另一台路由器。** 开发机双网卡且有线优先：

```
有线 192.168.8.103  跃点 25   ← 实际出口
Wi-Fi 192.168.10.202 跃点 30  ← 被跳过的正是本机
tracert 公网第一跳 = 192.168.8.1（不是 192.168.10.1）
```

### 三、2026-10-05 真机 A/B 重测（H5000M / kernel 6.18.52）

判据换成两个可靠信号：**绑定源地址 `192.168.10.202` 强制走 Wi-Fi** + **查 conntrack 的 `[OFFLOAD]` 标记**。

| 档位 | `_offloading(_hw)` | flowtable devices | OFFLOAD 标记 | 大流量传输 |
| :-- | :-- | :-- | :-- | :-- |
| 关 | 0 / 0 | —— | **0** | ——（基线） |
| 软件开 | 1 / 0 | `{ br-lan, eth1, eth2 }` | **42** | **44.15 MB / 39s 全成功** |
| 硬件也开 | 1 / 1 | `{ eth0, eth1, eth2, phy0.1-ap0 }` | **42** | **44.15 MB / 39s 全成功** |

3 条长连接全程正常收发，无超时、无丢包。⇒ **软件卸载确定生效且不断网。**

### 四、TTL 规则失效 ≠ 断网（原论证的因果链后半段是错的）

TTL 归一规则（`postrouting` priority 300）在卸载后对快转包零命中 —— 这部分是真的。
但 **flowtable 在 `neigh_xmit()` 前自行递减 TTL**（内核文档：*the TTL is decremented before
calling neigh_xmit()*），包照发不误。原论证从「规则失效」跳到「运营商丢弃 → 断网」，
这一步没有任何依据支撑。按「唯一重性能、稳定性」的口径接受该失效；
需保留 TTL 归一时把 `FLOW_OFFLOAD` 选 `off`。

### 五、硬件卸载仍关，但理由换了（原理由「缺驱动」是错的）

PPE 引擎**已 attach**：`dmesg` 有 `eth0/eth1: mediatek frame engine at 0xffffffc081880000, irq 67`
（两个 2.5G MAC 共用一个 FE + IRQ 67）。真正的卡点是**拓扑** ——
`mtk_ppe_offload.c` 的 `mtk_flow_set_output_device()` 只接受 `mtk_soc_eth` 自己的 `netdev[0..2]`
（映射 `PSE_GDM1/2/3_PORT`），其它设备一律 `return -EOPNOTSUPP` 且无 fallback；
而 5G WAN 是 `eth2`（USB CDC-NCM）⇒ 每条 flow 都被拒。

⚠️ **判硬件卸载真在用不能看 UCI、也不能看 fw4 的告警**：`nft_try_hw_offload()` 只做 `nft -c`
纯语法检查，而本机（无 PPE 时）`flags offload` 同样 `rc=0` ⇒ **恒为假阳性**，不会报
`falling back`。只能看三条同时成立：`ppe0/entries` 计数涨 + `ppe0/bind` 非空 + CPU 下降。
若将来 WAN 改走有线 `eth1`（现配置里有但未插线），`on-hw` 才有意义。

### 六、2026-10-06 刷机后验收：新默认值在真机上全部落地

用户刷入含本次改动的固件后逐项核对，**四处默认值 + 三个 init 服务 + sysctl + nft 片段全部到位**：

| 验收项 | 期望 | 真机实测 |
| :-- | :-- | :-- |
| `firewall.@defaults[0].flow_offloading` | `1` | **`1`** ✅ |
| `firewall.@defaults[0].flow_offloading_hw` | `0` | `0` ✅ |
| `/etc/mt5700/flow-offload` | `MODE=on` | `MODE=on` ✅ |
| nft 里的 flowtable | 存在且 devices 含 `eth2` | **`flowtable ft { devices = { br-lan, eth1, eth2 } }`** ✅ |
| TTL 归一 chain | 已挂 `postrouting` | `mangle_ttl_unify`（hook postrouting/300，规则齐全）✅ |
| `mt5700-rps` | 无线避开硬中断核、其它全核 | `phy0.1-ap0=0xe`、其余 7 个 `0xf`、XPS 64 个 `0xf` ✅ |
| `mt5700-smp` | 中断分摊 | `3 个已分摊到 4 核；1 个不可迁移（驱动限制）` ✅ |
| sysctl | BBR / fq / budget | `bbr`、`fq`、`netdev_budget=600`、`netdev_budget_usecs=20000` ✅ |

⇒ **默认开启的决定在真机固件层面完整落地，且 TTL 规则、offload 两者共存不冲突**
（TTL chain 与 flowtable 是两个独立 base chain，前者在 `postrouting`、后者在 `ingress`）。

⚠️ 顺带更正一条探测口径：**`flow_offloading` 在本版 OpenWrt 里只有
`firewall.@defaults[0].flow_offloading` 这一处**，不再是 `network.@device[0]` ——
后者取值恒为空，据此判断会误以为「配置没写进去」。本仓脚本本来只写 `firewall` 段（C15 覆盖），
但手工验收时别再查 `network` 段。

📌 仍未竟事项：flow offload 的 **CPU 收益量化**依旧没有可信数据（三重环境障碍见
`.workbuddy/` 现场记录：开发机双网卡分流、外网源限流、5G 链路测试期间多次重拨）。
本次验收只证明「落地正确、不阻断连接」，不构成性能量化。

### 六、新增守卫 C15

默认值在两个月内被反转过**两次**（09-21 开 → 09-22 关 → 10-05 又开），每次都只改了几处、
其余靠注释互相"提醒"。C15 钉住：四处默认取值必须都是 `on`；`auto` 分支不得再出现
`TTL_RULE` 判定；但 SQM 互斥（真互斥：被卸载的连接完全绕过 qdisc）必须保留。
已做反向验证 —— 7 条变异全部判红，基线与复原均绿。

### 七、顺带更正三处前版错误

1. ~~WED attach 失败的真因是**固件 blob 缺失**~~ —— **2026-10-06 修正：这只是次要因素，
   主因是内核未编入 `mtk_wed_ops.o`（缺 `CONFIG_NET_MEDIATEK_SOC_WED`）。**
   WED 胶水层确实完整：设备上 `mt7996_mmio_wed_init` / `mt7996_wed_init_buf` /
   `mt76_wed_dma_setup` / `mt76_wed_offload_enable` 等符号全部在，且都有非零地址；
   SoC 寄存器表也**有**（mt7987_data，`.version = 3`，走 `case 3` 拿 mt7988_data）。
   该项归因经历两次修正，最终结论见文末「更正」。
2. 主线 `mtk_eth_soc.c` 的 PPE 初始化是**内联**的（`mtk_ppe_init(eth, eth->base + reg_map->ppe_base, ...)`），
   **不存在**「补一个 `hnat@15000000` DT 节点就能启用」的说法。
3. `nft -c` 对 `{eth0,eth1}+flags offload`、`{eth0,eth1}`、`{eth2}(USB)+flags offload` 三组**全 rc=0**
   ⇒ 再次确认它不检查设备是否支持硬件卸载。

### 八、这次踩的坑（方法论）

★★ **验证路由器行为前，必须先证明流量真的经过了它。** `tracert` 看第一跳、`conntrack` 看
有没有对应条目、绑定源地址强制路径 —— 三样都做，才拿得出可信的 A/B。
本项目因缺这一步，把「我没在正确的路径上测到」写成了「卸载会导致断网」，
并据此做了两次默认值反转，误导了整整两个月。

### 五、同日第二次修正（静态审计复核后落地，都是"每次刷机都会重跑 uci-defaults"这一条根因引出的）

| 问题 | 修法 |
| :-- | :-- |
| **保留配置升级会重放 `/etc/uci-defaults/*`**（eMMC 走 `emmc_copy_config`，只还原 keep.d，脚本来自新 rootfs）→ 而 `99-mt5700-net` 的 `radio1.channel=36/htmode=EHT160` 与 `99-mt5700-sys` 的 NTP 列表是**无条件覆盖** → 用户手改的 5G 信道/频宽、NTP 源**每次升级都被抹掉**（真机佐证：当前 `channel='auto'`、`htmode='HE160'`，与脚本所设不符） | 两处都改为**带标记只应用一次**：`/etc/config/h5000m-defaults-wifi.applied`、`/etc/config/h5000m-defaults-ntp.applied`（真机确认 `keep.d/base-files:1` 就是 `/etc/config/`，整目录跨升级保留）。想恢复产品默认就删标记再重启 |
| 上一提交里两个新脚本各带一条 `( sleep 8; wifi reload ) &` | **删掉**：uci-defaults 由 S10boot 执行，早于 S11sysctl/S20network，无线还要再晚（真机约 25 秒才进 ap0）—— 配置在 wpad 读它之前就已就位，本来不需要 reload；而 sleep 8 正好落在建 AP 的窗口里，**是我自己引入的打断建链风险**。手工重跑脚本时才需自己补 `wifi reload` |
| 日志只有 128KB 内存环（`logd -S 128`），重启即清零 —— 掉线/复位的现场最容易丢 | `system.@system[0].log_size` 提到 512KB（纯 RAM；本机 available 734MB，logd 自身 1.7MB）。**不**加 `log_ip`、**不**落盘（避免 flash 写放大） |

**复核后未采纳**（静态审计里的其余条目）：无线 IRQ 亲和（MTK PCI-MSI 单向量不支持，且实测 144 次/秒无需迁移）、
`xps_cpus`（eth2/无线设备不支持）、`disassoc_low_ack='0'`（hostapd 默认踢掉低 ACK 客户端是合理的 BSS 保护，
CPE 场景不该留死客户端）、`noscan`（默认 0 会按共存自动回落，非缺陷）、邻居表 `gc_thresh`（本机 `neigh` 表远未
接近上限，属"阈值只增上限"的保险而非修复）、5G 出口探活自愈（误判会来回切路由 = 主动引入不稳定，需长期观察）、
每服务 respawn 加固（现依赖内核 watchdog 31s + `panic_on_oops` 链路，加更多脚本反而增加面）、
`proxy_arp_pvlan` 收窄到 br-lan（无线 AP 接口是动态创建的，按名字收窄会漏；`all`+`default` 才是稳的做法）。

## [2026-09-30 · 三] 稳定性体检：NTP 源去掉被反绑定保护拦掉的域名；并把"兜底已就位 / 已知限制"固化成文档

判据只有一条：**会不会掉线 / 抖动 / 复位 / 丢配置**。全部读数来自真机 192.168.10.1，未做任何会中断
现网的改动（本轮**没有**重启无线、没有刷机、没有改设备配置）。

### 一、唯一确定该改的：NTP 源里有被 dnsmasq 反绑定保护拦掉的域名

```
$ nslookup cn.ntp.org.cn 223.5.5.5
    Address: 111.203.6.13      ← 公网
    Address: 10.48.49.44       ← 10/8 私网地址
$ logread | grep rebind
    daemon.warn dnsmasq: possible DNS-rebind attack detected: cn.ntp.org.cn   ← 每几分钟一条
```

本机 `dhcp.@dnsmasq[0].rebind_protection=1`（配置里没有 `rebind_domain` 白名单），所以该域名解析被拦、
ntpd 对它的查询作废。四个源里其余三个（`ntp.tencent.com` / `ntp1.aliyun.com` / `ntp.ntsc.ac.cn`）
工作正常，设备时间实测准确 —— 所以这不是"掉线"，而是**日志噪声 + 一个源白配**；
更麻烦的是它会**淹没真正的反绑定告警**（那条是要当安全信号看的）。

处理：`Files/etc/uci-defaults/99-mt5700-sys` 的 NTP 列表去掉 `cn.ntp.org.cn`。
**不用** `rebind_domain` 白名单 —— 那是整域放行，为一个 NTP 名字削弱反绑定保护不划算。

### 二、已经就位的兜底（正面结论，写下来是为了别再去加）

| 机制 | 真机证据 |
| :-- | :-- |
| 硬件看门狗 | `mtk-wdt: Watchdog enabled (timeout=31 sec, nowayout=0)`，`/dev/watchdog0` |
| 崩溃自动恢复 | `kernel.panic=3` + `kernel.panic_on_oops=1` → oops 即 panic、3 秒后重启，不会停在半死状态 |
| 崩溃现场留存 | `ramoops` 已注册、`/sys/fs/pstore/` 存在且**当前 0 个转储** → 这段时间没有内核崩溃 |
| 内存 | `available 734MB`、zram 512M `Used=0`、`oom_kill=0` → 无内存压力 |
| 闪存 | eMMC `life_time=0x01`（<10%）、`pre_eol_info=0x01`、`/overlay` 3%、`/tmp` 972K |
| 掉电保护 | `K90umount` 含 `sync`；f2fs 挂 `lazytime,noatime,checkpoint_merge,fsync_mode=posix`；开机日志有 `f2fs_recover_fsync_data`（说明确实发生过非正常关机，且自恢复成功） |
| 中断量级 | 无线 IRQ79 ≈ **144/s**、USB IRQ74 ≈ 15/s、`NET_RX` ≈ 41/s → 4 核 A53 毫无压力 |
| 无线链路 | 两个客户端 10.8 小时内只有 3 次 DISCONNECT（一次是我这条 SSH 所在设备休眠）；无 beacon loss 记录 |
| 接口质量 | `eth2`/`br-lan`/`phy0.1-ap0` 的 errors/dropped 全 0，3 秒增量全 0 |

### 三、已知限制（不是缺陷，别再花时间）

| 现象 | 结论 |
| :-- | :-- |
| 无线 IRQ 79 的 `smp_affinity` 写不进去（5.6M 次中断 100% 在 CPU0） | MTK PCI-MSI 单向量不支持亲和设置；按上面的量级**根本不需要迁**。文档原先列为待优化，现撤销 |
| `eth2`/`phy0.1-ap0`/`br-lan` 的 `xps_cpus` 写入**失败** | 这些设备不支持 XPS（不是漏设）；`eth0`/`eth1` 可写且已是 `f` |
| `bootcount` 空跑、**没有自动回滚** | `p1`（512KB，PARTLABEL=u-boot-env）前 64 字节全零、`strings` 无变量、`/etc/fw_env.config` 不存在 → `fw_printenv/fw_setenv` 不可用。刷坏的恢复只有 U-Boot web recovery 或串口 —— **刷机前必须留退路** |
| `ubihealthd` 空跑 | eMMC 无 MTD/UBI；启动即退出，收益≈0，不动 |
| `radius`(disabled=1) / `sqm`(全部 enabled=0) / `autoreboot`(计划 enabled=0) / `relayd`(无配置) / `usbmuxd`(无 iOS 设备) | 都**不生效或无对象**；为微小资源收益去动服务不划算，保持现状（`cpufreq` 实测是 `schedutil`，也是好的默认） |

### 四、设备侧（不在本仓库，但直接决定"稳不稳"的观感）

1. **DNS 上游链路会卡 20 秒**：真机是 `客户端 → dnsmasq(53) → AdGuardHome(127.0.0.1#53335) → 上游`，
   AdGuardHome 日志里 `119.29.29.29:53 over udp ... i/o timeout`，**每次超时 20.003 秒**。
   缓存命中的域名没事，但**新域名首次解析会卡很久** —— 观感就是"有些网站打不开/很慢"。
   建议（属 AdGuardHome 自己的配置）：上游换 `223.5.5.5` 或 DoH/DoT、配多个上游并缩短超时。
   ★ 顺带确认：本仓 `min_cache_ttl=3600` + `use_stale_cache=3600` **现在看是对的**（掩盖上游抖动），
   代价是域名变更滞后；v024 用 60 是另一头的取舍。
2. **LAN IPv6 在"自我撤销"**：`odhcpd: No default route present, setting ra_lifetime to 0!` 每几分钟一条
   —— 5G 出口没有 IPv6 默认路由，odhcpd 只能把 RA 默认路由寿命归零，客户端 IPv6 反复失效。
   属功能取舍，本仓不擅自动：不用 IPv6 就关掉（`dhcp.lan.ra/ndp=disabled` + 删 `ip6assign`），
   要用就保持现状（**不要**用 `ra_default=1`，那会把 IPv6 流量丢给没有出口的路由器）。
3. `network.wwan` 是个没有 device 的 dhcp 接口（厂家固件残留）：不会掉线，但每次 reload 都会被尝试，
   确认不用可删。

### 验证

- 全部读数为真机现场取证（前几轮的脚本都在会话工作区，可重跑）。
- `bash Scripts/SelfCheck.sh` 全绿（README 改动不影响任何闸门）。
- 本轮**未改设备**：NTP 改动只写进固件覆盖层，要等下次刷机才生效。

## [2026-09-30 · 三] Wi-Fi MAC 唯一化（全机型 BSSID 相同）+ 三处运行时加固；并**回退**当天的无线校准固化

本轮起因是"从厂家固件里找无线校准"。结论是：**校准不用搬（也搬错了对象），但顺着这条线挖出了一个真缺陷** ——
factory 分区全零导致**所有 H5000M 的 Wi-Fi BSSID 都是同一对地址**。

### 一、真缺陷：全机型 Wi-Fi BSSID 相同（已修）

**症状**（无人会怀疑到配置上）：两台 H5000M 放同一网段，客户端在两者之间反复漫游/握手失败。

**取证链**（真机 192.168.10.1，逐条可复现）：

| 步骤 | 命令 | 结果 |
| :-- | :-- | :-- |
| 出厂校准是否存在 | `dd if=/dev/mmcblk0p2 bs=64k \| tr -d '\000' \| wc -c`（并按 64KB 分块逐块统计） | **0**（4MB 全零） |
| 驱动怎么办的 | `dmesg` | `eeprom tx_power zeros detected, using defaults`、`eeprom load fail, use default bin` |
| 驱动实际加载了什么 | `cat /sys/kernel/debug/ieee80211/phy0/mt76/eeprom` | 7680 B，`MT_EE_MAC_ADDR=00:0c:43:26:60:10`、`MAC_ADDR2=…:11`（MediaTek **样例**地址，写死在 `/lib/firmware/mediatek/mt7996/mt7992_eeprom_23_2i5i.bin` 里） |
| 上游的 MAC 修复有没有生效 | `cat /sys/class/ieee80211/phy0/macaddress` | `56:9d:93:7b:f5:a5` —— 生效了，但它改的是 **phy 级**地址 |
| 接口用的是哪个 | `iw dev` | `phy0.1-ap0 = 00:0c:43:26:60:11` —— 仍是 eeprom 里那对固定值 |

即：`11_fix_wifi_mac` 的 `hiveton,h5000m` 分支（用 eMMC CID 派生）只管 phy，**mt76 是按频段从 eeprom 取接口 MAC 的**，
于是 2.4G/5G 的 BSSID 在所有机器上完全一致。

**修法**：`Files/etc/uci-defaults/99-h5000m-wifi-mac` —— 用 eMMC CID 派生（`macaddr_generate_from_mmc_cid`），
写进 `wireless.<iface>.macaddr`（OpenWrt 官方路径：`/usr/share/ucode/wifi/ap.uc` 会把它作为 hostapd 的
`bssid=`）。取值沿用 immortalwrt 既有约定（同一颗 phy：radio0 = CID+2、radio1 = CID+3），
脚本注释里附**地址占用表**（eth0=C+0 / eth1=C+1 / phy0=C+2 / 上游留给第二 phy 的 C+3）。
不碰任何二进制与分区，纯 uci，升级安全；已有 `macaddr` 一律不覆盖；拿不到 CID 时 `exit 1` 保留待重试。

刷机后验证：`ubus call network.wireless status | grep bssid` 应显示 `56:9d:…` 段。

**新增静态闸门 C13**（钉三条"改坏也照样能编译、能刷机"的红线）：必须 CID 派生、已有值不覆盖、
拿不到 CID 必须 `exit 1`；另外禁止清理脚本出现 `rm /etc/config/wireless` / `wifi config` 之类的重建动作。

### 二、厂家固件残留清理（新增）

`Files/etc/uci-defaults/99-h5000m-wifi-scrub`：sysupgrade 会保留 `/etc/config/wireless`，从厂家固件
（`mt_wifi7` + qmodem 那一套）刷过来时会带 mt76/mac80211 **不认识**的私有键 ——
`assocresp_elements`（厂家塞进关联响应的私有 IE，残留后客户端"关联成功但 BA 协商全超时"）、
`tx_burst` / `pp_mode` / `pp_bitmap`、以及非 `mac80211` 的 `type`。

依据不是猜的：v024 固件**自己**的升级清理脚本 `99-h5000m-clean-defaults` 里逐个 delete 的就是这些键。
本仓只删私有键 + 修正 `type`，**绝不重建 wireless、不动 SSID/密码/信道**（C13 把这条写成红线）；
`sae_pwe` 属标准选项，只在取值非法时才删。

### 三、USB 网卡重枚举后补设 RPS 与中断亲和（扩既有 hotplug）

`Files/etc/hotplug.d/net/30-mt5700-rps` 原先只对无线接口名触发（注释理由是"避免 USB 模组反复重连时
做无谓调用"）。但 5G 模组重插/复位时 netdev 是**销毁重建**的：新接收队列的 `rps_cpus` 回到内核默认 0
（net-sysfs 里 rps_map 初始为空），而 `init.d/mt5700-rps` 只在 S95 跑一次
→ 之后一路没有 RPS，直到重启。USB 侧中断号也会重新分配，`mt5700-smp` 在 S99 的成果同样失效。
现按「设备挂在 USB 总线上」（`readlink -f /sys/class/net/$INTERFACE/device`）判定，不写死 eth2；
补跑 `mt5700-rps start` 与 `mt5700-smp restart`（都幂等）。代价是模组每次重插多几毫秒。

### 四、风扇 pwm1 的两个写者（新增 rc.local）

真机实测**内核 step_wise 温控与用户态守护进程同时在位**：

```
thermal_zone0: type=cpu-thermal  mode=enabled
cooling_device0: type=pwm-fan  cur=1 max=3        ← 4 档，即 dts 默认 <0 128 192 255>
hwmon2(pwmfan) pwm1=147                           ← 用户态曲线写的值（4 档里没有 147）
ps: /usr/sbin/h5000m-fancontrol daemon 在跑（S98），uci: enabled=1 mode=auto curve=balanced
```

当前 50℃ 未触发 trip 所以还没打架；越过降温点后内核会按 4 档写 128/192/255，守护进程 5 秒后又写回曲线值
—— 两个写者互相覆盖。厂家固件用的正是同一招（风扇守护脚本**先** `echo disabled > thermal_zone0/mode`）。

新增 `Files/etc/rc.local`（每次开机执行，早于 S98 风扇服务）：**仅当确实装了并启用了 h5000m-fancontrol**
才停内核温控，并回读校验 + 记日志；没装就一行不碰（保留内核兜底）。
取舍写明：停内核温控同时也停掉了内核侧对 WiFi（`mt7996_phy0.0/0.1`）的降功率降温动作 —— 与厂家一致
（本机有主动风扇）。回退：删本文件或 `echo enabled > /sys/class/thermal/thermal_zone0/mode`。

### 五、回退：当天的无线校准固化（`Files/lib/firmware/mediatek/mt7996/*.bin`）

同一天早些时候按"factory 全零 → 只依赖上游默认文件"的推理，把厂家 BE5040 校准固化进了固件。
随后**用用户手上的厂家固件镜像（`mwrt-hiveton-h5000m-1139-24-20260925中秋.bin`）里的真品**做逐字节复核，
结论是应当回退：

| 判据 | 结果 |
| :-- | :-- |
| 本机实际使用的那一槽（`_23_2i5i`，内部 FEM）vs mt76 自带默认文件 | **只差 3 个字节**：2 个是 MAC 字段、1 个在 mt76 不解析的区域（`0x1af`）→ **收益为 0** |
| 厂家真品 vs 之前从第三方仓库取的副本 | 只差 2 个字节，且**都在 MAC 字段**（厂家真品是 `00:0c:8c` 段、mt76 默认是 `00:0c:43` 段） |
| 固化会不会有副作用 | 会：eeprom 里的 MAC 就是 mt76 取接口 MAC 的来源，换文件等于把 BSSID 钉成另一段固定值 → 与第一节的修复直接冲突 |
| "上游改名丢校准"这个动机 | 不成立：mt76 的默认 eeprom 与其驱动**同仓库同版本发布**（`package/kernel/mt76` 从 `$(PKG_BUILD_DIR)/firmware/` 安装） |
| 外部 FEM 那一槽（`_23`） | 与本机无关（`dev->var.fem=INT`），且厂家真品比 mt76 默认低 3~4 档（功率表 41 vs 45）→ 改了是降功率，收益不明 |

处理：删掉那两个 `.bin`（`Files/lib/` 整目录）并改写 C12 为**条件式**（目录在就按大小/CHIP_ID/FEM 槽位/
`*.bin binary` 四项校验；不在就明确 skip 并打印本节结论，而不是静默通过）。

### 六、配套改动

| 文件 | 改动 |
| :-- | :-- |
| `Scripts/Packages.sh` | `INSTALL_NET_TUNING` 由"只复制 `Files/etc/`"改为**整棵 `Files/` 树**。原实现自相矛盾：复制只做 etc/，而完整性断言遍历整个 Files/ —— 新增任意 Files/ 子树都会让断言误红 |
| `.gitattributes` | 新增 `*.bin binary`（★ 必须排在 `Files/** text eol=lf` 之后，后写者胜）：否则二进制覆盖层会被当文本翻成 CRLF |
| `Scripts/SelfCheck.sh` | C9 由 `Files/etc` 扩到整个 `Files/`；C12 改条件式；新增 C13；**修 C5 假阳性**（二进制里出现 0x0d 是数据不是行尾 → 显式跳过 `*.bin`） |
| `README.md` | 结构树补三个新文件；第三节改写为"Wi-Fi MAC 唯一化 / 厂家残留清理 / 校准审计结论 / USB 重枚举补设"四条 |

### 七、复核后**不采纳**的项（连同理由，避免以后重复调研）

| 候选（来源） | 不采纳的理由 |
| :-- | :-- |
| conntrack buckets 改走 `modprobe.d`（据称内核把它注册为只读） | **结论被真机推翻**：本机 6.18 上 `/sys/module/nf_conntrack/parameters/hashsize` 是 `-rw-------`，`sysctl -w` 返回 0 并回读生效；而且**用户自己的 `99-mt5700-conntrack.conf` 早把这条写清楚了**（可写，但写它会重建哈希表，63488 vs 65536 只差 3%，不值得）。保持现状 |
| 接口级 sysctl 的 netdev 热插拔重放 | **真机实测无增益**：`proxy_arp_pvlan` / `rp_filter` / `arp_ignore` 的 `br-lan`、`eth2`、`phy0.1-ap0` 上已经是期望值（`default` 模板确实被后创建的接口继承了）。`S11sysctl` 早于 `S20network` 这个事实成立，但 `all`+`default` 已经覆盖 |
| 关掉 `ubihealthd` | eMMC 机型无 MTD/UBI（`/proc/mtd` 为空、`lsmod` 无 ubi）→ 该服务本来就什么都不做，收益≈0 |
| USB 事件驱动"模组就绪"取代固定 `sleep 5` | 属**新功能**而非缺陷修复（现有 `99-mt5700-wan` 已能工作）；增加一条 USB hotplug 触发链需要真机反复插拔验证，本轮不做 |
| 5G 出口健康探测 + 主备切换（mwrt 的 assurance 组件） | 风险中（误判会来回切路由），且本仓文档已就该方向做过取舍；要做得自己写轻量探活 + 滞回 + 冷却，留作独立任务 |
| `&fan` 的 `cooling-levels` 由 4 档改厂家 24 档 | 一旦按第四节的 `rc.local` 停用内核温控，这些档位就不再参与控制 → 无意义；先解决"谁写 pwm1"更根本 |
| `CONFIG_SQUASHFS_DECOMP_MULTI_PERCPU=y`（厂家 config-6.12 有） | 有理论收益（多核解压），但属内核 kconfig，需一次全量编译验证符号可用；留作候选，不塞进本轮 |
| zram / swap / fstab / 日志级别 / dnsmasq 缓存 TTL 等 | 与厂家固件两边等价，或属有意选择的策略（如把 dnsmasq 日志丢 `/dev/null` 会牺牲排障能力，正是本机 TTL 校验与 5G 排障依赖的东西） |

### 验证

- `bash Scripts/SelfCheck.sh`：本地全绿（C1~C13；C12 打印 skip 说明、C13 覆盖两个新脚本的红线）。
- C13 的红线判据已用"删掉守卫 / 改成常量 / 加 rm"三种变异确认会判红（详见提交说明）。
- 真机取证全部在 192.168.10.1 现场完成（dmesg / debugfs eeprom dump / iw / thermal / hwmon / usb 标识）。
- **未做**：刷机验证。新固件刷入后按第一节与第四节的命令各验一次即可。

## [2026-09-30 · 三] H5000M 无线校准（e2p）固化进固件 —— factory 分区全零，此前完全依赖上游 mt76 的默认文件名

把 Hiveton 官方固件（[higowrt](https://github.com/Hiveton/higowrt)）所用的 **BE5040 无线校准**
固化进固件 `Files/lib/firmware/mediatek/mt7996/`，由 `Packages.sh` 铺进 `wrt/files/` 顶掉 mt76
自带的同名默认 eeprom。

### 真机取证：这块板的出厂校准**不存在**

| 事实 | 命令 / 来源 | 结果 |
| :-- | :-- | :-- |
| factory 分区是否为空 | `dd if=/dev/mmcblk0p2 bs=64k \| tr -d '\000' \| wc -c` | **0**（4MB 全零；按 64KB 分块逐块统计也全为 0） |
| 驱动怎么处理的 | `dmesg` | `eeprom tx_power zeros detected, using defaults`、`eeprom load fail, use default bin`（每次开机都一样） |
| 驱动实际加载了什么 | `cat /sys/kernel/debug/ieee80211/phy0/mt76/eeprom` | 7680 字节，CHIP_ID=0x7992，FEM=(0,0) 内部 |
| 与 mt76 默认文件的关系 | 逐字节比对 `mediatek/mt7996/mt7992_eeprom_23_2i5i.bin` | **只差 11 字节，且全部是驱动按芯片 efuse 运行时打的补丁** → 本机走的就是 mt76 的默认文件 |

结论：整机射频校准**只挂在上游 mt76 的默认文件名上**。而这个名字历史上改过
（`mt7992_eeprom.bin` → `_23` → `_24`，见 mt76 `mt7996/mt7996.h` 的
`MT7992_EEPROM_DEFAULT*` 定义）：上游一改，本固件就会**静默**改用别的板子的默认值 ——
WiFi 照常起来，只是功率/频段按错板子走，没有任何报错。

### 厂家侧证据（为什么用这一份）

higowrt 的 `package/mtk/drivers/mt_wifi7/Makefile` 里有一条自带注释：

```
# HiGoWRT: 用 SDK 自带 5040 iPA 校准作 driver e2p (无 per-device 校准,
# 避免 'EEPROM in Flash is wrong' 降级导致 physical_dev not ready)
$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/mt7992/rebb/MT7991_MT7976_EEPROM_BE5040_iPAiLNA.bin $(1)/lib/firmware/e2p
```

即：**厂家自己也承认没有 per-device 校准**，用的是 SDK 的 BE5040 iPA 校准作 e2p。
该二进制不在 higowrt 的公开仓库里（驱动源码 `mt7993_20250919-39602c.tar.xz` 是
`PKG_SOURCE_URL` 为空的闭源包），但同一份文件在公开镜像 `benboguan/mt799x`
（MTK wifi 驱动 + `bin/` 目录）里可取得。

### 本次改动

| 文件 | 改动 |
| :-- | :-- |
| `Files/lib/firmware/mediatek/mt7996/mt7992_eeprom_23_2i5i.bin` | 新增。厂家 `MT7991_MT7976_EEPROM_BE5040_iPAiLNA.bin`（内部 FEM，本机实际使用），7680 字节，SHA256 `4f5a6345…f85563` |
| `Files/lib/firmware/mediatek/mt7996/mt7992_eeprom_23.bin` | 新增。厂家 `MT7991_MT7976_EEPROM_BE5040_ePAeLNA.bin`（外部 FEM 槽位），7680 字节，SHA256 `64584a83…6ab137` |
| `Scripts/Packages.sh` | `INSTALL_NET_TUNING` 由「只复制 `Files/etc/`」改为**整棵 `Files/` 树**（`cp -rf "$SRC_DIR/." "$DST_DIR/"`）。否则 `Files/lib/...` 会被静默丢掉；而下面的完整性断言是「源里有什么、目标就必须有什么」，届时会判红而不是放过 |
| `.gitattributes` | 新增 `*.bin binary`（★ 必须排在 `Files/** text eol=lf` 之后，后写者胜）。没有这条，7680 字节的校准会在 Windows 检出时被当文本翻成 CRLF → 驱动按固定偏移读到**整体错位**的表，而 WiFi 照样能起来 |
| `Scripts/SelfCheck.sh` | C9 由 `Files/etc` 扩到整个 `Files/`；**新增 C12**（见下）；**修 C5 假阳性**（见下） |
| `README.md` | 结构树补上这两个文件；第三节新增「Wi-Fi 射频校准」条目，写明取证过程与 SHA256 |

### 这次改动的价值要说清楚（不是"修功率表"）

本机 dump 出来的实际校准与厂家 iPAiLNA 文件**只差 1 个字节**（偏移 `0x1af`，落在
mt76 不解析的区域），所以它**不会**带来功率变化。真正的收益有两条：

1. **解耦上游文件名漂移**：校准从"上游 mt76 恰好有这个名字的默认文件"变成"我们固件自己带"；
2. **补齐外部 FEM 槽位**：`mt7992_eeprom_23.bin` 那一槽，mt76 自带的是另一块板的表
   （与厂家 ePAeLNA 差 **254 字节**），现在换成本系列的正确值。

### 新增静态闸门 C12

钉四件事（都属于「装错也照样能编译、能刷机、WiFi 也能起」的静默失效）：
文件存在、大小恰好 7680（小于它 mt76 判 `Invalid default bin size` 并放弃 eeprom 初始化）、
CHIP_ID=0x7992、**FEM 位与文件名对应**（`_2i5i` 必须 (0,0)、另一个必须 (3,3)，
驱动按 efuse 选文件，装反等于没装），外加 `.gitattributes` 的 `*.bin binary` 且顺序正确。

**变异验证（4/4 判红，还原后全绿）**：

| 变异 | 结果 |
| :-- | :-- |
| 文件截断成 7000 字节（下载不全 / 被文本转换） | ✗ 判红（大小） |
| 两个 FEM 槽位互换 | ✗ 判红（两个文件各报一次） |
| 用 mt76 的 MT7996 通用 eeprom 顶替 | ✗ 判红（CHIP_ID 31120 ≠ 31122，且 FEM 不符） |
| 删掉 `.gitattributes` 的 `*.bin binary` | ✗ 判红（顺序/缺失） |

### 顺带修掉的同类问题：C5 的假阳性

C5（「Files/ 覆盖层必须是 LF」）用 `tr -dc '\r'` 数 CR —— 但**二进制校准里出现 0x0d 是数据，
不是行尾**，于是本条对新增的 .bin 恒假红（本次加入校准文件时首次命中）。
处理：C5 显式跳过 `*.bin`，并在注释里写明「将来新增别的二进制覆盖层时，这里与
`.gitattributes` 要一起加」；二进制的完整性交给 C12。

### 影响与回退

- 对**本机**（`dev->var.fem = INT`）：加载的表只差 1 个字节（mt76 不解析的区域），
  可以认为"无行为变化，但校准来源从上游挪到自己固件"。
- 对**外部 FEM 的 H5000M**（若有）：那一槽从"别的板子的表"换成本系列正确的表。
- 回退：删掉 `Files/lib/.../mt7996/` 两个文件即可 —— 固件退回「用 mt76 默认 eeprom」的旧行为
  （README / CHANGELOG 相应段落同步删除即一致）。
- 本次**未做**真机刷机验证（改动不触及运行中的设备，且本机校准逐字节已比对过）；
  下一次 `H5000M-MT-AUTO` / 手动 `WRT-BUILD` 产物刷入后，
  以 `dmesg` 仍是 `use default bin`（这条**不会**变，因为 nvmem 依旧全零）、
  以及实际发射功率/速率无异常为准。

## [2026-09-30 · 三] netmode 换源：改用自有 fork（上游 `main` 的直接后代，v1.3.1-r2 → v1.3.4-r1）

`Scripts/Packages.sh` 里 `luci-app-h5000m-netmode` 的克隆源由 `FAN789/luci-app-h5000m-netmode`
换成 `woshinibabao1/luci-app-h5000m-netmode`。

### 背景：上一版「保持上游」的理由已经过期

2026-09-22 风扇温控换源时，这里**有意**把 netmode 留在上游，理由写进了当时的注释：
「保持上游，是为了让 netmode 与厂家行为一致，避免不同 fork 之间的行为差异」。
那个理由当时成立（两边是并行的两套改动），现在不成立了 —— 这个 fork 已经是上游 `main` 的
**直接后代**，没有分叉行为，多出来的全部是性能与缺陷修复。

### 依据（可复现，非推断）

| 判据 | 命令 / 来源 | 结果 |
| :-- | :-- | :-- |
| 上游是不是 fork 的祖先 | `git merge-base --is-ancestor <FAN789>/main <fork>/main` | 返回 0（是祖先，无分叉） |
| fork 多出的提交 | `git log --oneline <FAN789>/main..<fork>/main` | 3 个：`1a31fb2` 裁剪重复探测/写入/DOM 抖动、`6af1323` 收尾并发竞态、`8aadba0` status 54→11 进程 |
| 包标识是否变 | `git diff <FAN789>/main..<fork>/main -- Makefile` | 只有 `PKG_VERSION`/`PKG_RELEASE`（1.3.1-r2 → 1.3.4-r1）；`PKG_NAME` / `LUCI_DEPENDS`(`+luci-base`) / `LUCI_PKGARCH` 不变 |
| 默认配置 / uci-defaults / 菜单是否变 | `git diff ... -- root/etc/config root/etc/uci-defaults root/usr/share/luci/menu.d` | **无差异** |
| 权限面是否变 | `git diff ... -- root/usr/share/rpcd/acl.d` | 只**收紧**：删掉视图根本用不到的 `uci: network / mt5700m` 读写授权 |
| 是否多出第二个包 | 两个仓库里 `find -name Makefile` | 各只有根目录一个 `Makefile`（fork 新增的 `tests/` 里没有 Makefile，`luci.mk` 也不会安装它） |
| 匿名 HTTPS 能否克隆 | `gh api repos/woshinibabao1/luci-app-h5000m-netmode` | `visibility=public`、`default_branch=main`（`UPDATE_PACKAGE` 走匿名 HTTPS，凭据零依赖） |
| 版本序是否正常 | Makefile | 1.3.4-r1 > 1.3.1-r2，apk/ipk 升级判定正常 |

换源换来的实际收益（真机 MT7987A 实测；LuCI 每 5 秒查一次状态，而 rpcd 是单线程的）：
一次 `status` 由 **54 个外部进程 / 约 156 ms** 降到 **11 个 / 约 83 ms**；另外修掉
「没有模组 IPv6 别名段时把 `usbv6_defaultroute`/`usbv6_auto` 谎报成 1」、
「抢锁用 `rm -rf` + `mkdir`，两个实例可能互相删锁」、「状态查询失败会把界面连同选择一起重置」
等问题（详见该 fork 的提交说明）。

### 同步的文档

| 文件 | 改动 |
| :-- | :-- |
| `Scripts/Packages.sh` | 克隆源改为 `woshinibabao1/luci-app-h5000m-netmode`；注释重写为「为什么现在换」+ 依据 + 回退方法 |
| `README.md` | 致谢区的 netmode 链接改指上游并注明「本固件编的是其 fork」；第二节第 3 小节新增换源说明（与风扇温控同一体例） |
| `CHANGELOG.md` | 本条目 |

### 验证边界

- `bash Scripts/SelfCheck.sh`：本地全绿（C1~C11，含 C9 的 README 结构树断言）。
- 本次**没有**跑完整编译（本地环境编不了几小时的固件）：换源是否真能编出产物，由下一次
  定时 `H5000M-MT-AUTO` 或手动 `WRT-BUILD` 实跑验证。风险面已在上表收敛为三条硬约束：
  包标识不变、无新增依赖、仓库公开且分支为 `main`。

### 回退

把 `Scripts/Packages.sh` 里该行的 repo 改回 `FAN789/luci-app-h5000m-netmode` 即可 ——
包名、Config 符号与安装路径都不变，README / CHANGELOG 的说明同步改回即一致。

## [2026-09-28 · 一] 修 `rustup component add rust-lld` —— 那个组件根本不存在（Custom Packages 必中断）

真机 run：[`36408269360`](https://github.com/woshinibabao1/OpenWRT-CI/actions/runs/36408269360)
（WRT-BUILD，`main@f68511f`）。8 分 9 秒后停在 **第 11 步 Custom Packages**：

```
10:19:48  ##[warning]rustup component add rust-lld 第 1 次失败，10 秒后重试
10:19:58  ##[warning]rustup component add rust-lld 第 2 次失败，10 秒后重试
10:20:08  ##[warning]rustup component add rust-lld 第 3 次失败，10 秒后重试
10:20:18  ##[error]…连续 3 次失败 —— rust 工具链不完整…
```

### 根因：组件名不存在

Rust 官方发行清单（`channel-rust-stable.toml`）里**没有名为 `rust-lld` 的组件** ——
携带 LLD 的只有 **`llvm-tools-preview`**（rustup 记作 `llvm-tools`）与
`llvm-bitcode-linker-preview`。所以那行**每次必失败**，重试 3 次纯属空转 30 秒，
最后以一句「工具链不完整」把整条流水线终止 —— 报错信息还把人往错误方向带。

**判定证据（同一 job 内自证，不需要额外实验）**：

| 事实 | 说明 |
| :-- | :-- |
| `rustup target add aarch64-unknown-linux-musl` **成功** | 工具链可写、可用、默认 toolchain 正常 → 排除「环境坏了」「权限不足」「没设默认工具链」 |
| `component add` 每次**瞬时**失败 | 不是下载超时；失败间隔恰好 = 重试的 `sleep 10` → 确定性参数错误，不是网络抖动 |
| 清单里查无此组件 | `pkg.rust-lld` 不存在 |

另外注意这是**一次回归**：本地旧版写的是 `rustup component add rust-lld || true`
（吞掉失败，无害空转），改成「硬失败 + 重试 3 次」后，把一次静默空转升级成了构建终止。

### 修复（`Scripts/Packages.sh`）

不再赌组件名，改成**验收产物**+**兜底**+**可见报错**三件事：

1. **按产物验收**：`find_rust_lld()` 在 `$SYSROOT` 下找 `rust-lld*` 可执行文件 ——
   真正的前提是「链接器找得到」，不是「某条 rustup 命令返回 0」。rustc 自带时无需任何操作。
2. **兜底**：找不到才 `llvm-tools` → `llvm-tools-preview` 依次尝试（两个名字都试，不再赌）。
3. **报错可见**：`add_component` 原实现是 `>/dev/null 2>&1`，于是 3 次失败**零证据**，
   只能靠猜。改为捕获输出、失败时打印前 300 字符；并且它只负责**报告**，
   是否致命交给调用方 —— 否则兜底成功时页面上仍会挂一个红色 error 注解。
4. 最终仍找不到 → 打印 `rustc -vV` / `rustup show` / 已装组件清单后 exit 1。

顺带省掉那 **30 秒**空转重试（`sleep 10 × 3`）。

### 新增静态闸门 C11（`Scripts/SelfCheck.sh`）

这类错误「编译前必炸、且报错指错方向」，所以静态钉住三条：

- **①** 可执行的 `component add <名>` 必须在白名单（`llvm-tools` / `llvm-tools-preview`）内；
  ★ 匹配的是 `component add` 而非 `rustup component add` —— 本仓走 `add_component()` 包装
  调用，只认前者会漏掉真正的调用点；★ 必须排除注释行，否则修复说明里引用的错误写法会自判红。
- **②** 必须存在 `find_rust_lld()`，且必须有 `[ -z "$RUST_LLD" ]` 空值闸门 ——
  否则故障会推迟到 Compile Firmware 才以 `linker rust-lld not found` 暴露，离根因几小时。
- **③** `add_component` 必须捕获 rustup 输出 —— 防止「失败无证据」再次回来。

**变异验证**（4/4 判红，还原后全绿）：

| 变异 | 结果 |
| :-- | :-- |
| 组件名换回 `rust-lld` | ✗ 判红（并连带发现 `rust-lld-preview` 也会被判） |
| `find_rust_lld()` 改名 | ✗ 判红 |
| 删掉 `RUST_LLD` 空值闸门 | ✗ 判红 |
| `add_component` 改回丢弃输出 | ✗ 判红 |

### 顺带量到的耗时（本次未改，作为下次的候选）

按日志时间空档统计（≥3 秒的空档合计 **204 秒**，其中最大的 20 个已列）：

| 耗时 | 位置 | 说明 |
| --: | :-- | :-- |
| **81.8 s** | `Building format(s) --all.` | **TeX Live 的 postinst**（`fmtutil-sys --all`） |
| **30.2 s** | rust-lld 重试 | 本次已消除 |
| 22.3 s | `[INFO] Checking network...` → `apt update` | 上游脚本行为 |
| 19.2 s | cache restore 解包 | 工具链 + 下载缓存两份 |
| 8.7 + 6.7 s | 若干 apt 下载 | — |

TeX Live 的来源已定位：上游 `init_build_environment.sh` 的安装清单里并没有 `texlive`，
它是 **`asciidoc` → `asciidoc-dblatex` → `dblatex` → `default-jre` + 一整套 texlive**
（推荐依赖）带进来的（run 日志 878–942 行的 NEW packages 列表可见）。

候选改法（**本次故意没做**，理由见下）：在跑上游脚本前放一个定向 pin，
只挡 TeX 相关包、其余推荐依赖不动：

```
# /etc/apt/preferences.d/99-no-texlive
Package: texlive* dblatex tex-gyre tipa
Pin: release *
Pin-Priority: -1
```

★ **为什么这次没顺手改**：它属于「删掉之后照样能编译、只在真机某个包上才炸」的类型，
而唯一的验证方式是一次**完整编译**。稳定性优先于速度，所以先只把结论和补丁留在案，
要做得先备好一次全量跑。

## [2026-09-28 · 五] 修复 `FLOW_OFFLOAD` 选项被 YAML 吃成布尔（会导致编译中断）

在验证「MT5700-Console 转私有后本仓库还能不能拉到源码」时，`workflow_dispatch` 派发被
GitHub 以 422 拒绝：

```
Provided value 'off' for input 'FLOW_OFFLOAD' not in the list of allowed values
```

查下去发现是 **YAML 的坑**：`WRT-BUILD.yml` / `H5000M-MT-AUTO.yml` 的 options 写的是裸值

```yaml
        options:
          - auto
          - off        # ← YAML 1.1 把裸写的 off 当布尔 false
          - on         # ← 同理，当 true
          - on-hw
```

解析结果实测是 `['auto', False, True, 'on-hw']`。两个后果：

1. `default: 'off'`（带引号，是字符串）**不在选项列表里** → 用默认值派发必被 422 拒；
2. 网页下拉框显示成 `auto / false / true / on-hw`，用户选「off」实际传下去的是字符串
   `"false"` —— 而 `Scripts/ApplyFlowOffload.sh` 的 case 只认 `auto|off|on|on-hw`：

   ```bash
   case "$MODE" in
   auto|off|on|on-hw) ;;
   *) echo "::error::非法 WRT_FLOW_OFFLOAD='$MODE'（仅允许 auto/off/on/on-hw），终止 CI"; exit 1 ;;
   ```

   → **报「非法」并 exit 1，整个编译中断**。

### 修复

给 options 的 `off` / `on` 加引号，使选项名、默认值、脚本接受值三者一致：

```yaml
        options:
          - 'auto'
          - 'off'
          - 'on'
          - 'on-hw'
```

两处同源问题一并修：`WRT-BUILD.yml`、`H5000M-MT-AUTO.yml`（后者是 `workflow_run`
自动触发，传空值走 `WRT-CORE` 的 default，所以一直没暴露；但网页手动触发同样会踩）。

### 验证

`yaml.safe_load` 复核 options 已全为字符串；随后用 REST API 派发 `WRT-BUILD`
（显式传 `FLOW_OFFLOAD=off`）不再被 422 拒绝 —— 这条路径此前 100% 失败。

## [2026-09-28 · 四] 构建对仓库可见性免疫：MT5700 Console 转私有后又转回公开

`luci-app-mt5700` 的唯一源码源 `woshinibabao1/MT5700-Console` 今天在 public / private
之间来回切了一次（转私有 → 恢复开源 → 又转私有 → 最终**恢复开源**）。
而 `Scripts/Packages.sh` 是用**匿名 HTTPS** 克隆它的（硬编码
`https://github.com/$PKG_REPO.git`，`UPDATE_PACKAGE ... MT5700-Console`）：

仓库私有时会要求认证 → CI 里必然失败（`could not read Username`）→ 连续 3 次后
命中 `P07` 的 `exit 1` → **整条编译中断**。好的一面是 P07 是硬失败而非静默缺包，
不会编出一个没有控制台的固件。

最终结论：**仓库继续开源**（贡献记录要能被别人看到），但**构建不该再被可见性牵着走** ——
否则每次切换都要改这个仓库并重跑一轮。

### 做法：有密钥走 SSH，没密钥回退匿名 HTTPS

| 项 | 做法 |
| :-- | :-- |
| 凭据 | `MT5700-Console` 上一把 **read-only Deploy Key**（ed25519）。实测 push 被拒：`The key you are authenticating with has been marked as read only.` |
| 传递 | 私钥存为 secret `MT5700_DEPLOY_KEY`，**只注入 `Custom Packages` 这一步** |
| 生命周期 | 写到 `0600` 临时文件 → 设 `GIT_SSH_COMMAND` → 克隆完或失败**立即删除**，另挂 `trap ... EXIT` 兜底 |
| **回退** | `PKG_AUTH=ssh` 时若 `MT5700_DEPLOY_KEY` 为空（他人 fork）或密钥准备失败，**回退匿名 HTTPS** 并记一条 notice/warning —— 不致中断构建 |
| 影响面 | 只有 `PKG_AUTH=ssh` 的调用走这条分支；其余（argon 等）**始终**匿名 HTTPS |
| 为什么不用 PAT | Deploy Key 权限更小（只读 + 只对这一个仓库生效）、无过期轮换问题、也不会以 URL 形态出现在进程列表或日志里 |

`GIT_SSH_COMMAND` 用 `IdentitiesOnly=yes`（只用这把钥匙，不把 runner 上其它密钥送出去）
与 `StrictHostKeyChecking=accept-new`（首次 TOFU 记住 GitHub 主机公钥，之后若变化会被检出）。

**为什么不做成「只支持私有」**：本仓库是个 fork，别人可能拿它编自己的固件而拿不到这个
secret。做成「缺凭据即回退公开通道」后，四种组合都能跑：公开+有密钥、公开+无密钥、
私有+有密钥 ✓；私有+无密钥则明确失败（符合预期）。

### 改动清单

| 文件 | 改动 |
| :-- | :-- |
| `Scripts/Packages.sh` | 新增 `setup_private_repo_key` / `cleanup_private_repo_key`；`UPDATE_PACKAGE` 新增第 6 参数 `PKG_AUTH`（`ssh` ⇒ 可能私有）；`luci-app-mt5700` 那一行传 `"ssh"`；克隆目标由硬编码 URL 改为 `$CLONE_URL`；失败文案补「凭据失效」 |
| `.github/workflows/WRT-CORE.yml` | `Custom Packages` 步骤新增 `env: MT5700_DEPLOY_KEY`（**只在这一步** —— 这一步克隆的第三方 Makefile 会被后面的编译执行，不该让它们看到令牌） |

### 验证

- 本地用该私钥 `git clone git@github.com:woshinibabao1/MT5700-Console.git` → **成功**
  （167 个文件，`PKG_VERSION:=2.4.6`）；同一把钥匙 `git push` → **被拒**（read only），确认最小权限；
- `Packages.sh` 与其余 7 个脚本 `bash -n` 全通过；`WRT-CORE.yml` YAML 解析通过、
  `Custom Packages` 的 env 值正确；
- 端到端：手动触发 `WRT-BUILD`，观察 `Custom Packages` 步骤。

### 回退

把 `luci-app-mt5700` 那一行的第 6 参数 `"ssh"` 去掉即可完全回到改动前（匿名 HTTPS）；
若仓库长期公开且不想留这把钥匙，删掉仓库的 Deploy Key 与 `MT5700_DEPLOY_KEY` secret 即可 ——
**代码无需再动**（缺密钥会自动走匿名 HTTPS）。

## [2026-09-28 · 三] 全仓审计修复批：能力宣称与产物不一致（mwan3 / SQM / EHT160）+ 权限与守卫

起因是「全面分析，看还有没有更完善的地方」。审计覆盖工作流 / 构建脚本 / 设备端注入层 /
配置与文档一致性五个面，**每条结论都带两侧原文**；凡涉及设备行为的，一律上真机
（192.168.10.1，`luci-app-mt5700-2.3.60`）核对，不采信推断。

### 1. 能力宣称与产物不一致（3 条，均为真机确证）

| # | 位置 | 问题 | 证据 |
| :-- | :-- | :-- | :-- |
| D1 | `README.md`「链路检测」 | 写「搭配 mwan3…毫秒级无缝切换，确保网络永不掉线」 | 全仓 `Config/*.txt` + `Packages.sh` **搜不到 mwan3**（`luci-app-h5000m-netmode` 的 `LUCI_DEPENDS` 只有 `+luci-base`，不会带入）；真机**无** `mwan3` 命令、无 `/etc/init.d/mwan3`。→ **纯宣称、无实现**，已划掉并注明 |
| D2 | `GENERAL.txt` + `99-mt5700-net` | 两处都让用户「到「网络 → SQM QoS」填写」，但只编了**后端** `sqm-scripts`、没编**前端** `luci-app-sqm` | 真机：`/etc/init.d/sqm` 在、`uci show sqm` 有段、`sqm-scripts` 已装，但 `/www/luci-static/resources/view/network/` 下**无任何 sqm 页面**（对照组 `luci-app-firewall` 页面齐全）。→ 已补 `CONFIG_PACKAGE_luci-app-sqm=y`（上游该包存在，`LUCI_DEPENDS:=+luci-base +sqm-scripts`），并加进 WRT-CORE 的「关键包选择自检」打印列表 |
| D3 | `README.md` 默认配置表 | 5G 频宽写 `EHT160` | 真机是 **`HE160` + `channel=auto`**（`iwinfo` 报 `HT Mode: HE160`） |

**D3 的完整定位（三条设置路径全部没落地）**：

1. `Scripts/Settings.sh` 的 `$WIFI_SH` 分支（设 `EHT160`，还配了一条守卫告警）——
   **该分支永不执行**：上游 `target/linux/mediatek/filogic/base-files/etc/uci-defaults/` 下
   已没有 `*set-wireless.sh`（只剩 `05_fix-compat-version`，2026-09-28 用 GitHub API 核对），
   `find` 返回空 → 一律走 `elif` 的 `mac80211.uc` 分支；
2. `Settings.sh` 的 uc 分支 —— 那两条改频宽的 `sed` 是**注释掉的**，注释理由写着
   「5G 保持 80MHz 上限」，而实测是 160MHz：**该决策的前提本身就不成立**
   （它并没有限制在 80MHz，只是没动上游默认值）；
3. `Files/etc/uci-defaults/99-mt5700-net` 第 5b 节（设 `channel=36` + `EHT160`）——
   真机上判断条件 `wireless.radio1.band` 返回的确实是 `5g`（条件成立），
   但设置**没有保留**（仍是 `auto`/`HE160`）。推断是 wifi 服务生成配置时按
   `mac80211.uc` 的默认重写；**未做实机确证**（改 Wi-Fi 配置会当场断开当前连接，
   不能在这台在用设备上做）。

三处都已按「如实描述 + 标注证据」改写；**没有动任何 Wi-Fi 行为** —— 频宽改动触及 DFS，
必须在真机上带自动回滚验证后再合（唯一有效的位置是 `Settings.sh` 的 uc 分支）。

### 2. 安全（2 条）

| 位置 | 问题 | 修法 |
| :-- | :-- | :-- |
| `Auto-Clean.yml` / `Cache-Clean.yml` | `permissions: write-all` —— 而本仓 `Guard-Check.yml` 用的是 `contents: read`，**同一原则只落实了一半**。`write-all` 额外给出 `packages`/`deployments`/**`id-token`（OIDC）** 等本任务用不到的权限 | 各自收敛为实际所需：Auto-Clean = `contents: write` + `actions: write`；Cache-Clean = `actions: write` |
| `WRT-CORE.yml` 的 job 级 `env: GITHUB_TOKEN` | 该令牌是 `contents: write`，却挂在 **job 级 env** 上，于是**每一步**都能读到 —— 包括 `Packages.sh` 克隆第三方插件、`make` 执行上游/第三方 Makefile、以及以 root 执行远端下载的初始化脚本。而它**没有任何使用者**：`Scripts/*.sh` 里 grep `TOKEN\|secrets.` 为零 | 删掉 job 级 env，改为只在 `Release Firmware` 步骤注入。该 action 的 `token` 输入默认就是 `${{ github.token }}`（其 action.yml 原文：“Defaults to github.token when omitted”），故不影响发布 |

### 3. 健壮性（4 条）

| 位置 | 问题 | 修法 |
| :-- | :-- | :-- |
| `Auto-Clean.yml` | 删除两句都带 `\|\| true`，紧跟着**无条件** `DELETED+1` —— 删除失败也计入成功数，日志撒谎；更要紧的是 job 仍返回 success，而下游 `H5000M-MT-AUTO` 的闸门正是 `conclusion == 'success'`，于是「清理全失败 + 照跑几小时编译」（该文件注释自己点名的场景，实际拦不住） | 改为 `if` 判定；失败计 `FAILED`；**尝试删过但一条都没成功**时 `exit 1`（判据不用 `DELETED==0`：keep-latest 模式下本来就可能一条不删，那是正常的） |
| `WRT-CORE.yml` | `TEST=true` 声称「仅生成配置文件」，但全仓 `artifact` **零命中** —— 导出的 `.config` 只被 `cp` 进 runner 本地的 `./wrt/upload/`（随 runner 销毁），用户在页面上**拿不到** | 新增 `Upload Config (TEST only)` 步骤（`actions/upload-artifact@v4`，仅 `WRT_TEST == 'true'` 时跑） |
| `WRT-CORE.yml` | `BRANCH` 是自由文本输入，而它原样进**文件名**与 **Tag**：填 `feature/x` 会让 `cp ...-feature/x-....txt` 的父目录不存在 → `bash -e` 就地失败，打包与 Release 都不执行 | 另存 `WRT_BRANCH_SLUG`（`tr '/' '-'`）供拼名与 Tag 用；`git clone` 仍用原值 |
| `Guard-Check.yml` | 它的 `apt-get update` 没有 WRT-CORE 早已总结过的规避手段（google-chrome 源哈希竞态）也没有重试，而它是 **PR 上唯一的自动信号** —— 假红直接挡合并 | 补 `rm -f .../google-chrome*.list` + 失败重试一次，与 WRT-CORE 同一处理 |
| `WRT-CORE.yml` | `feeds update/install` 无重试，而同文件的 `git clone` 明确加了 3 次重试 —— 同一个文件里两条网络路径加固标准不一致（feeds 的 git 拉取次数远多于单次 clone） | 套用同样的 3 次重试 + 失败即终止 |

另：`WRT-CORE.yml` 里 5 处 `$GITHUB_WORKSPACE/Scripts/x.sh` 直接调用统一改为 `bash <file>`
—— 直接调用能跑全靠 `Check Scripts` 那条 `find -maxdepth 3 ... -exec chmod +x` 的副作用，
而它限深 3 层：将来加 `Scripts/<子目录>/x.sh` 会「本地能跑（Windows 不看执行位）、CI 报
Permission denied」。`WRT-BUILD.yml` 的 `type: boolean` 默认值由 `'false'` 改为 `false`
（与 `Auto-Clean.yml` 的写法统一）。

### 4. 守卫增强：C9 的扫描范围扩到 `Config/`

`Config/PRIVATE.txt` 是 `Settings.sh` **最后写入 `.config` 的一层**（可覆盖 GENERAL 的同名项），
却从来没进过 README 结构树、也没人告警 —— 因为 C9 只扫 `Scripts/` `Files/etc/` `workflows/`。

现把 `Config/*.txt` 纳入 C9，README 同步补上 `PRIVATE.txt`。
**变异验证**（本仓红线：「写了守卫 ≠ 有了守卫」）：把 README 里的 `PRIVATE.txt` 临时改成
`XXXXXX.txt` → C9 判红（`::error::C9 README 项目结构树漏列： PRIVATE.txt`）→ 还原后全绿。

### 5. 文档与注释修正（不改变任何行为）

- `README.md`：工作流表补 `Guard-Check`（原先同页结构树里有它、表里却没有）；
  「产物区分」删掉已停用且**不可能产生**的 `MT5700M` 示例（`ApplyMTMode.sh` 对它直接 `exit 1`）；
  结构树补 `Config/PRIVATE.txt` 并写明叠加顺序；「本清单与 Config 严格一致」改为
  「列出**显式选中**的包，但 `+DEPENDS` 的传递依赖照样进固件」（例：`luci-app-partexp`
  声明了一串不在任何 Config 里的依赖）；`eip197-mini-firmware` 的溯源改为
  「由 `kmod-crypto-hw-safexcel` 的 `+DEPENDS` 带入、本仓未显式声明」，并标注
  **真机 `/lib/firmware/` 下未见该固件、是否启用未经验证**；
- `Config/GENERAL.txt`：内核版本注释 `6.18.41` → `6.18.x`（同仓他处为 6.18.52，钉小版本必过期）；
- `Scripts/Packages.sh`：`x86)` 分支标注为**已不可达的历史分支**（WRT_TARGET 只可能是 mediatek）；
- `Files/etc/uci-defaults/99-mt5700-net`：`flow-offload` 注释说清「设计默认 off、脚本内变量初值 auto
  只是兜底」这两件事不是一回事。

### 6. 设备端（Files/）补充修复

| 位置 | 问题 | 修法 |
| :-- | :-- | :-- |
| `99-mt5700-sys` | **三个 init.d 服务在首次开机都不会运行**：`enable` 只建 `/etc/rc.d/S*` 软链，而 procd 的 rc 队列在开机那一刻就**一次性展开完了**（只 glob 一次）—— 本脚本跑在 S10，此刻新建的软链进不了本次队列。`apk-index-cache` 因此要等**下一次开机**才生效，而它治的正是「每次重启后软件页不可用」，首启等于没治 | 对不依赖时序的 `apk-index-cache` 补一次 `start`（幂等、内部有 timeout 300）。`mt5700-smp`（S10 时无线 IRQ 尚未注册）/ `mt5700-rps`（要停的 `packet_steering` 此刻还没启动）**不补** —— 补了反而引入时序偏差，由 hotplug 与「第二次开机」兜住 |
| `99-mt5700-wan` | 机型守卫用 `exit 0` 收尾：uci-defaults 被 source 后返回 0 即记为 applied、**随后脚本被删除** ⇒ 一次判据不成立就**永不重试**，而它负责的恰是「刷完没网」的三件事（MT5700M 接口 / 不收对端 DNS + 国内 DNS / 加入防火墙 wan 区） | 区分「读不到机型」（`return 1`，保留脚本待下次开机）与「确认是别的机型」（才 `exit 0`）；匹配改为大小写无关 |
| `30-mt5700-rps` | 补设 RPS 后不看返回码就记「已补设」—— 而 `mt5700-rps` 在一个队列都没设上时 `return 1`，日志与事实可能相反（本项目反复踩的「假成功」类） | 改为 `if … start; then 已补设; else 补设失败` |

### 7. 构建脚本（Scripts/）补充修复

| 位置 | 问题 | 修法 |
| :-- | :-- | :-- |
| `Settings.sh` | `$WRT_IP / $WRT_NAME / $WRT_SSID / $WRT_WORD` **未转义就进 sed 替换串**，而它正是文档推荐的改法（「改默认值就改 `WRT-CORE.yml` 的 `inputs.default`」，那里没有任何字符校验）：`&` 会展开成整个匹配、`/` 让 sed 报错、`\` 吞掉后一字符。**要紧的是改 SSID / 密码那两处零回读断言**（唯一那条 wifi 回读告警在 `$WIFI_SH` 分支里，而该分支永不执行）⇒ 密码含 `/`（WPA 密码里很常见）时会**静默保持上游默认**，极端情形是空密码 AP，而 Release 说明照抄 `WRT_SSID/WRT_WORD` | 加 `esc()` 并转义 4 处替换串；给 uc 分支补 SSID / 密码的回读断言 |
| `Packages.sh` | `rustup target add … \|\| true` 与 `rustup component add rust-lld \|\| true` —— **注释自己写着**缺 rust-lld 会导致编译失败，代码却把失败吞掉且无重试 ⇒ 故障被推迟几小时到 Compile Firmware，以一条 cargo 报错出现，离根因很远 | 抽 `add_component()`：重试 3 次、最终 `::error::` + `exit 1` |
| `Packages.sh` | `[ -d "$SRC_DIR" ] \|\| { echo …跳过; return 0; }` —— 同一函数里「单个覆盖层文件缺失」是硬失败，**整个源目录缺失**却静默跳过（后果更大：`Files/` 是 TTL 规则 / sysctl / uci-defaults / init.d 的全部来源）。原先没变成静默洞，只是**靠 `ApplyFlowOffload.sh` 的副作用兜住** | 改为硬失败 |

### 8. 自我纠错：5G 频宽那段的结论**撤回**

第一轮我在 `Scripts/Settings.sh` 与 README 里写了「注释理由与真机不符，**上游默认本来就是 160MHz**」。第二轮（上游源码 + 真机取证）复核后，**那条更正本身是错的**，已撤回改写：

| 事实 | 证据 |
| :-- | :-- |
| 上游模板**会把频宽钉在 80** | `mac80211.uc`：`let width = band.max_width; … else if (width > 80) width = 80;` 之后 `htmode += width` ⇒ 只要 5G 的 `max_width > 80`，生成的后缀必然是 80（EHT80/HE80）。所以原注释「保持 80MHz 上限」**与上游行为一致** |
| 真机的 160MHz **不能作为编译产物的证据** | 那台设备的 Wi-Fi 被手工改过：`default_radio1.ssid` 不是默认的 OWRT（是 `Ajmd007-5G`）、`encryption` 是 `sae-mixed` 而不是脚本会设的 `psk-mixed` —— 读数反映的是**用户的选择** |
| 5b 节到底有没有生效**无法判定** | 它确已执行（`/etc/uci-defaults/` 已被消费、同批次的 rpcd respawn 改动在真机生效），但用户的手工改动同样会覆盖它 |

**教训**：拿「真机当前值」推断「编译产物状态」之前，必须先排除「用户改过」这个混杂因素。这次恰好有 `ssid` 与 `encryption` 两处独立证据说明该机被改过；没有它们，就会把用户的选择当成脚本失效的证据。

### 9. 验证

| 项 | 结果 |
| :-- | :-- |
| `bash Scripts/SelfCheck.sh` | **C1~C10 全部通过**（含扩展后的 C9） |
| C9 变异验证 | 删 `PRIVATE.txt` → 判红；还原 → 全绿 |
| 6 个 workflow YAML | 逐个 `yaml.safe_load` 通过 |
| 真机只读核对 | sysctl 13 项 + 端口段、RPS/XPS 掩码、`packet_steering` 已停用、`apk-index-cache` 软链与索引、
MT5700M 接口/防火墙 wan 区/DNS/USB autosuspend、`ubus call mt5700 logs`、SQM/mwan3 有无 —— **均与仓库声明一致**（除上面 D1/D2/D3） |

**诚实边界**：

1. **没有实机验证的改动**：`WRT-CORE.yml` 的 Token 改动（需要真跑一次 Release 才能确认
   `action-gh-release` 的默认 token 生效）、`upload-artifact` 步骤、`BRANCH_SLUG`、
   Auto-Clean 的 `exit 1` 判据 —— 都需要一次真实 workflow 运行。已尽量选有官方文档/源码
   兜底的写法（如 action.yml 的 `default: ${{ github.token }}`）。
2. **没有改的**：Wi-Fi 频宽行为（见 D3，触及 DFS 需真机带回滚验证）；`GENERAL.txt` 里
   「通用层却含 H5000M 专属项」的结构问题（当前只有单机型，下沉收益小于改动风险，
   仅把 README 的描述改准）；Release body 硬编码机型文案（同因）；
   缓存 restore/save 的 key/path 双写（需要一条静态自检才能防漂移，本轮未做）。
3. **第二轮审计发现、但本轮仍未改的**（都属「潜伏」或需真机验证）：
   - `Handles.sh` 的 tailscale 补丁 `sed -i '/\/files/d'` 删的是**含 `/files` 的整行**，
     而上游那两行是必需的安装规则（`$(INSTALL_BIN) ./files//tailscale.init` 等，双斜杠无害）
     ⇒ 包只装二进制、没有 `init.d` 与配置，脚本却打印假成功。当前 `Config/*.txt` 无该符号
     （未启用），属潜伏；
   - `Handles.sh` 的 argon 主题 sed 无左边界：会把 `dark_primary` 一并改成同一颜色，
     且守卫单靠 `dark_primary` 即可满足（上游改名普通 `primary` 时仍打印 `has been fixed!`）；
   - `Settings.sh` 的 `EDIT_FILES` 只覆盖「find 一个文件都没找到」，**不覆盖「锚点不存在」**，
     而 GNU sed 零匹配返回 0 —— 其中 `EDIT_FILES "/attendedsysupgrade/d"` 对上游 master
     的 6 个 collection **已经永远零匹配**（真正拦住它的是 `Config/GENERAL.txt` 的 `=n`）；
   - `Packages.sh` 的 `curl … | sh` 装 rustup 无校验和、且脚本无 `pipefail`（curl 失败时
     `sh` 读空 stdin 仍返回 0）；honk 预编译 apk 从第三方 release 取 `latest` 且
     `apk add --allow-untrusted`（显式关掉签名校验）—— 两者都属「启用后即为高风险」；
   - `nftables.d/12-mangle-ttl-128.nft` 依赖 fw4 生成的 `$wan_devices` 宏：**未确证**它在
     宏不存在时是「fw4 整体拒绝加载」（= 没有 NAT、客户端全断）还是仅该 include 失败。
     需在真机上清空 wan 区 `network` 后 `fw4 reload` 观察（本轮没做——那是一台在用的设备，
     不动它的防火墙）；加固方向是本文件自带 `define`，或写成 `oifname { "eth1", "eth2" }`。

## [2026-09-27 · 二] 修「无法执行 apk update 命令：SyntaxError: Unexpected end of JSON input」

用户报错原文即这一句。**真机全程复现并计时，非推测。**

### 1. 根因：uhttpd 的 60 秒 CGI 预算，撞上「跑完才输出」的包管理脚本

| 环节 | 证据（都是打开的代码 / 量出来的数） |
| :-- | :-- |
| 前端怎么炸的 | `/www/luci-static/resources/fs.js` 的 `handleCgiIoReply`：`case 'json': return res.json()`。对**空 body**，`res.json()` 抛的正是 `SyntaxError: Unexpected end of JSON input`；而它前面先过 `res.ok && status==200` ⇒ 说明服务端给的是 **HTTP 200 + 空 body** |
| 后端为什么不输出 | `/usr/libexec/package-manager-call` 的 `install\|update\|upgrade\|remove` 分支：先 `$cmd $action "$@" >/tmp/ipkg.out 2>/tmp/ipkg.err`，**全部跑完之后**才 `json_init … json_dump` —— 中途 stdout 一个字节都没有 |
| 谁掐的连接 | uhttpd 启动参数 `-t 60`（`/etc/config/uhttpd` 的 `script_timeout='60'`）。受控实验：占住 `/tmp/ipkg.lock` 让 CGI 全程静默，浏览器点击后**恰好 60.2 秒**弹出上面那句报错 |
| 为什么越点越死 | 被掐掉的只是 `cgi-io`，**孙进程 `apk update` 会继续跑**（真机实测存活 68 分钟），期间一直占着 `/tmp/ipkg.lock` 与 apk 数据库锁 ⇒ 再点一次要么继续等锁、要么直接失败 |

为什么 60 秒必然不够：本机 WAN 是 5G 漫游，6 个源逐个下、还常被截断重试
（`ERROR: wget: exited with error 4` / `unexpected end of file`），实测一次完整 `apk update`
耗时分钟级、最坏一次 **68 分钟**。**60 秒预算 ＝「Update lists 永远失败」**，
这跟包管理器本身好不好完全无关 —— 换个快的网络就一切正常，所以极难归因。

### 2. 三处改动

| 位置 | 改动 | 治的是 |
| :-- | :-- | :-- |
| `Files/etc/uci-defaults/99-mt5700-sys` 第 6 节 | `uhttpd.main.script_timeout` 60 → **300** | 「第一次点击就注定失败」 |
| `Scripts/Handles.sh` | 既有补丁串里 `flock -x 200` → `flock -n -x 200`，并加二次核对 | 「并发点击空转到超时、再报一句 JSON 解析错」 |
| `Files/etc/init.d/apk-index-cache` | 后台 `apk update` 加 `timeout 300` | 开机那次更新可能占着数据库锁几十分钟 |

★ 用 `-n` 而不是 `-w <秒>`：本机 BusyBox flock（v1.38）**只有 -s/-x/-u/-n**，
没有 `-w`（真机 `flock --help` 核过）。拿不到锁就立刻失败，走脚本既有的
`else → code=255 / stderr="Failed to acquire lock"` 分支，正常吐 JSON。
★ 只抬 `script_timeout`，**不动 `network_timeout(=30)`** —— 后者是读请求头的空闲上限，
与「CGI 能跑多久」无关，一并放大只会放宽无谓的连接占用。

### 3. 真机验证（A/B，均带计时）

| 场景 | 改前 | 改后 |
| :-- | :-- | :-- |
| 占锁时点「Update lists」 | 空转 **60.2 秒** → `SyntaxError: Unexpected end of JSON input` | **0.2 秒** → 弹窗给出可读结果：`错误 / Failed to acquire lock / apk update 命令失败了，代码为 255。` |
| 让 CGI 静默超过 60 秒 | 60.2 秒被掐、空 body | HTTP 层直接测：客户端 **100.1 秒**自己超时，服务端始终**没**关连接 |

（同一个构造、同一个观测点，只改配置，前后对照。）

### 4. C10 守卫 + 变异验证

新增 C10：uhttpd 预算 ≥120，且 Handles.sh 的 **sed 替换串**里两个补丁都在。

⚠️ 第一版判据写成裸 `grep 'flock -n -x 200'` —— 它会命中 Handles.sh 里那句**运行时自检**
（`if grep -q 'flock -n -x 200' "$PMC_FILE"`），于是**替换串被改坏时守卫照样绿**。
「守卫被自己的自检顶住」，与 C9 的 CNT 陷阱同类。已改成锚定 `if flock -n -x 200; then|`
（尾部 `|` 是 sed 分隔符，只在替换串里出现）。

变异：**对照绿 / R1 预算改回 60 → 红 / R2 替换串丢掉 `flock -n` → 红 /
R3 替换串丢掉 `--allow-untrusted` → 红 / 在注释里写 `script_timeout='60'` → 仍绿**
（这一条专门证明守卫排除了注释行），逐字节还原一致。

### 5. 顺带澄清

用户起初怀疑「是不是你改了我的 **apk 源**」—— **没有**：仓内 `repositories.d` / `distfeeds`
字样全部出现在注释与文档里（唯一功能性代码是一句**只读** `grep` 数源条数），
真机 `distfeeds.list` 仍是原厂 6 条 immortalwrt snapshot 源，
编译上游 `immortalwrt/immortalwrt` 是 2026-08-29 由 LianXia233 切换的。
这条报错与「源」无关，纯粹是超时预算问题。

## [2026-09-27] 修 apk-index-cache：软链从来就没建成过（脚本进了固件、被 enable，却什么都没做）

起因是用户问「你是不是改了我的 apk 源」。**核查结论：源一行都没动。**

| 核查点 | 结果 |
| :-- | :-- |
| 仓库 HEAD / 工作区 | `f38b4ae`（2026-09-23 14:56）· 干净 · 无 stash · 无其它分支领先 |
| GitHub 远端 main | `f38b4aee87fab2d4a630d6bcfe36190438f81539`（API 核对，与本地同一 SHA） |
| 仓内 `repositories.d` / `distfeeds` 字样 | **全部出现在注释与文档里**；唯一功能性代码是一句**只读** `grep` 数源条数 |
| 真机 `/etc/apk/repositories.d/` | `distfeeds.list` 仍是原厂 6 条 immortalwrt snapshot 源；`customfeeds.list` 只有注释 |
| 编译上游源 `immortalwrt/immortalwrt` | 2026-08-29 由 LianXia233 切换，与本次无关 |

但顺着这条线复查 2026-09-23 上线的 `apk-index-cache`，**发现它自上线起每一次开机都失败** ——
等于没生效。所以「改回原样」在行为上其实早就成立了，只是仓里多了一段不工作的代码。

### 1. 根因：少建了一层父目录

真机（2026-09-27）：

```
logread          →  user.notice apk-index-cache: 软链创建失败，未改动 apk 行为
/usr/share/apk/cache  →  空                # 持久目录里一个索引都没有
/var/cache/apk        →  真目录（不是软链） # 这个目录是 apk 自己建的
/etc/rc.d/S96apk-index-cache  →  存在      # 脚本确实进了固件、确实被 enable
```

`ls -ld /var` → `var -> tmp`：**本固件 /var 是指向 /tmp 的软链**，而 /tmp 是 tmpfs，
于是**每次开机 /var/cache 都不存在**。设备上的对照实验：

```
父目录 /var/cache 存在   → ln -sfn rc=0，软链建成
父目录 /var/cache 不存在 → ln: /var/cache/apk: No such file or directory，rc=1
```

脚本只 `mkdir -p` 了持久目录，**没建链接目标的父目录** `/var/cache`。ln 一失败，
下面 `[ ! -L "$APK_CACHE" ]` 当场 `return 1` —— 连「后台补一次索引」都不会执行。

### 2. 为什么 09-23 我的验证是绿的（教训）

当次复位步骤是「清持久目录 + 把 `/var/cache/apk` 留成**空目录**」→ 走搬迁分支：
cp → `rm -rf /var/cache/apk` → `ln`。而此时 `/var/cache` **因为我刚建过 apk 目录而必然存在**
—— 失败的前置条件被测试装置自己消掉了。**「在错误的前提下验证通过」**，
所以这次把这条判据交给机器（C8-④）。

### 3. 改动

| 位置 | 改动 |
| :-- | :-- |
| `Files/etc/init.d/apk-index-cache` | `start()` 补 `mkdir -p "$(dirname "$APK_CACHE")"`；后台 update 失败时**不再猜原因**，改为逐字记录 apk 原话 |
| `Scripts/SelfCheck.sh` | C8 增加第 ④ 项：必须为软链的父目录建目录（锚在 `dirname … APK_CACHE` 上，不写死 `/var/cache/apk`，免得守卫跟着代码各自漂移） |

★ 顺带修掉一处**无依据归因**：原本失败日志写「多半是此刻还没联网」，
真机实测真实原因是**数据库锁被占用**（另一支 `apk update` 尚未退出
→ `ERROR: Unable to lock database: Resource temporarily unavailable`），与网络毫无关系。
带着一个错误结论去排障，会让人白查一遍 WAN。

### 4. 真机验证（A/B + 重启模拟，非推测）

从**真正的空 tmpfs** 起步（`/var/cache` 不存在，这正是 09-23 漏掉的前置条件）：

| 步骤 | 旧版（09-23 那版） | 修复版 |
| :-- | :-- | :-- |
| `start` 返回码 | **rc=1** | **rc=0** |
| `/var/cache/apk` | 不存在（故障复现） | `-> /usr/share/apk/cache` |
| 日志 | `软链创建失败` | `索引不完整（0/6 条源）…` |

重启模拟（抹掉 `/var/cache` = 真机重启后的状态）：

| 场景 | `apk list -a` |
| :-- | :-- |
| 抹掉后不跑脚本（＝ 09-23 版本的实际效果） | **0** ← 就是「软件页空的、要手动 Update lists」 |
| 跑修复版 `start` 之后，**不联网**立即查 | **9656 包 / 0.5s**（纯读持久缓存） |

幂等：连跑两次 `start`，rc=0，软链与内容不变。

### 5. 变异验证

C8-④ 配一对对照 + 两个变异：**对照绿 / R1（父目录指错）红 / R2（整块删除）红**，
逐字节还原一致。

### 遗留（非本次范围）

- 本次真机只补到 **5/6 条源**（9668 包）。差的 1 条是蜂窝链路抖动
  （`ERROR: wget: exited with error 4` / `unexpected end of file`），**非代码问题**；
  脚本的**条数比对**会在下次开机自动重试（have<want 不会自锁，这正是当初刻意不用
  「有无判定」的原因）。
- `/usr/share/apk/cache` 不在 sysupgrade 保留列表内，刷机后要重新联网补一次 —— 刻意如此
  （跨版本保留旧索引会让软件页列出一批已不存在的包，比留空更误导）。

## [2026-09-23] 修 LuCI「系统 → 软件」页每次重启都不可用（apk 索引缓存在 tmpfs）+ 新增 C8/C9 守卫

症状（2026-09-23 真机复现）：重启后打开「系统 → 软件」，可用包列表是空的、
点安装/卸载会失败，**必须先手动点一次右上角「Update lists…」**才恢复正常。

### 1. 根因：索引只活在内存里

```
readlink -f /var            -> /tmp      # OpenWrt 的 /var 是 tmpfs
apk 索引缓存目录            -> /var/cache/apk
```

索引随重启蒸发。把该目录挪走后复现出的现象，比「列表空了」更能误导人：

- 页面取「可用包」的接口返回 **HTTP 200，body 只有 4 字节 `[ ]`**（看起来像网络成功、源里没包）；
- 任何 apk 操作先甩 6 条 `WARNING: opening from cache … No such file or directory`；
- 空缓存时 `apk list -a` 返回 **0** 且**不会**联网补拉 —— `apk update --help` 说的
  「索引过期会自动刷新」是对**已存在**的条目而言；条目压根不存在时它把这个源当成空的。

⭐ 区别于另一个同名现象的坑：`ubus call file exec` 有 **128KB 返回体上限**（实测 128KB 通过、
256KB 起 `Command failed`），而软件页的列表是 979KB / 11.7MB。所以**不能用 ubus 那
条路去测软件页** —— 一律假失败。页面真正走的是 cgi-io 的流式 exec。

### 2. 修法：`Files/etc/init.d/apk-index-cache`（新增）

开机把 `/var/cache/apk` 换成指向持久目录 `/usr/share/apk/cache`（overlay）的**软链**，
索引不齐时后台补一次 `apk update`。选软链而不是给调用方加 `--cache-dir`：

| 方案 | 为什么（不）选 |
| :-- | :-- |
| 软链 `/var/cache/apk` → 持久目录 ✅ | 对调用方**完全透明**：LuCI 软件页、rpcd 的 `package-manager-call`、命令行三条路都不用改，也不必知道这条约定 |
| 给所有调用方加 `apk --cache-dir` | apk 确实支持这个全局选项，但 LuCI 那条调用链没法给它加参数 |
| 开机把索引从持久目录拷回 `/var` | 每次开机多做一遍 1.5MB 读改写，且 apk 之后写回 tmpfs，重启照样丢 |

体积可接受：6 条 APKINDEX 合计 `du -sk` = **1468**（约 1.5MB）。

⚠️ 判定必须用**条数比对**（索引条数 vs `repositories.d` 里已配源条数），不能用「有没有
`APKINDEX.*`」。真机实测：6 个源少掉 2 个索引时，可用包从 **10429 掉到 1743**，而
「有无判定」会认为已就绪 —— 缺的那两个源此后**永远**不会被补齐（apk 只刷过期条目、
不补缺失条目），现象是「某个 feed 的包在软件页搜不到」，极难归因。

### 3. 真机验证记录（非推测）

| 步骤 | 结果 |
| :-- | :-- |
| 复位到故障态（清持久目录 + `/var/cache/apk` 空目录） | `apk list -a` = **0**，`list-available` 返回 4 字节 |
| 执行 `start` | 软链建立；30 秒后后台 update 补齐 6 条索引、10429 个包 |
| **模拟第二次重启**（抹掉软链 + 建空目录） | 列表先为 0 → 再 `start` → 列表**立刻**回到 9560+，**无需联网** |
| 连跑两次 `start`（幂等） | rc=0，不重复铺 Keys |
| 故意删 2 个索引 | 日志识别「索引不完整（4/6 条源）」→ 后台补 → 恢复 6/6、10429 包 |
| `stop` | 软链移除、回到原行为，持久目录内容保留 |

### 4. C8 守卫：文件进了固件 ≠ 会被执行

三件事缺一件都是**静默失效**：固件照出、能刷、能开机，只有软件页不可用 ——
而排障时几乎不会想到「脚本其实从来没跑过」。

| 检查 | 缺了会怎样 |
| :-- | :-- |
| 首行是 shebang | `Packages.sh` 按 shebang 判 +x，缺了就以 0644 进固件，`enable` 直接失败 |
| 声明 `START=` | rc.common 靠它排开机顺序，没有就压根不进启动序列 |
| uci-defaults 里有非注释行对它 `enable` | OpenWrt **不会**因为文件躺在 `/etc/init.d/` 下就自动启用 |

启用链写在 `Files/etc/uci-defaults/99-mt5700-sys` 第 5 节（与本仓既有惯例一致：
`mt5700-rps` / `mt5700-smp` 都在 uci-defaults 里 enable）。

### 5. C9 守卫：README 结构树不得漏列实际文件

上一轮**人工**修过 6 处文档与代码矛盾，但人工比对没有记忆 —— 那轮新增的
`SelfCheck.sh` 与 `Guard-Check.yml` 就都没进结构树，本轮的 `apk-index-cache`
要不是先写了这条守卫也会漏。**同一个坑踩到第三次**，交给机器：

凡 `Scripts/*.sh`、`Files/etc/**`、`.github/workflows/*.yml` 里真实存在的文件，
其 basename 必须出现在 README 结构树里。★ 按 basename 而非相对路径比对 ——
README 里写的是 `init.d/mt5700-rps` 这种带父目录的短名，按路径比对会全量误报。

★ 与 C6 同一道防线：**扫描到的数量本身也要断言**（`CNT >= 20`）。find 的目标目录
一旦改名或失效，`for` 循环一轮都不进 → `MISS` 恒为空 → 这条守卫退化成**永远通过**，
而它恰恰是最后一道防「文档与代码走散」的检查。

### 6. 变异验证（证明守卫真能检出）

C8 四个变异 + C9 三个变异，**7/7 判红**。

⚠⭐ 排查时踩到的坑，值得记一笔：第一遍做 C9-3（把 find 目标改坏）时守卫**没红**，
以为是守卫恒绿 —— 实际是 `replace(s, old, new, 1)` 改到了**第一次出现**的那个
同形 `find`，而它在 **C1 段**（语法检查扫 Scripts），C9 段原样未动。
教训：**做「故意违反」时必须把锚点锁进目标段落的上下文**（这次改成
`MISS=""\nCNT=0\nfor F in $(find Scripts...`，并断言锚点唯一）。否则会得出
「守卫失效」的错误结论，进而可能把一个其实是好的守卫改掉。

### 7. 顺带修：README 结构树补 3 项

`Guard-Check.yml`、`SelfCheck.sh`、`Files/etc/init.d/apk-index-cache` 均已入树（由 C9 把关）。

---

### 遗留（未改，非本次范围）

本机软件源是 `https://downloads.immortalwrt.org/snapshots/**`（`DISTRIB_RELEASE='SNAPSHOT'`），
**每天滚动**且没有历史保留。这意味着：

- 自编译固件的内核模块自带 vermagic 指纹，源里的 kmod 版本随时可能与本机内核不一致，
  表现为装 `kmod-*` 失败或装上后 `modprobe` 报 magic mismatch；
- 重装某个包时源给的可能比已装的**旧**（实测：本机 `26.261.08411`，源里是 `26.232.63255`）。

彻底解需要「把源锁定到编译时刻对应的那套产物」—— 即 CI 每次编译后把用到的
`packages.adb` 作为 Release 资产上传并改写 `distfeeds.list`，代价不小，不在本次范围内。
运维侧规避：需要装包时优先用 `apk add <本地编译产物>`，或手动指定与目标一致的版本。

## [2026-09-23 · 全仓走查] 收敛重复的默认值、新增静态自检闸门（C1~C7）、修 README 四处与代码矛盾

主题仍是**「同一件事只留一个家」**：本仓此前最典型的重复是两个调用工作流把
7 个固件身份类 input 逐字抄了两遍。

### 1. 7 个 input 下沉到 WRT-CORE（单一真源）

`WRT_THEME` / `WRT_NAME` / `WRT_SSID` / `WRT_WORD` / `WRT_IP` / `WRT_PW` / `WRT_MARK`
原本在 `WRT-BUILD` 与 `H5000M-MT-AUTO` 里各写一遍（值完全相同）。抄两份的必然结果是
**改一处漏一处**：改默认密码后手动编译变了、定时编译还是旧的，而这类问题只会在
刷完机拿旧密码连不上时才暴露，排查时很难想到是编译脚本。现在改 `WRT-CORE` 的
`inputs.default` 一处即可，两边同时生效。

⚠️ `MT_MODE` **刻意不下沉**：它的默认必须是 `""`（不装 MT 插件，保持普通 CI 行为），
两个调用方各自传 `MT5700` 属于**有意的差异化**而非重复。把它的 default 改成
`MT5700` 会悄悄改变「调用方不传」的语义 —— 这条已写进 C7 守卫。

### 2. 新增 `Scripts/SelfCheck.sh` + `.github/workflows/Guard-Check.yml`

本仓此前**没有任何自动化检查**：编译脚本的副作用是拉源码 + 编几小时固件，没法 cheap 地
跑一遍验证；能 cheap 做的是静态契约检查。七条检查项每条对应一个真踩过的坑：

| 项 | 检查什么 | 出处 |
| :-- | :-- | :-- |
| C1 | shell 语法 + 禁 C 风格块注释 | 块注释的 `/*` 会被 glob 展开成 `/` 下文件列表并执行，`bash -n` 查不出 |
| C2 | workflow YAML 可解析 | YAML 缩进错误在 Actions 里的报错信息极差 |
| C3 | 调用方不许再抄 WRT-CORE 的 default | 本次 C1 节的重复，防复发 |
| C4 | 单个 `Config/*.txt` 内 `CONFIG_*` 符号不重复 | kconfig 只认最后一条，前者静默失效 |
| C5 | `Files/` 覆盖层必须是 LF | CRLF 下 `#!/bin/sh` + CR 找不到解释器，脚本**静默不执行** |
| C6 | `plugin-deps` 标记区存在且 ≥10 项 | 标记被改名会让 WRT-CORE 的依赖断言退化成恒绿 |
| C7 | `MT_MODE.default` 必须为空 | 见上 |

闸门独立成 workflow（而非挂进 WRT-CORE）：编译 job 的头几步是装环境 + 拉源码，
走到能判断配置对错已过去好几分钟；静态检查秒级反馈，也不占用编译的 345 分钟预算。

### 3. README 四处与代码矛盾（会让人按文档排错走偏）

| 位置 | 原写 | 实际 |
| :-- | :-- | :-- |
| 默认配置表 | 5G 频宽 `80MHz (HE80)` | `Settings.sh` 改的是 **EHT160**（Wi-Fi 7） |
| 默认配置表 | Flow Offload `auto` | `WRT_FLOW_OFFLOAD` default 是 **off**，`Files/etc/mt5700/flow-offload` 也是 `MODE=off` |
| Flow Offload 说明 | 默认 `auto`、定时编译取 `auto` | 同上，且 `auto` 在本机**等价于 `off`**（固件带 TTL 规则，auto 会查到并强制关） |
| 项目结构树 | `fq_codel`、漏 5 个文件 | `tcp.conf` 是 **fq**；漏列 conntrack.conf / stability / init.d×2 / hotplug |

### 4. 其它

- **打包循环**：`for FILE in $(find …)` 改成 `while IFS= read -r`（前者按空白分词，产物名含空格会被拆成两段并丢文件），相关变量全部加引号。
- **删 `make clean -j$(nproc)`**（打包步骤末）：产物此时已全部 `mv` 进 `upload/`，剩下的目录不再被任何后续步骤读取；`rm -rf` 几十 GB 是纯浪费机时，而 `-j` 对 `clean` 毫无作用（看着像并行，实际串行）却容易误导。
- **`plugin-deps` 锚点**：awk 的 `/^# >>> plugin-deps:begin/` 缺行尾锚点，`…:beginX` 也会被当成 begin —— 标记改名后断言照样"通过"（恒绿）。`SelfCheck` 与 `WRT-CORE` 里那份 awk 一起修。
- `Settings.sh` 的 `sed` 目标加引号；`$WIFI_SH` **刻意不加**（find 可能返回多个路径，需要空白分词），已在注释里写明。
- 删 `VerifyMTMode.sh` 的 `pkg_disabled()`（全仓零调用点，且与 `pkg_selected()` 真值互补，留着就是同一件事两个家）。

### 本轮新教训（可复用）

1. **★★ 变异验证又抓到三处「守卫自身的缺陷」** —— 只看到「全绿」远不够，这次
   8 条变异里第一轮就有 2 条没被检出，第二轮还额外暴露了 1 条误报：
   - `/*` 正则写成 `(^|[[:space:]])/\*` 时，星号不转义是**量词**（"斜杠出现 0 次或多次"）→ 全仓飘红；转义后又发现**锚点太严**（缩进的块注释漏检），退化成"任意位置"又**误报合法 glob**（`/sys/class/net/*/…`、`/etc/nftables.d/*.nft`）。最终用「行首 / 空格后 / tab 后」三条显式 `-e` 分支。
   - `plugin-deps` 缺 `$` 锚点 → 标记改名被放过（恒绿）。
   - **不能只跑一次**：修正正则后必须同时看「基线仍绿」和「变异仍红」，两头都要。
2. **★ Windows 的 Git-Bash grep 有两个致命坑**（写跨 Windows/Linux 的 shell 守卫必看）：
   - **字符类恒不匹配**：`grep -Ec '^CONFIG_[A-Za-z]+='` → 0，而 `'^CONFIG_[^=]+='` 与 `'^CONFIG_.*='` → 6。`[[:space:]]`、`[[:alnum:]]` 同样失效。写了字符类等于在 Windows 上**恒绿**。
   - **读文件时剥 CR**：造一个真 CRLF 文件（`printf 'a\r\nb\r\n'`），`grep -c` 照样报 0 → 用 grep 查行尾是**恒绿守卫**。改用 `tr -dc '\r' | wc -c`（字节级，两种环境一致）。
   - 另：`$'\r'`（ANSI-C quoting）在该 bash 里**不展开**，且命令替换内外行为不一致（同一条命令直接跑得 0、赋给变量得 1）。生成特殊字符一律用 `printf`。
3. **★ 代理报告的结论必须验证**：本轮两个审查代理都把 `make clean` 判成 P0（"会删掉工具链缓存"）。
   查 OpenWrt 顶层 `Makefile` 后确认是**误报** —— `_clean` 只删 `$(STAGING_DIR)`（target 子目录），
   而 `dirclean` 才**额外**删 `$(STAGING_DIR_HOST)`、`targetclean` 才**额外**删 `$(TOOLCHAIN_DIR)`；
   这两个"额外"正说明 `clean` 不碰 host 与 toolchain，缓存路径 `staging_dir/host*`、`tool*` 安全。

### 已定位、本轮未动

- **fullcone 口径三方不一致**：`Config/GENERAL.txt` 明确 `kmod-nft-fullcone is not set`、
  四个 uci-defaults 都没有下发 fullcone，但 `FIRMWARE_OPTIMIZATION_REPORT.md` 写
  「fullcone 在 firewall defaults=1」。二者必有一错，但**裁决需要真机取证**
  （`uci show firewall` + `nft list ruleset` 看 NAT 是 fullcone 还是 masquerade），
  不凭文档推测改动 —— 历史上因"两份文档数字打架"而把对的那句改错过一次。
- `UPDATE_VERSION()`（`Packages.sh`）无调用点但属上游模板函数，保留（理由见 2026-09-21 记录）。
- `Handles.sh` 里 honk 修补块的 `[ -f "$HONK_FILE" ]` 当前恒为假，是「随
  `INSTALL_HONK_PREBUILT` 一起启用」的配套修补，刻意保留，注释已说明别删。

---

## [2026-09-22 · 编译失败修复] 常见依赖断言拦下 3 个包：crc32c 撤销、`xz` 必须与 `xz-utils` 成对

触发：`WRT-BUILD` 在 defconfig 之后的断言步骤失败 ——

> `以下常见依赖未进 .config（包名被 kconfig 静默丢弃，或上游改名）： kmod-lib-crc32c xz tar`

### 1. `kmod-lib-crc32c` —— 撤销：这个符号在本树根本不存在

- 上一轮是照"两套基线都有"加进来的。基线（内核 6.12 / 6.6）那时它还是模块，
  本树内核 **6.18 已把 crc32c 编成内建**，内建之后就没有对应的 `kmod-*` 包了。
- 证据：上次成功构建产出的完整 `.config` 里搜不到 `CONFIG_PACKAGE_kmod-lib-crc32c`，
  连 `CONFIG_LIBCRC32C` 都没有；真机 `/lib/modules/6.18.52/` 下没有 `libcrc32c.ko`，
  而依赖它的 `kmod-fs-btrfs` 照常工作。
- 这一类包**加不上去** —— 写进 Config 会被 defconfig 丢掉，随即被 CI 断言拦下。
  已改成注释说明并移出断言区。

### 2. `xz` / `tar` —— 根因是上一轮把 `xz-utils` 删掉了

- 上游 `utils/xz/Makefile`：`Package/xz` 是模板生成的子包，`DEPENDS:=xz-utils +liblzma`。
  上一轮为了修"空 meta"，只写了 `xz=y` 却把 `xz-utils=y` 删掉 —— 等于把 `xz` 的
  **硬依赖**抽走，defconfig 于是静默丢弃 `CONFIG_PACKAGE_xz=y`。
- `tar` 是连带受害者：`Package/tar` 的 DEPENDS 含 `+PACKAGE_TAR_XZ:xz`，
  而 `PACKAGE_TAR_XZ` 默认 `y` ⇒ `xz` 掉了，`tar` 也一起被丢。
- 修法：**两行都留** `CONFIG_PACKAGE_xz-utils=y` + `CONFIG_PACKAGE_xz=y`
  （meta 包本身只有 782 字节，代价可忽略）。

### 3. 断言本身按预期工作

30 项里精确点名 3 项、其余 27 项通过 —— 说明「整行标记 + awk 自动提取 + 逐个 grep `.config`」
的守卫是有效的。kconfig 对不存在的包名是**静默丢弃**（defconfig 照样成功、不报错），
没有这道断言的话，"以为配上了其实没配上"会一路带到刷机之后才发现。

---

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

