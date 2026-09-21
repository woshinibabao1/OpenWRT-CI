#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# 双重断言 sing-box 不被编入固件（对照 Scripts/VerifyMTMode.sh 的「配置前/后」双校验范式）：
#   PHASE=pre  —— 编译前：检查 ./.config 是否意外选中 sing-box / homeproxy
#   PHASE=post —— 编译后：检查 ./bin/targets/*/*.manifest 是否含 sing-box / homeproxy
#
# 退出码：
#   0 = 通过（未选中 / 未出现）
#   1 = 违规（pre 阶段 .config 选中了；post 阶段 manifest 含）
#   2 = 未知 PHASE（未传或非法）
#
# 设计要点（对应 Proposer P05）：
#   - 真值防护：现有配方已不再 =y 选中 sing-box，但避免「将来某包 DEPENDS 反向拉回」。
#     这里把「显式 =n（Config/GENERAL.txt）+ 编译前后两道断言」作为纵深防线。
#   - =n 或未出现均放行：只有 =y/=m 才算违规（kconfig 把 =m 也视为编入）。
#   - 反向依赖探测（pre 阶段只报告不失败）：打印 DEPENDS 了 sing-box 的包名，
#     供人工判读是否需一并置 =n，避免误杀合法包。
#
# 环境变量：
#   PHASE  pre | post

set -u

PHASE="${PHASE:-}"

case "$PHASE" in
	pre|post) ;;
	*)
		echo "::error::未指定 PHASE（需 pre 或 post），当前='$PHASE'"
		exit 2
		;;
esac

if [ "$PHASE" = "pre" ]; then
	# .config 里若显式 =y/=m 选中即违规；=n 或未出现均放行
	if grep -E '^CONFIG_PACKAGE_(sing-box|luci-app-homeproxy|luci-i18n-homeproxy-zh-cn)=[ym]' ./.config 2>/dev/null; then
		echo "::error::发现 sing-box / homeproxy 被选中（见上），终止 CI"
		exit 1
	fi
	echo "VerifyNoSingBox(pre): .config 未选中 sing-box / homeproxy，通过"

	# 反向依赖探测（仅报告不失败，避免误杀合法包）：
	# 打印 DEPENDS 了 sing-box 的包名，供人工判读是否需一并置 =n
	echo "VerifyNoSingBox(pre): 反向依赖探测（仅报告）"
	grep -rlsE '(^|[+ :])sing-box' --include=Makefile ./package ./feeds 2>/dev/null \
		| sed 's#/Makefile$##; s#.*/##' | sort -u || true
	exit 0
fi

# PHASE=post：编译后查 manifest
VIOLATION=0
while IFS= read -r MF; do
	HIT="$(grep -Hw -e sing-box -e luci-app-homeproxy "$MF" 2>/dev/null)"
	if [ -n "$HIT" ]; then
		echo "::error::manifest 含 sing-box / homeproxy：$HIT"
		VIOLATION=1
	fi
done < <(find ./bin/targets -name '*.manifest' -type f 2>/dev/null)

if [ "$VIOLATION" -ne 0 ]; then
	echo "::error::产物 manifest 含 sing-box / homeproxy，终止 CI"
	exit 1
fi

echo "VerifyNoSingBox(post): 产物 manifest 未含 sing-box / homeproxy，通过"
exit 0
