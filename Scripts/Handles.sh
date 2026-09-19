#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE/wrt/package" ]; then
	PKG_PATH="$GITHUB_WORKSPACE/wrt/package"
else
	PKG_PATH="$(pwd)"
fi

#修改argon主题字体和颜色
if [ -d "$PKG_PATH/luci-theme-argon" ]; then
	echo " "
	if sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" \
		"$PKG_PATH/luci-theme-argon/luci-app-argon-config/root/etc/config/argon"; then
		echo "theme-argon has been fixed!"
	else
		echo "theme-argon fix failed; continuing!"
	fi
fi

#修改mini-diskmanager菜单位置
if [ -d "$PKG_PATH/luci-app-mini-diskmanager" ]; then
	echo " "
	if sed -i "s/services/system/g" \
		"$PKG_PATH/luci-app-mini-diskmanager/luci-app-mini-diskmanager/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json"; then
		echo "mini-diskmanager has been fixed!"
	else
		echo "mini-diskmanager fix failed; continuing!"
	fi
fi

#修复TailScale配置文件冲突
FEEDS_PACKAGES="$PKG_PATH/../feeds/packages"
TS_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/tailscale/Makefile' -print -quit 2>/dev/null)"
if [ -f "$TS_FILE" ]; then
	echo " "

	if sed -i '/\/files/d' "$TS_FILE"; then
		echo "tailscale has been fixed!"
	else
		echo "tailscale fix failed; continuing!"
	fi
fi

#修复Rust编译失败
RUST_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/rust/Makefile' -print -quit 2>/dev/null)"
if [ -f "$RUST_FILE" ]; then
	echo " "

	if sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE"; then
		echo "rust has been fixed!"
	else
		echo "rust fix failed; continuing!"
	fi
fi

#修复 honk 包安装阶段 /var 目录冲突
# 根因：honk 的 Package/honk/install 中执行 $(INSTALL_DIR) $(1)/var/share/honk，
# 会在 pkgdir 下创建 var/ 目录；但 OpenWrt rootfs 中 /var 是指向 /tmp 的符号链接，
# 构建系统复制 pkgdir 到 rootfs 时 cp 无法用目录覆盖符号链接，报错：
#   cp: cannot overwrite non-directory '.../root-mediatek/./var' with directory '.../.pkgdir/honk/./var'
# 修复方式：移除 install 中的 /var/share/honk 创建与 chmod；运行时数据目录由
# honk.init 的 prepare_subscription_store() 在启动时自动 mkdir -p 创建。
HONK_FILE="$(find "$PKG_PATH" -maxdepth 2 -type f -wholename '*/honk/Makefile' -print -quit 2>/dev/null)"
if [ -f "$HONK_FILE" ]; then
	echo " "

	if sed -i '/chmod 0700 \$(1)\/var\/share\/honk/d; s# \$(1)/var/share/honk##g' "$HONK_FILE"; then
		echo "honk /var directory conflict has been fixed!"
	else
		echo "honk fix failed; continuing!"
	fi
fi

#安装默认允许未签名包（--allow-untrusted）
# 自编译出来的 apk（本机 CI 打的 luci-app-*、第三方包等）不带仓库签名，
# apk 默认会因签名校验失败拒绝安装，LuCI「系统 → 软件」页表现为安装失败、
# 错误信息里只有一句 untrusted。
#
# ★ 必须改后端 package-manager-call，改前端 package-manager.js 没用：
#   脚本解析参数时 `-*)` 分支会把未知选项直接 shift 丢弃（apk 分支只认
#   --force-removal-of-dependent-packages 与 --force-overwrite），前端传什么都进不来。
#
# ★ 追加到 cmd 而不是 $@：最终拼成 "apk --allow-untrusted add <pkg>" ——
#   --allow-untrusted 是 apk 的全局选项，放在子命令之前才一定生效。
#
# ★ 只对 apk 的 add（= 用户点的 install）生效：
#   opkg 默认不校验包签名，加了反而可能不被识别；update / upgrade / remove 保持原样。
PMC_FILE="$(find "$PKG_PATH/../feeds/luci" "$PKG_PATH/feeds/luci" -type f \
	-path '*/luci-app-package-manager/root/usr/libexec/package-manager-call' -print -quit 2>/dev/null)"
if [ -f "$PMC_FILE" ]; then
	echo " "

	if grep -q 'allow-untrusted' "$PMC_FILE"; then
		echo "package-manager: untrusted already allowed; skipping!"
	elif sed -i 's|^\t*if flock -x 200; then|\t\t\t# install 默认允许未签名包（自编译 apk 无签名，否则装不上）\n\t\t\tif [ "$action" = "add" ] \&\& [ "$ipkg_bin" = "apk" ]; then\n\t\t\t\tcmd="$cmd --allow-untrusted"\n\t\t\tfi\n\t\t\tif flock -x 200; then|' "$PMC_FILE"; then
		echo "package-manager: install now defaults to --allow-untrusted!"
	else
		echo "package-manager fix failed; continuing!"
	fi
fi

