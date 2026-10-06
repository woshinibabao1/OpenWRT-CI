#!/bin/bash
# SPDX-License-Identifier: MIT
# 把本仓 Patches/ 下的内核补丁注入 openwrt 源码树。
#
# ★ 为什么需要这个脚本：本仓是「配置定制仓」，只往 .config 追加选项，
#   历史上**从未有过任何打补丁的动作**（CI 的 Custom Settings 阶段只做
#   cat >> .config）。所以补丁光放进仓库不会生效——补丁目录是空的，
#   OpenWrt 只会用它自己的 target/linux/mediatek/patches-* 里的补丁。
#   本脚本把补丁复制进去，让它进入内核构建的补丁队列。
#
# ★ 必须放在 make defconfig **之后**、make 编译之前：
#   - 之前不行：target/linux/mediatek 的 Makefile 与补丁目录在 kernel
#     包的 prepare 阶段才被展开，过早复制会被 prepare 清掉。
#   - 之后：目录已存在，直接拷入即可被后续 prepare 拾取。
#
# 用法（在 openwrt 源码树根目录执行）：bash ApplyPatches.sh
# 开关：WRT_PATCHES=off 可整体跳过（出问题时第一时间能关掉）。

set -e

[ "${WRT_PATCHES:-on}" = "off" ] && { echo "WRT_PATCHES=off：跳过内核补丁注入"; exit 0; }

SRC_DIR="$GITHUB_WORKSPACE/Patches"

# 与 Settings.sh 的 EDIT_FILES 同一条纪律：找不到补丁目录就直接失败。
# 静默跳过 = CI 全绿但固件里没有补丁，等刷完机才发现加速没生效——
# 这正是本脚本存在的反面教材。
if [ ! -d "$SRC_DIR" ]; then
	echo "::error::未找到补丁目录 $SRC_DIR（本仓应有 Patches/）"
	exit 1
fi

# 目标补丁目录：优先 -6.18（当前内核 6.18.54），否则退回不带版本号的那个。
# ★ 不写死单一路径：内核版本一升，patches-6.18 就会改名，
#   写死的话升级内核那天补丁会静默不生效。
PATCH_DIR=""
for CAND in "./target/linux/mediatek/patches-6.18" \
            "./target/linux/mediatek/patches"; do
	if [ -d "$CAND" ]; then
		PATCH_DIR="$CAND"
		break
	fi
done

if [ -z "$PATCH_DIR" ]; then
	echo "::error::在 target/linux/mediatek/ 下找不到任何 patches 目录（内核结构变了？）"
	exit 1
fi

echo "补丁注入目标目录：$PATCH_DIR"

COUNT=0
for P in "$SRC_DIR"/*.patch; do
	[ -e "$P" ] || continue
	BASE="$(basename "$P")"

	# ★ 行尾必须是 LF。CRLF 的补丁在 OpenWrt 的 patch 阶段可能匹配失败，
	#   而失败信息往往出现在很后面、很难联想到行尾问题。仓库 .gitattributes
	#   已对 Patches/** 声明 text eol=lf，这里再兜一层底。
	if grep -qU $'\r' "$P"; then
		echo "::error::补丁 $BASE 含 CRLF 行尾，无法用于内核补丁队列"
		exit 1
	fi

	# 幂等：重复构建（CI 重试）时同名文件已存在，先清掉再拷，
	# 否则第二次会因为 -p1 重复应用失败。
	rm -f "$PATCH_DIR/$BASE"
	cp "$P" "$PATCH_DIR/$BASE"
	echo "  已注入：$BASE"
	COUNT=$((COUNT + 1))
done

[ "$COUNT" -gt 0 ] || { echo "::error::$SRC_DIR 下没有任何 .patch 文件"; exit 1; }

echo "共注入 $COUNT 个补丁"
