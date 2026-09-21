#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# find 无结果时 sed 会退化成「从 stdin 读」，命令照样返回 0 ——
# 于是「该改的没改」被静默吞掉：表现为固件主题不对、登录 IP 不对、状态页没有编译日期，
# 而 CI 全程全绿，等刷完机才发现。这里统一走包装函数，找不到文件直接失败。
# 用法：EDIT_FILES "<sed 表达式>" <find 的查找路径与条件...>
EDIT_FILES() {
	local PATTERN="$1"; shift
	local FILES
	FILES="$(find "$@" -type f 2>/dev/null)"
	if [ -z "$FILES" ]; then
		echo "::error::Settings.sh: 未找到待修改文件（find $@）—— feeds 结构变了还是路径写错了？"
		exit 1
	fi
	printf '%s\n' "$FILES" | while IFS= read -r F; do
		sed -i "$PATTERN" "$F"
	done
}

#移除luci-app-attendedsysupgrade
EDIT_FILES "/attendedsysupgrade/d" ./feeds/luci/collections/ -name "Makefile"
#修改默认主题
EDIT_FILES "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" ./feeds/luci/collections/ -name "Makefile"
#修改immortalwrt.lan关联IP
EDIT_FILES "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" ./feeds/luci/modules/luci-mod-system/ -name "flash.js"
#添加编译日期标识
EDIT_FILES "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" ./feeds/luci/modules/luci-mod-status/ -name "10_system.js"

