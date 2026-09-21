#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE/wrt/package" ]; then
	PKG_PATH="$GITHUB_WORKSPACE/wrt/package"
else
	PKG_PATH="$(pwd)"
fi

#修改argon主题字体和颜色
ARGON_CFG="$PKG_PATH/luci-theme-argon/luci-app-argon-config/root/etc/config/argon"
if [ -d "$PKG_PATH/luci-theme-argon" ]; then
	echo " "
	# ★ GNU sed 零匹配也返回 0，故必须先 grep 锚点再动手 ——
	#   否则 `if sed -i ...; then echo fixed` 会把假成功报成已修复，
	#   上游一改模板就静默失效（表现只是"主题颜色没生效"，很难联想到这步）。
	if [ ! -f "$ARGON_CFG" ]; then
		echo "::warning::theme-argon: 未找到 $ARGON_CFG（上游可能调了目录结构），配色未修正"
	elif grep -q "primary '" "$ARGON_CFG"; then
		sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" "$ARGON_CFG"
		echo "theme-argon has been fixed!"
	else
		echo "::warning::theme-argon: 未匹配锚点 \"primary '\"，配色未修正（上游可能已改模板）"
	fi
fi

#修改mini-diskmanager菜单位置
DISKMAN_MENU="$PKG_PATH/luci-app-mini-diskmanager/luci-app-mini-diskmanager/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json"
if [ -d "$PKG_PATH/luci-app-mini-diskmanager" ]; then
	echo " "
	if [ ! -f "$DISKMAN_MENU" ]; then
		echo "::warning::mini-diskmanager: 未找到 $DISKMAN_MENU，菜单位置未调整"
	elif grep -q 'services' "$DISKMAN_MENU"; then
		sed -i "s/services/system/g" "$DISKMAN_MENU"
		echo "mini-diskmanager has been fixed!"
	else
		echo "::warning::mini-diskmanager: 菜单里已无 \"services\"，无需调整（上游可能已改到 system）"
	fi
fi

#修复TailScale配置文件冲突
FEEDS_PACKAGES="$PKG_PATH/../feeds/packages"
TS_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/tailscale/Makefile' -print -quit 2>/dev/null)"
if [ -f "$TS_FILE" ]; then
	echo " "

	if grep -q '/files' "$TS_FILE"; then
		sed -i '/\/files/d' "$TS_FILE"
		echo "tailscale has been fixed!"
	else
		# 零匹配不是错误：上游若本来就不再引用 /files，这里无事可做。原先的写法会把
		# 这种情况报成 "fixed!"（sed 零匹配返回 0），反而掩盖"确实改了"与"没改"的区别。
		echo "tailscale: Makefile 里已无 /files 引用，无需修复"
	fi
fi

#修复Rust编译失败
RUST_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/rust/Makefile' -print -quit 2>/dev/null)"
if [ -f "$RUST_FILE" ]; then
	echo " "

	if grep -q 'ci-llvm=true' "$RUST_FILE"; then
		sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE"
		echo "rust has been fixed!"
	else
		# 这条失效会让 rust 编译直接失败（构建当场变红），不会拖到真机才发现，故中性提示即可。
		echo "rust: ci-llvm 已为 false 或上游改了写法，无需修复"
	fi
fi

#修复 honk 包安装阶段 /var 目录冲突
# ★ [当前不会生效] honk 插件已停用：Packages.sh 里 INSTALL_HONK_PREBUILT 被注释，
#   Config/GENERAL.txt 里 honk 相关符号也全是注释态，package/ 下不会出现 honk，
#   故下面这段 `[ -f "$HONK_FILE" ]` 目前恒为假。它是「随 INSTALL_HONK_PREBUILT
#   一起启用」的配套修补 —— 将来重新启用 honk 时，这段会随之自动生效，别删。
# 根因：honk 的 Package/honk/install 中执行 $(INSTALL_DIR) $(1)/var/share/honk，
# 会在 pkgdir 下创建 var/ 目录；但 OpenWrt rootfs 中 /var 是指向 /tmp 的符号链接，
# 构建系统复制 pkgdir 到 rootfs 时 cp 无法用目录覆盖符号链接，报错：
#   cp: cannot overwrite non-directory '.../root-mediatek/./var' with directory '.../.pkgdir/honk/./var'
# 修复方式：移除 install 中的 /var/share/honk 创建与 chmod；运行时数据目录由
# honk.init 的 prepare_subscription_store() 在启动时自动 mkdir -p 创建。
HONK_FILE="$(find "$PKG_PATH" -maxdepth 2 -type f -wholename '*/honk/Makefile' -print -quit 2>/dev/null)"
if [ -f "$HONK_FILE" ]; then
	echo " "

	if grep -q 'var/share/honk' "$HONK_FILE"; then
		sed -i '/chmod 0700 \$(1)\/var\/share\/honk/d; s# \$(1)/var/share/honk##g' "$HONK_FILE"
		echo "honk /var directory conflict has been fixed!"
	else
		echo "honk: Makefile 里已无 var/share/honk 引用，无需修复"
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
	elif ! grep -qP '^\t*if flock -x 200; then' "$PMC_FILE"; then
		# ★ 必须显式区分「锚点不存在」与「sed 执行失败」：GNU sed 即使零匹配也返回 0，
		#   而 `if sed -i ...; then` 会把零匹配的假成功报成 "has been fixed!"。
		#   锚点一旦随上游改版消失，修补就不会写入，CI 仍全绿，直到真机上安装自编译 apk
		#   才报 untrusted（错误信息只有一句 untrusted，极难定位到是这一步没生效）。
		#   这里不 exit 1：该修补只影响「LuCI 里手动装包」这一次要能力，为它中断几小时的
		#   构建不划算；但必须留下可见的警告。
		echo "::warning::package-manager: 未找到锚点 'if flock -x 200; then'，--allow-untrusted 未注入；LuCI 软件页将装不上自编译 apk。请检查上游 $PMC_FILE"
	else
		sed -i 's|^\t*if flock -x 200; then|\t\t\t# install 默认允许未签名包（自编译 apk 无签名，否则装不上）\n\t\t\tif [ "$action" = "add" ] \&\& [ "$ipkg_bin" = "apk" ]; then\n\t\t\t\tcmd="$cmd --allow-untrusted"\n\t\t\tfi\n\t\t\tif flock -x 200; then|' "$PMC_FILE"
		echo "package-manager: install now defaults to --allow-untrusted!"
	fi
fi

