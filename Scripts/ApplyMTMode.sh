#!/bin/bash
# SPDX-License-Identifier: MIT
# MT 模式配置层应用脚本（由 WRT-CORE 在 Custom Settings 阶段调用）
#
# 职责：
#   1. 校验 MT_MODE 合法性（仅允许 空 / MT5700；MT5700M 明确拒绝）
#   2. 按模式向 .config 叠加独立插件配置层
#   3. 在配置生成前主动写入互斥包的 =n，防止 make defconfig 被间接依赖拉回
#
# 使用方式（在 OpenWrt 源码根目录执行，且机型配置 + GENERAL 已写入 .config 之后）：
#   MT_MODE=MT5700 $GITHUB_WORKSPACE/Scripts/ApplyMTMode.sh
#
# MT_MODE 含义：
#   ""        —— 不安装任何 MT 插件（原有普通 CI 行为）
#   MT5700    —— 仅 luci-app-mt5700（方案 B，单包自含 Rust 后端）
#   MT5700M   —— ⛔ 已停用：luci-app-mt5700m 方案 A，依赖 QModem 的
#                sms-tool_q / ubus-at-daemon，而 sms-tool_q 的版本号
#                （3.4.0-rc.3）对 apk 非法会导致 world 打包失败，且功能与
#                方案 B 重复。这里**明确拒绝并终止**，属有意为之的守卫：
#                绝不静默编出一套没人验证过的半残固件。
#   其他值    —— 直接 ::error:: 并 exit 1

set -euo pipefail

MODE="${MT_MODE:-}"
CFG_GITHUB="${GITHUB_WORKSPACE:-}"
if [ -n "$CFG_GITHUB" ]; then
	CFG_DIR="$CFG_GITHUB/Config"
else
	CFG_DIR="$(cd "$(dirname "$0")/../Config" && pwd)"
fi

echo "::group::检测 MT 模式"

case "$MODE" in
	"" )
		echo "::notice::MT_MODE 为空：不安装任何 MT5700 / MT5700M 相关插件"
		;;
	MT5700 )
		echo "::notice::MT_MODE=MT5700：仅安装 luci-app-mt5700（方案 B）"
		;;
	MT5700M )
		echo "::error::MT_MODE=MT5700M 已停用：该方案（luci-app-mt5700m + QModem 的 sms-tool_q / ubus-at-daemon）自 2026-09-15 起不再出固件，原因是 sms-tool_q 版本号（3.4.0-rc.3）对 apk 非法会让 world 打包失败，且功能与 MT5700（单包自含）完全重复。请改用 MT_MODE=MT5700，或显式留空不装任何 MT 插件。"
		exit 1
		;;
	* )
		echo "::error::非法 MT_MODE='$MODE'（仅允许空 / MT5700），终止 CI"
		exit 1
		;;
esac

# 必须在 OpenWrt 源码根目录（存在 .config 或即将生成）
if [ ! -f ./.config ] && [ ! -f ./Makefile ]; then
	echo "::error::ApplyMTMode.sh 必须在 OpenWrt 源码根目录执行"
	exit 1
fi

# 写入互斥保护：无论本模式是否启用，都先把对侧包显式置 n
# 这样即使机型配置/PRIVATE/WRT_PACKAGE 意外写入对侧包，也会被覆盖为禁用。
write_disable() {
	local pkg
	for pkg in "$@"; do
		echo "CONFIG_PACKAGE_${pkg}=n" >> ./.config
		echo "  禁用 ${pkg}"
	done
}

case "$MODE" in
	MT5700 )
		echo "叠加配置层：Config/MT5700.txt"
		[ -f "$CFG_DIR/MT5700.txt" ] || { echo "::error::缺少 $CFG_DIR/MT5700.txt"; exit 1; }
		cat "$CFG_DIR/MT5700.txt" >> ./.config
		echo "互斥保护：强制禁用 MT5700M 侧包"
		write_disable luci-app-mt5700m luci-i18n-mt5700m-zh-cn sms-tool_q ubus-at-daemon
		;;
	"" )
		echo "空模式：显式禁用全部 MT 相关包（防止被其他配置层拉入）"
		write_disable \
			luci-app-mt5700 luci-i18n-mt5700-zh-cn \
			luci-app-mt5700m luci-i18n-mt5700m-zh-cn \
			sms-tool_q ubus-at-daemon
		;;
esac

echo "::endgroup::"
