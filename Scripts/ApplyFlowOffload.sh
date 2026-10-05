#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# 构建期把 flow offload 选型写入固件 files 覆盖层：
#   ${GITHUB_WORKSPACE}/wrt/files/etc/mt5700/flow-offload
# 内容一行：MODE=<auto|off|on|on-hw>
# 该文件随固件打包，开机由 Files/etc/uci-defaults/99-mt5700-net 读取决策。
# 默认的 Files/etc/mt5700/flow-offload（MODE=auto）也会被 INSTALL_NET_TUNING 铺进
# 覆盖层，本脚本在其之后执行、用构建期选择覆盖它，保证「页面/编译期入口」生效。
#
# 退出码：
#   0 = 写入成功
#   1 = MODE 非法（编译期即失败，绝不带进固件）
#   2 = 目标目录不可写（wrt/ 软链未建好等环境异常）
#
# ★★ 2026-10-05 默认值由 off 改为 on，理由是原先的「必须关」依据被证伪（详见下）。
#
# ── 原来的理由（已作废，别再照着引用）──────────────────────────────────
# 原注释称：「真机实证（2026-09-21）卸载开着时客户端 HTTP 25 秒超时、
#   conntrack 带 [OFFLOAD]、正向 10 包只回收 1 包；关掉后同一请求 HTTP 200 / 1.0 秒。
#   故默认必须是 off。」
#
# ── 证伪过程（2026-10-05 真机 A/B，H5000M / kernel 6.18.52）──────────────
# 那次测试的**流量根本没经过这台路由器**：开发机有两块网卡且有线优先
#   有线 192.168.8.103 跃点 25 / Wi-Fi 192.168.10.202 跃点 30
#   tracert 显示公网第一跳是 192.168.8.1 —— 走的是另一台路由器。
# 判据本身是可靠的（用 conntrack 的 [OFFLOAD] 标记，且绑定源地址强制走 Wi-Fi），
# 但换到正确路径后结论**完全相反**，三档实测：
#
#   档位        flow_offloading(_hw)   flowtable devices                      OFFLOAD 标记   大流量传输
#   A 关        0 / 0                  ——                                     0              ——（基线）
#   B 软件开    1 / 0                  { br-lan, eth1, eth2 }                  42             44.15 MB / 39s 全成功
#   C 硬件也开  1 / 1                  { eth0, eth1, eth2, phy0.1-ap0 }        42             44.15 MB / 39s 全成功
#
#   ⇒ 软件卸载**确实生效**（conntrack 条目带 [OFFLOAD]）且**不断网**。
#   ⇒ 三条长连接全程正常收发，无丢包、无超时。
#
# ⇒ 结论：TTL 归一规则在卸载下失效（这是内核机制，见下）是事实，但
#   **「失效 = 断网」是误判**。flowtable 快转路径会自行递减 TTL
#   （内核文档：TTL is decremented before calling neigh_xmit()），
#   包依然正常发出去，不会因为没走我们的 ttl set 128 就被丢弃。
#   以「性能、稳定性优先」为准，TTL 规则的失效可接受 → 默认开。

set -u

MODE="${WRT_FLOW_OFFLOAD:-on}"
# 大小写不敏感：归一化为小写再校验
MODE="$(printf '%s' "$MODE" | tr '[:upper:]' '[:lower:]')"

case "$MODE" in
	auto|off|on|on-hw) ;;
	*)
		echo "::error::非法 WRT_FLOW_OFFLOAD='$MODE'（仅允许 auto/off/on/on-hw），终止 CI"
		exit 1
		;;
esac

# 目标目录：wrt/files/etc/mt5700（与 INSTALL_NET_TUNING 的覆盖层路径一致）
WRT_FILES="${GITHUB_WORKSPACE:-$(pwd)}/wrt/files"
DST_DIR="$WRT_FILES/etc/mt5700"

if [ ! -d "$WRT_FILES" ]; then
	echo "::error::目标目录 $WRT_FILES 不存在（Custom Packages 阶段应已建好 wrt/ 软链），无法写入 flow-offload"
	exit 2
fi

mkdir -p "$DST_DIR" || { echo "::error::无法创建目录 $DST_DIR"; exit 2; }

printf 'MODE=%s\n' "$MODE" > "$DST_DIR/flow-offload" || {
	echo "::error::写入 $DST_DIR/flow-offload 失败"
	exit 2
}

echo "flow-offload: 已写入 MODE=$MODE → $DST_DIR/flow-offload"
exit 0
