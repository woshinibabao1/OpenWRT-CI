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
if [ -f "$WIFI_SH" ]; then
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
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
#修改默认时区
sed -i "s/timezone='.*'/timezone='CST-8'/g" $CFG_FILE
sed -i "s/zonename='.*'/zonename='Asia\/Shanghai'/g" $CFG_FILE

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