WIFI_SH=$(find ./target/linux/mediatek/filogic/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
# ⚠️ 判据用 [ -n ] 而不是 [ -f ]：find 可能返回**多个**路径（上游同时存在
#    zz-set-wireless.sh 与 set-wireless.sh 之类），而 [ -f "a\nb" ] 恒为假 ——
#    于是会静默掉到 elif（甚至两个分支都不进），整个 wifi 配置无声不生效。
#    下面的 sed 本来就支持多文件（`sed -i ... $WIFI_SH` 会把路径按空白拆开）。
if [ -n "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
	#修改加密方式为 WPA-PSK/WPA2-PSK Mixed Mode
	sed -i "s/encryption='.*'/encryption='psk-mixed'/g" $WIFI_SH
	#设置国家码为 CN
	sed -i "s/country='.*'/country='CN'/g" $WIFI_SH
	#修改2.4G默认频宽为 40MHz
	sed -i "s/htmode='HT20'/htmode='HT40'/g" $WIFI_SH
	#5G 默认频宽：EHT160（Wi-Fi 7）。2026-09-21 由 HE80 改为 EHT160。
	#   依据：① 本机网卡 MT7992E 是 802.11be —— `iw phy phy0 info` 明确列出
	#         "EHT Iftypes: AP" 与 "EHT-MCS Map (BW = 160)"；
	#         ② 厂家基准（Mwrt）默认就是 channel 36 + EHT160；
	#         ③ 频谱占用与 HE160 完全相同（36-64 的 160MHz 块），不新增 DFS 风险。
	#   真机实测：改为 EHT160 后 wifi reload 仅 5 秒 AP 即恢复、未触发 DFS 阻塞；
	#             Wi-Fi 6 客户端仍按 160MHz HE-MCS 11 HE-NSS 2 协商（向下兼容无损）。
	#   ⚠️ 不要退回「149 信道 + 160MHz」：CN 域 (5725-5850 @ 80) 只批 80MHz，
	#      那样配 hostapd 会报 "Frequency 5845 is not allowed (seg0)" →
	#      "Could not select hw_mode and channel. (-3)"，AP 直接起不来。
	#      仅当所处环境雷达检测导致 36-64 的 160MHz 起不来时，才退回 HE80。
	sed -i "s/htmode='VHT80'/htmode='EHT160'/g" $WIFI_SH
	# 上游若改了默认频宽，上面的 sed 会零匹配却仍返回 0（GNU sed 的特性）→ 静默失效。
	# 这里补一条可见性检查，让它至少吵一声。
	grep -q "htmode='EHT160'" $WIFI_SH || echo "::warning::Settings: $WIFI_SH 中未匹配到 htmode='VHT80' 锚点，5G 频宽未被改写（上游可能改了默认值）"
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改加密方式为 WPA-PSK/WPA2-PSK Mixed Mode
	sed -i "s/encryption = 'none'/encryption = 'psk-mixed'/g" $WIFI_UC
	#设置国家码为 CN（6G 分支）
	sed -i "s/country = '00'/country = 'CN'/g" $WIFI_UC
	#在 else 分支添加 country = 'CN'
	sed -i "s/} else {/} else {\\n\\t\\tcountry = 'CN';/" $WIFI_UC
	#修改2.4G默认频宽为 40MHz
	sed -i 's/width = 20;/width = 40;/g' $WIFI_UC
	#5G 保持 80MHz 上限（原因同上：CN 5.8G 限 80MHz；5.2G 的 160MHz 必然跨 DFS）
	#sed -i 's/width > 80)/width > 160)/g' $WIFI_UC
	#sed -i 's/width = 80;/width = 160;/g' $WIFI_UC
else
	# ★ 两个候选都不存在 = 本次固件的 SSID / 密码 / 加密方式 / 国家码 / 频宽
	#   **全部沿用上游默认**，而且不会有任何报错 —— 这正是本文件开头 EDIT_FILES
	#   注释里写的那类静默失效（"该改的没改，CI 全绿，刷完才发现"）。
	#   默认 SSID/密码属于刷完第一眼就能看出、但排查时最容易怀疑到别处的东西
	#   （会先怀疑无线驱动、hostapd、国家码），故与 EDIT_FILES 的约定保持一致：直接终止。
	echo "::error::Settings.sh: 未找到任何可改写 wifi 默认值的文件（WIFI_SH='$WIFI_SH' 为空且 $WIFI_UC 不存在）—— SSID/密码/国家码/频宽会全部沿用上游默认。上游大概调整了 wifi-scripts 的目录结构，请更新本脚本。"
	exit 1
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
# ★ 下面 4 条是本文件里唯一**没有任何守卫**的 sed（其余都走 EDIT_FILES 包装）。
#   风险两层，且都以"静默"收场：
#     ① 文件不存在 → sed 报错，但本脚本没有 set -e，脚本退出码仍为 0 → CI 全绿；
#     ② 文件在、锚点变了（上游改模板）→ GNU sed 零匹配仍返回 0 → 同样全绿。
#   后果是"刷完默认 IP 不是 $WRT_IP"—— 对这台机器尤其致命：整套 LuCI / SSH / 部署脚本
#   都按 $WRT_IP 连，排查时几乎不会怀疑到编译脚本这一步。
#   处理按本仓既有约定分级：文件缺失 = 硬失败；锚点不匹配 = 醒目告警（与 Handles.sh
#   里 htmode 锚点检查同一处理方式）。
[ -f "$CFG_FILE" ] || { echo "::error::Settings.sh: 未找到 $CFG_FILE —— 默认 IP / 主机名 / 时区都无法写入"; exit 1; }

#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
#修改默认时区
sed -i "s/timezone='.*'/timezone='CST-8'/g" $CFG_FILE
sed -i "s/zonename='.*'/zonename='Asia\/Shanghai'/g" $CFG_FILE

# 回读校验：判据是"内容真的变了"，不是"sed 没报错"。
# 本条已真机确认过锚点有效（固件内 /bin/config_generate 实测含
#   set system.@system[-1].hostname='OWRT' / timezone='CST-8' / zonename='Asia/Shanghai'
#   与 lan) ipad=${ipaddr:-"192.168.10.1"}），所以这里的告警是防上游改版，不是已知故障。
grep -q "hostname='$WRT_NAME'" "$CFG_FILE" \
	|| echo "::warning::Settings: $CFG_FILE 中主机名未写成 '$WRT_NAME'（上游模板变了？）"
grep -q "zonename='Asia/Shanghai'" "$CFG_FILE" \
	|| echo "::warning::Settings: $CFG_FILE 中时区未写成 Asia/Shanghai（上游模板变了？）"
grep -q "$WRT_IP" "$CFG_FILE" \
	|| echo "::warning::Settings: $CFG_FILE 中默认 IP 未写成 $WRT_IP（上游模板变了？）"

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi
