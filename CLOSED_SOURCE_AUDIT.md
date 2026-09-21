# 闭源模块可移植性审计（MT7987A / H5000M）

- 审计日期：2026-09-21
- 审计对象：`Mwrt-H5000M-1139-24-20260921.bin`（厂家基准固件）与 `Hiveton/higowrt` 中的驱动/加速组件
- 目标项目：`woshinibabao1/OpenWRT-CI` → immortalwrt/immortalwrt **master**，内核 **6.18.52**
- 审计方式：GitHub 源码多方核验 + 真机（192.168.10.1）运行态核验，**不采信经验推断**

---

## 一、结论速览

| 组件 | 性质 | 源码可得性 | 本项目能否用 | 判定依据 |
|---|---|---|---|---|
| `mt_wifi7` | **闭源**（MTK SDK 预编译） | 仓库内**无任何 .c/.h**，只有 Makefile/config.in/patches/init 脚本 | ❌ 不可用 | higowrt 包内无源码；SDK 绑定 6.6/6.12 |
| `mt_hwifi` | **闭源** | 同上，包内无源码 | ❌ 不可用 | 同上 |
| `warp` | **闭源** | 包内仅 Makefile/config.in/patches | ❌ 不可用 | 同上 |
| `mt_wifi_osal` / `wifi-profile` | **闭源** | 无源码 | ❌ 不可用 | 同上 |
| `mtkhnat` | **GPL 开源** | 完整 C 源码可得（hnat.c 34KB、hnat_nf_hook.c 96KB …） | ⚠️ 理论可移植，实际不建议 | 源码来自 MTK SDK **6.12** 分支；本项目 6.18 走的是主线 `mtk_ppe_offload` 架构 |
| `mtk_eth_soc`（SDK 版） | **GPL 开源** | 可得（6.12） | ⚠️ 同上 | 与主线 6.18 驱动差异大，替换等于换掉整个以太网栈 |
| `mtk_wed` / PPE（MT7987） | **GPL 开源，已在你内核源码树里** | 主线自带 + openwrt backport | ⏳ 上游尚未完成，等即可 | 见第三节 |

**一句话：真正"闭源拿不到"的只有 WiFi7 那一坨；但它对你这台设备几乎没有价值。**
加速缺失的真因不是闭源，而是 **MT7987 的 WED 上游支持未完成**（且你的主 WAN 走 USB，硬件加速本来就管不到）。

---

## 二、闭源实锤证据

### 2.1 包内无源码（higowrt 仓库实证）

```
package/mtk/drivers/mt_wifi7/      → Makefile(18KB) config.in(32KB) files/ patches/  【无 .c/.h】
package/mtk/drivers/mt_wifi7/files → 仅 8 个 .sh / .init 启动脚本
package/mtk/drivers/mt_hwifi/      → Makefile(38KB) config.in patches/               【无 .c/.h】
package/mtk/drivers/warp/          → Makefile config.in patches/                     【无 .c/.h】
```

仓库 README 亦明确声明：`MediaTek Wi-Fi 7 驱动为 MTK 闭源 SDK，版权归 MediaTek 所有`。

### 2.2 版本壁垒（不可绕过）

- 厂家固件模块 vermagic = **6.6.94**，本项目内核 **6.18.52** → `insmod` 直接拒载（此前真机已实测）。
- 闭源 SDK 不是"单个 .ko"，而是一组互相依赖的模块（mtk_wed → mtk_warp → mtk_hwifi 串锁）+ 一批对内核的私有 patch。缺任何一环都起不来。
- 结论：**即使拿到 .ko 二进制也加载不了**，不存在"直接拿"的路径。

---

## 三、被误判为"闭源"的部分（重要修正）

### 3.1 mtk_hnat 其实是 GPL 源码

MediaTek 官方 feed（`mtk-openwrt-feeds`）与 higowrt 中均含完整源码，且 hnat.c 头部即为 GPL-2.0 声明：

```
target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_hnat/
  Makefile  hnat.c  hnat.h  hnat_debugfs.c  hnat_mcast.c  hnat_nf_hook.c  nf_hnat_mtk.h
```

**但**：该源码对应 **kernel 6.12 SDK 分支**；本项目 6.18 使用的是主线 `mtk_ppe_offload.c`（主线自 6.x 起自带 PPE 卸载，与 HNAT 是两套不同实现）。移植 HNAT ≈ 把整个以太网驱动栈换成 SDK 版本，与"一切以稳定为主"直接冲突 → **放弃，但理由是版本与风险，不是闭源**。

### 3.2 MT7987 的以太网/WED：设备树已就绪，驱动与固件缺口

| 检查项 | 结果 | 来源 |
|---|---|---|
| `mediatek,mt7987-eth` 已在跑 | ✅ eth0/eth1 正常 | 真机 `/sys/class/net/*/device/of_node/compatible` |
| MT7987 以太网支持补丁 | ✅ 已 backport：`750-net-ethernet-mtk_eth_soc-add-mt7987-support.patch` 等 3 个 | immortalwrt `target/linux/mediatek/patches-6.18` |
| 设备树 WED 节点 | ✅ 存在 `wed@15010000` + `wdma@15104800` | `mt7987.dtsi:926`；真机 dtb 已确认 |
| `mtk_wed` 驱动是否编入 | ❌ `modules.builtin` 中 wed 计数 **0**，无 `mtk-wed` platform driver | 真机实测 |
| 主线 mtk_wed.c 是否支持 7987 | ❌ 全文 7987 零命中（mtk_eth_soc.c / mtk_ppe.c 同样零命中） | torvalds/linux master |
| WO 卸载固件 | ❌ 上游 linux-firmware 只有 mt7981/mt7986/mt7988 的 wo 固件，**无 mt7987_wo.bin** | `package/firmware/linux-firmware/mediatek.mk`；真机 `/lib/firmware/mediatek/mt7987/` 仅 2.5G PHY 两个 bin |

**结论**：MT7987 的 WED 属于"上游还没做完"，不是闭源封锁。等上游补齐 WO 固件与驱动匹配即可，不需要去抄厂家固件。

---

## 四、为什么即便全套搬来也没收益（决定性理由）

你的**主 WAN 是 5G 模组的 USB CDC-NCM（eth2）**。PPE / HNAT / WED 这些硬件加速引擎只作用于 SoC 内置 GMAC（eth0/eth1）与直连 PCIe 无线，**管不到 USB 口**。

- 上网流量路径：`5G 模组 → USB → eth2 → CPU 转发` → 硬件加速命中率 ≈ 0
- 内置 GMAC 的流量（LAN↔LAN、有线 WAN）才可能命中，量级很小

因此"搬闭源加速栈"的投入产出比为负：**风险极高（换驱动栈），收益≈0（主路径用不上）**。

---

## 五、最终处置

1. **放弃**：`mt_wifi7` / `mt_hwifi` / `warp` / `mt_wifi_osal` / `wifi-profile`（闭源 + 版本壁垒 + 无收益）。
2. **放弃**：`mtk_hnat` 移植（GPL 可得，但 6.12→6.18 移植风险与稳定性冲突）。
3. **无线维持开源 mt76**：真机 mt7996e 已正常工作（`HW/SW Version: 0x8a108a10`，phy0.0/0.1-ap0 均已 up），无需闭源 WiFi 驱动。
4. **不再关闭 flow offload 的探索，但保持关闭**：现网按既有结论维持关闭（TTL 规则依赖 nftables 路径；关闭后客户端 HTTP 200 已实测通过）。
5. **留给上游**：MT7987 的 WED/WO 固件补齐后，可一键受益，无需自行移植。
