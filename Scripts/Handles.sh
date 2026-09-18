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

