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
# 默认 off（不是 auto）：固件自带 WAN 侧 TTL 统一规则（/etc/nftables.d/12-mangle-ttl-128.nft），
# 而 flow offload 会把连接从 nftables 路径上摘走 → TTL 规则对快转包完全不执行。
# 真机实证（2026-09-21，H5000M / kernel 6.18.52）：offload 开着时客户端 HTTP 25 秒超时、
# conntrack 里连接带 [OFFLOAD] 标记、正向 10 包只回收 1 包（仅 SYN-ACK）；
# 关掉后同一请求 HTTP 200 / 1.0 秒。故默认必须是 off。
# 想要卸载加速请显式选 on / on-hw，代价是 TTL 统一失效。

set -u

MODE="${WRT_FLOW_OFFLOAD:-off}"
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
