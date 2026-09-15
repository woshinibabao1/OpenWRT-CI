#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

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
	#5G 固定 80MHz（HE80），不再拉到 160MHz。原因（真机实测）：
	#   1) CN 监管域 (5725 - 5850 @ 80)，5.8G（149~165）只批 80MHz；配 160MHz 时
	#      hostapd 报 "Frequency 5845 is not allowed (seg0)" →
	#      "Could not select hw_mode and channel. (-3)"，AP 直接起不来；
	#   2) 5.2G 唯一的 160MHz 块（36~64）跨 DFS 区，开机要先做 1~10 分钟雷达静默检测；
	#   3) 城中村高密度环境 160MHz 干扰重，80MHz 实际更稳、协商速率几乎无损。
	sed -i "s/htmode='VHT80'/htmode='HE80'/g" $WIFI_SH
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
