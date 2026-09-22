#!/bin/bash
# SPDX-License-Identifier: MIT
# MT 模式最终 .config 互斥验证（由 WRT-CORE 在 make defconfig 之后调用）
#
# 检查点：
#   - MT5700：必须存在 luci-app-mt5700；必须不存在 mt5700m / sms-tool_q / ubus-at-daemon
#   - MT5700M：⛔ 已停用（方案 A 的 QModem 依赖对 apk 非法且功能重复）——
#              这里保留分支作守卫：一旦出现就直接报错终止，而不是让它编下去
#   - 空模式：上述四类包全部不得被选中
#
# 在 OpenWrt 源码根目录执行。发现违规时 ::error:: 并 exit 1。

set -euo pipefail

MODE="${MT_MODE:-}"
DOT_CONFIG="./.config"

echo "::group::验证 MT 模式包选择"

if [ ! -f "$DOT_CONFIG" ]; then
	echo "::error::未找到 $DOT_CONFIG，请先执行 make defconfig"
	exit 1
fi

# 从最终 .config 读取包是否被选中（y 或 m 均视为选中）
pkg_selected() {
	local pkg="$1"
	grep -qE "^CONFIG_PACKAGE_${pkg}=[ym]" "$DOT_CONFIG"
}

# 2026-09-23 移除 pkg_disabled()：全仓 grep 确认零调用点，且它与 pkg_selected()
# 只是返回值相反（真值表互补），留着等于同一件事两个家 —— 将来只会有人改一个忘另一个。
# 需要反向判定时写 `! pkg_selected "$pkg"` 即可，不必再维护一份。

report_pkg() {
	local pkg="$1"
	if pkg_selected "$pkg"; then
		echo "  [选中] $pkg"
	else
		echo "  [未选中] $pkg"
	fi
}

echo "::notice::MT_MODE=${MODE:-（空）}"
echo "最终 .config 包状态："
for p in luci-app-mt5700 luci-app-mt5700m sms-tool_q ubus-at-daemon; do
	report_pkg "$p"
done

FAIL=0

check_must() {
	local pkg="$1"
	if ! pkg_selected "$pkg"; then
		echo "::error::MT_MODE=${MODE} 要求必须选中 ${pkg}，但最终 .config 中未选中"
		FAIL=1
	fi
}

check_must_not() {
	local pkg="$1"
	if pkg_selected "$pkg"; then
		echo "::error::MT_MODE=${MODE} 要求不得选中 ${pkg}，但最终 .config 中被选中（配置污染）"
		FAIL=1
	fi
}

case "$MODE" in
	MT5700 )
		check_must luci-app-mt5700
		check_must_not luci-app-mt5700m
		check_must_not sms-tool_q
		check_must_not ubus-at-daemon
		# 注：原先这里还有一段 `grep -qE '^CONFIG_PACKAGE_luci-app-mt5700m=[ym]'` 的
		# 「反向依赖探测」，但它与上一行 check_must_not 的判据**完全相同**
		# （pkg_selected 用的就是 =[ym]），属纯重复；且它只 echo ::error:: 却不置 FAIL=1 ——
		# 一旦有人删掉 check_must_not，这里就成了「只喊不拦」。已删除，拦截统一走 check_must_not。
		;;
	MT5700M )
		# 守卫（不是「校验通过」路径）：这个模式已停用，配好的 .config 只可能是
		# 绕过了 ApplyMTMode.sh 拼出来的（例如手工改 workflow、直接手改 .config）。
		# 这里明确拦下 —— 让它编完等于产出一套没人验证过的固件。
		echo "::error::MT_MODE=MT5700M 已停用（方案 A：luci-app-mt5700m + QModem 的 sms-tool_q / ubus-at-daemon）。请改用 MT5700，或清空 MT_MODE。"
		FAIL=1
		;;
	"" )
		check_must_not luci-app-mt5700
		check_must_not luci-app-mt5700m
		check_must_not sms-tool_q
		check_must_not ubus-at-daemon
		;;
	* )
		echo "::error::非法 MT_MODE='$MODE'（仅允许空 / MT5700；MT5700M 已停用）"
		FAIL=1
		;;
esac

if [ "$FAIL" -ne 0 ]; then
	echo "::error::MT 模式互斥验证失败，已中止编译"
	echo "::endgroup::"
	exit 1
fi

echo "::notice::MT 模式互斥验证通过"
echo "::endgroup::"
