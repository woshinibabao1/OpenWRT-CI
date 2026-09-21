#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)  # 第5个参数为自定义名称列表
	local REPO_NAME=${PKG_REPO#*/}

	echo " "

	# 删除本地可能存在的不同名称的软件包
	for NAME in "${PKG_LIST[@]}"; do
		# 查找匹配的目录
		echo "Search directory: $NAME"
		local FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)

		# 删除找到的目录
		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not found directory: $NAME"
		fi
	done

	# 克隆 GitHub 仓库
	# P07：克隆失败（分支改名 / 仓库私有 / 限流）必须立即终止，
	# 否则会静默缺包，最终表现为「插件莫名没了」而不是构建失败。
	# 但「失败」要区分偶发与必然：GitHub 对 CI 出口 IP 的限流（403 / early EOF）
	# 是偶发的，一次失败就 exit 1 会让几小时的构建白跑，故先重试 3 次。
	# 重试前必须删掉残留目录，否则 git 会以 "destination path already exists" 直接失败。
	local TRY=1
	while [ "$TRY" -le 3 ]; do
		if git clone --depth=1 --single-branch --branch $PKG_BRANCH "https://github.com/$PKG_REPO.git"; then
			break
		fi
		echo "::warning::克隆 $PKG_REPO@$PKG_BRANCH 第 $TRY 次失败，5 秒后重试"
		rm -rf "./$REPO_NAME"
		TRY=$((TRY + 1))
		sleep 5
	done
	if [ ! -d "./$REPO_NAME" ]; then
		echo "::error::克隆 $PKG_REPO@$PKG_BRANCH 连续 3 次失败（分支改名/仓库私有/限流）"
		exit 1
	fi

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		find ./$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
		rm -rf ./$REPO_NAME/
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		mv -f $REPO_NAME $PKG_NAME
	elif [[ "$PKG_SPECIAL" == "all" ]]; then
		find ./$REPO_NAME/ -mindepth 1 -maxdepth 1 -type d -exec cp -rf {} ./ \;
		rm -rf ./$REPO_NAME/
	fi
}

# 调用示例
# UPDATE_PACKAGE "OpenAppFilter" "destan19/OpenAppFilter" "master" "" "custom_name1 custom_name2"
# UPDATE_PACKAGE "open-app-filter" "destan19/OpenAppFilter" "master" "" "luci-app-appfilter oaf" 这样会把原有的open-app-filter，luci-app-appfilter，oaf相关组件删除，不会出现coremark错误。

# UPDATE_PACKAGE "包名" "项目地址" "项目分支" "pkg/name/all，可选，pkg为提取匹配包；name为重命名；all为提取全部一级包"
# 主题：只保留 argon（用户指定）。aurora 及其配置页已按用户要求移除；
# 主题由工作流的 WRT_THEME=argon 决定，Settings.sh 会写入 luci-theme-argon 与 luci-app-argon-config。
UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"

# ===== 已停克隆（2026-09-21）=====
# 下面这些包此前被克隆，但 Config/*.txt 里从来没有对应的 CONFIG_PACKAGE_*=y，
# 真机 `apk list --installed` 也确认它们**从未进入固件** —— 纯浪费 CI 机时
# （每次 clone 5~30 秒）。停掉它们不影响任何固件产物。
# 判定依据不是「看起来没用」，而是三份独立证据：
#   ① Config/*.txt 四个配置文件全量扫描无该符号；
#   ② 真机已装包清单里没有它们；
#   ③ 与厂家基准（Mwrt / higowrt）对比，厂家同样不装。
# 需要时恢复：取消对应行注释，并在 Config 里补 =y。
# UPDATE_PACKAGE "momo" "nikkinikki-org/OpenWrt-momo" "main"
# UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main"
# 已按用户要求移除 OpenClash 与 MosDNS（2026-09-21）：不再克隆它们的源码，
# 同时 Config/GENERAL.txt 里对应 5 个符号已写 =n。两处必须同时改，只改一处
# 会出现「克隆了却不装」的纯浪费（每次 clone 5~30 秒的 CI 机时）。
# UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "dev" "pkg"
# UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
# UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"

# Honk eBPF 透明代理：使用上游预编译 APK（见下方 INSTALL_HONK_PREBUILT）
# 说明：honk 为 Rust/eBPF 架构，从源码编译会超过 GitHub 6 小时上限导致构建取消，
# 因此改为下载上游发布的预编译包，并在首次开机时离线安装进固件。

# UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"

#UPDATE_PACKAGE "athena-led" "unraveloop/JDC-AX6600-Athena-LED-Controller" "main"
# UPDATE_PACKAGE "ddns-go" "sirpdboy/luci-app-ddns-go" "main"
# UPDATE_PACKAGE "diskman" "sbwml/luci-app-diskman" "main"
UPDATE_PACKAGE "diskmanager" "4IceG/luci-app-mini-diskmanager" "main"
# UPDATE_PACKAGE "easytier" "EasyTier/luci-app-easytier" "main"
# 已按用户要求移除 MosDNS（2026-09-21）：与 Config/GENERAL.txt 的 5 个 =n 配套。
# 注意本行第 5 参数原本还会从 feeds 删掉 v2dat 目录；不再克隆后 v2dat 也不再被删，
# 但 Config 里 v2dat=n，不会进固件。
# UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"
# UPDATE_PACKAGE "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox ookla-speedtest"
# UPDATE_PACKAGE "netwizard" "sirpdboy/luci-app-netwizard" "main"
# UPDATE_PACKAGE "openlist2" "sbwml/luci-app-openlist2" "main"
UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
# P17：qbittorrent 未出现在 Config/GENERAL.txt 任何 =y 里，克隆与删 qt6 都是净损失；
# 且其第 5 参数会顺手从 feeds 删掉 qt6base/qt6tools（可能被其它包需要）。故整行禁用。
# UPDATE_PACKAGE "qbittorrent" "sbwml/luci-app-qbittorrent" "master" "" "qt6base qt6tools rblibtorrent"

# ===== MT 模式（MT_MODE）：独立插件配置层 =====
# 允许值：空 / MT5700；其他值（含已停用的 MT5700M）直接终止。
# 空  —— 不克隆、不折叠任何 MT 插件
# MT5700  —— 仅 luci-app-mt5700（单包自含 Rust 后端，不依赖 QModem）
# ⛔ MT5700M（方案 A）已停用：它需要 luci-app-mt5700m + QModem feed 的
#    sms-tool_q / ubus-at-daemon，而 sms-tool_q 的版本号（3.4.0-rc.3）对 apk 非法
#    会导致 world 打包失败，且功能与 MT5700 完全重复。
#    这里不再保留任何克隆/折叠代码 —— 留着只会是永不执行的死代码；
#    拦截交给 ApplyMTMode.sh / VerifyMTMode.sh 的守卫（误选会明确报错终止）。
MT_MODE="${MT_MODE:-}"
echo " "
echo "===== MT_MODE=${MT_MODE:-（空）} ====="
case "$MT_MODE" in
	""|MT5700) ;;
	*)
		echo "::error::非法 MT_MODE='$MT_MODE'（仅允许空 / MT5700；MT5700M 已停用），终止 CI"
		exit 1
		;;
esac

# UPDATE_PACKAGE "quickfile" "sbwml/luci-app-quickfile" "main"
# UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"

# ===== 已停克隆（2026-09-22）：viking feed =====
# 判定方式与上面几行同一套，这次做了穷举核对：
#   ① 拉 VIKINGYFY/packages 顶层目录清单（共 8 个），逐个回查四个 Config 文件：
#        axonhub / luci-app-axonhub / gecoosac / luci-app-gecoosac / luci-app-wolultra
#        —— 四个 Config 文件里**一次都没出现**（连 =n 都没写）；
#        sing-box / luci-app-homeproxy —— 明确 =n（用户要求移除）。
#      即：一个包都不会进固件。
#   ② 下面第 5 参数删除名单里列的 luci-app-timewol / luci-app-wolplus 在上游仓库
#      **已经不存在**了（只剩上面 8 个目录）—— 说明这份名单本身也已过期。
#   ③ 它带进来的 6 个包目录只会被 package/ 扫描一遍（纯耗时），不进产物。
# 结论：与 momo / nikki / openclash / passwall 同属「克隆了却不编入」，按同一标准停掉。
# 需要时恢复：取消下面这行注释，并在对应 Config 里补 =y；同时**必须**恢复紧随其后的
#   那句 rm —— 两行是配套的（见该行注释）。
# UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "axonhub gecoosac sing-box luci-app-homeproxy luci-app-timewol luci-app-wolplus luci-app-wolultra"

# P06（纵深防御）—— ★ 与上面 viking 克隆是**配套**的，别单独删：
#   viking 克隆到 ./packages/（git clone 目录名取 URL 仓库名，第 4 参数为空故原样保留），
#   其内含 sing-box / luci-app-homeproxy 子目录，会被 OpenWrt 的 package/ 扫描拾起。
#   ⚠️ UPDATE_PACKAGE 的删除循环只 find `../feeds/luci/`、`../feeds/packages/`，
#      清不到刚克隆出来的 ./packages/ —— 所以这里必须物理删（cwd 为 wrt/package/）。
#   真正防线仍是 Config/GENERAL.txt 的 =n + VerifyNoSingBox.sh 双重断言。
#   ★ 2026-09-22 起 viking 已停克隆，本行当前是 no-op；保留它是因为重新启用 viking 时
#     必须同时恢复到这一行，删掉就等于把那个安全网弄丢了。
rm -rf ./packages/sing-box ./packages/luci-app-homeproxy

# UPDATE_PACKAGE "vnt" "lmq8267/luci-app-vnt" "main"

# FAN789 插件及其他专用硬件插件
UPDATE_PACKAGE "luci-app-h5000m-fancontrol" "FAN789/luci-app-h5000m-fancontrol" "main"

# ===== MT5700（方案 B）：luci-app-mt5700 单包（Rust 后端由包内 src/Makefile 编译）=====
# 该包 Makefile 的 LUCI_DEPENDS 为空，不依赖 sms-tool_q / ubus-at-daemon。
# 包内 src/Makefile 会在 OpenWrt 包编译阶段调用宿主 cargo 交叉编译 at-webserver-rust，
# 因此这里需要预先装好 rustup + 目标 target，并把 cargo PATH / RUSTFLAGS
# 写入 GITHUB_ENV，供后续 Compile Firmware 步骤使用。
# 链接器必须用 rust-lld（自包含 musl），否则 rustc 会驱动宿主 cc，交叉编译失败。
SETUP_RUST_FOR_MT5700() {
	local RUST_TARGET="aarch64-unknown-linux-musl"
	case "${WRT_TARGET:-${WRT_CONFIG:-}}" in
		x86) RUST_TARGET="x86_64-unknown-linux-musl" ;;
	esac

	if [ "${WRT_TEST:-false}" = "true" ]; then
		echo "luci-app-mt5700: TEST 模式，跳过 rustup 安装（仅生成配置）"
		return 0
	fi

	if ! command -v rustup >/dev/null 2>&1; then
		curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
			| sh -s -- -y --profile minimal --default-toolchain stable
	fi
	export PATH="$HOME/.cargo/bin:$PATH"
	rustup target add "$RUST_TARGET" || true
	# rust-lld 是自包含 musl 静态链接的必需组件，minimal profile 不自带，
	# 缺失会导致 "-C linker=rust-lld" 找不到链接器而编译失败。
	rustup component add rust-lld || true
	echo "luci-app-mt5700: rustup ready, target=$RUST_TARGET"

	# 让后续 GitHub Actions 步骤（尤其 Compile Firmware）能找到 cargo。
	# PATH 只能通过 GITHUB_PATH 追加；不要写入 GITHUB_ENV 的 PATH（会整段覆盖）。
	if [ -n "${GITHUB_PATH:-}" ]; then
		echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"
	fi
	if [ -n "${GITHUB_ENV:-}" ]; then
		echo "CARGO_HOME=$HOME/.cargo" >> "$GITHUB_ENV"
		echo "RUSTUP_HOME=$HOME/.rustup" >> "$GITHUB_ENV"

		# ⚠️ 关键：链接参数必须只作用于「目标架构」，不能用全局 RUSTFLAGS。
		# MT5700 Console 的后端依赖 tokio / serde / chrono / ureq，编译过程会先编
		# host 端的 proc-macro（serde_derive、tokio-macros 等）。全局 RUSTFLAGS 会
		# 一并作用于 host 编译，强制用 rust-lld 链接宿主程序，极易失败。
		# CARGO_TARGET_<TRIPLE>_* 只对交叉目标生效，host 仍用系统 cc，两者互不干扰
		#（cargo 优先级：CARGO_TARGET_<TRIPLE>_RUSTFLAGS > RUSTFLAGS）。
		local ENV_PREFIX
		ENV_PREFIX="$(echo "$RUST_TARGET" | tr '[:lower:]-' '[:upper:]_')"
		echo "CARGO_TARGET_${ENV_PREFIX}_LINKER=rust-lld" >> "$GITHUB_ENV"
		echo "CARGO_TARGET_${ENV_PREFIX}_RUSTFLAGS=-C link-self-contained=yes" >> "$GITHUB_ENV"
		echo "luci-app-mt5700: cross env CARGO_TARGET_${ENV_PREFIX}_LINKER=rust-lld"
	fi
}

# ===== 网络调优：注入首次开机 uci-defaults 与 sysctl =====
# 把 Files/ 下的文件原样铺进固件 files 覆盖层（wrt/files/），随固件一起打包。
# 内容与 H5000M 5G CPE 的实测调优一致（见 Files/etc/uci-defaults/99-mt5700-net）。
INSTALL_NET_TUNING() {
	local SRC_DIR="${GITHUB_WORKSPACE:-$(pwd)/../..}/Files"
	local DST_DIR="${GITHUB_WORKSPACE:-$(pwd)/../..}/wrt/files"

	[ -d "$SRC_DIR" ] || { echo "net-tuning: $SRC_DIR 不存在，跳过"; return 0; }

	mkdir -p "$DST_DIR/etc/uci-defaults" "$DST_DIR/etc/sysctl.d" "$DST_DIR/etc/nftables.d" "$DST_DIR/etc/hotplug.d/net"
	cp -rf "$SRC_DIR/etc/." "$DST_DIR/etc/"

	# ---- 可执行位（2026-09-22 改为按内容判定）--------------------------------
	# 原来按目录写死三条 chmod（uci-defaults / init.d / hotplug.d/net）。那样只覆盖
	# "当时已知的三个目录" —— 将来往 Files/etc 下新增一个目录（例如 hotplug.d/iface/、
	# lib/…）就会漏掉，而漏掉的后果**全是静默的**：
	#   · init.d / uci-defaults：rc.common 与开机脚本直接跳过，不报错；
	#   · hotplug.d：内核热插拔事件里被跳过，同样不报错；
	#   · git 也不保存 exec 位，所以不能指望仓库里的文件权限。
	# 现改为：**凡是首行是 shebang（#!）的覆盖层文件一律 +x**，与它放在哪个目录无关；
	# 非脚本（sysctl 的 .conf / nftables 的 .nft / flow-offload 文本）保持 0644 ——
	# 给数据文件乱加 +x 反而会让"这个目录里哪些是脚本"变得不可读。
	local EXEC_N=0
	while IFS= read -r F; do
		[ "$(head -c 2 "$F" 2>/dev/null)" = '#!' ] || continue
		chmod 0755 "$F" && EXEC_N=$((EXEC_N + 1))
	done < <(find "$DST_DIR" -type f)
	echo "net-tuning: 已注入 Files/etc → wrt/files/etc（识别为脚本并 +x 的 ${EXEC_N} 个）"

	# ---- 完整性断言 ----------------------------------------------------------
	# P08：复制后无断言，调优脚本丢了没人知道（直接后果：刷完没网）。
	# ★ 2026-09-22 改为**逐文件比对源目录**，不再手写白名单。理由：手写清单会随
	#   Files/ 演进而失效 —— 本轮实测就发现白名单只覆盖 5 个、另有 7 个漏网，
	#   其中包括后来新增的 sysctl.d/99-mt5700-conntrack.conf 与 99-mt5700-tcp.conf
	#   （BBR / fq / 16M 缓冲 / NAT 端口段全在这两份里）。它们一旦没铺进去，
	#   固件照样能编能刷，只是所有网络调优**静默失效**。
	#   改为"源里有什么、目标就必须有什么"后，新增文件自动纳入断言，不会再漏。
	#
	#   各文件缺失的具体后果（为啥不能只 warn）：
	#     · uci-defaults/99-mt5700-net       —— 首次开机全部网络配置（含 flow offload 选型）
	#     · uci-defaults/99-mt5700-wan       —— MT5700M 接口 / DNS / 防火墙 wan 区 → 刷完没网
	#     · nftables.d/12-mangle-ttl-128.nft —— TTL 统一，缺失会被运营商丢 TCP 包
	#     · init.d/mt5700-rps + hotplug/30-mt5700-rps —— 四核 RPS 分摊（缺了不报错、只是慢）
	#     · init.d/mt5700-smp                —— 中断亲和 + 关 GRO fraglist
	#     · sysctl.d/99-mt5700-*.conf        —— BBR / fq / 16M / conntrack / NAT 端口段
	local SRC_N=0 MISS_N=0 REL
	while IFS= read -r F; do
		SRC_N=$((SRC_N + 1))
		REL="${F#"$SRC_DIR"/}"
		[ -f "$DST_DIR/$REL" ] || {
			echo "::error::net-tuning: 覆盖层缺失 $REL（源 $F）—— 固件会能编能刷，但该项静默失效"
			MISS_N=$((MISS_N + 1))
		}
	done < <(find "$SRC_DIR" -type f)
	[ "$MISS_N" -eq 0 ] || exit 1
	echo "net-tuning: 覆盖层完整性断言通过（${SRC_N} 个文件逐个比对，与源目录一致）"
}

case "$MT_MODE" in
	MT5700)
		echo "MT_MODE=MT5700：克隆 luci-app-mt5700（不安装 mt5700m / sms-tool_q / ubus-at-daemon）"
		# 源：woshinibabao1/MT5700-Console（本项目自己维护的 MT5700 Console，单包自含
		# LuCI 前端 + Rust 后端 at-webserver-rust，PKG_NAME=luci-app-mt5700）。
		# 注意：仓库名与包名不同，故用第 4 参数 "name" 把克隆目录重命名为包名，
		# 保证 OpenWrt 扫描 package/ 时目录与 PKG_NAME 一致。
		UPDATE_PACKAGE "luci-app-mt5700" "woshinibabao1/MT5700-Console" "main" "name"
		SETUP_RUST_FOR_MT5700
		# 防污染：若工作区意外出现 mt5700m 相关目录，主动移除
		rm -rf ./luci-app-mt5700m ./luci-app-mt5700m_shell
		;;
	*)
		echo "MT_MODE 为空：跳过所有 MT 插件克隆"
		rm -rf ./luci-app-mt5700 ./luci-app-mt5700m ./luci-app-mt5700m_shell
		;;
esac

# H5000M 网络模式切换到 FAN789 原版（与风扇控制同源，避免不同 fork 之间行为不一致）
UPDATE_PACKAGE "luci-app-h5000m-netmode" "FAN789/luci-app-h5000m-netmode" "main"

#安装 Honk 预编译 APK（避免从源码编译 Rust/eBPF 导致超过 6 小时上限）
# 流程：
#   1. 按编译目标架构从上游最新 release 下载 honk 与 luci-app-honk 的 openwrt-25.12 APK：
#        x86      -> x86_64
#        mediatek -> aarch64_cortex-a53（MT798x / MT7622 均为 Cortex-A53，MTK 机型专用）
#        其余     -> aarch64_generic
#      （与 immortalwrt master 的 APK 格式匹配）
#   2. 将 APK 放入固件 files 覆盖层（/etc/honk/），并写入 uci-defaults 脚本，
#      在设备首次开机时离线 apk add 安装（依赖由 GENERAL.txt 编入镜像，无需联网）。
# 注意：上游 APK 基于 OpenWrt 25.12 构建，与 immortalwrt master 同内核/同 musl，ABI 兼容。
INSTALL_HONK_PREBUILT() {
	echo " "

	# 确定目标架构（优先用 WRT-CORE 导出的 WRT_TARGET，回退到 WRT_CONFIG）
	local HONK_ARCH="aarch64_generic"
	case "${WRT_TARGET:-${WRT_CONFIG:-}}" in
		x86) HONK_ARCH="x86_64" ;;
		mediatek) HONK_ARCH="aarch64_cortex-a53" ;;
	esac

	# 定位 OpenWrt 工作区与 files 覆盖层。
	# 注意回退路径用 ../.. —— 本脚本的 cwd 是 wrt/package（见 WRT-CORE.yml），
	# 与 INSTALL_NET_TUNING 保持一致；原先写的 $(pwd)/.. 会得到 wrt/wrt/files。
	# （Actions 里 GITHUB_WORKSPACE 恒有值，所以这个错只在本地调试时才暴露。）
	local WRT_FILES="${GITHUB_WORKSPACE:-$(pwd)/../..}/wrt/files"
	local HONK_DIR="$WRT_FILES/etc/honk"
	local UCI_DIR="$WRT_FILES/etc/uci-defaults"
	mkdir -p "$HONK_DIR" "$UCI_DIR"

	# 获取上游最新 release 的资产下载地址，筛选本架构的 honk / luci-app-honk（排除 legacy / cortex-a53）
	local REL_JSON
	REL_JSON="$(curl -fsSL --retry 5 --retry-all-errors \
		"https://api.github.com/repos/breeze303/openwrt-honk/releases/latest")" || {
		echo "honk prebuilt: failed to fetch release list!"
		return 1
	}

	local DL_URLS
	DL_URLS="$(printf '%s' "$REL_JSON" | jq -r \
		--arg arch "$HONK_ARCH" \
		'.assets[] | select(.name | test("-"+$arch+"-openwrt-25.12.apk$")) | select(.name | test("legacy") | not) | .browser_download_url')" || {
		echo "honk prebuilt: failed to parse release assets!"
		return 1
	}

	if [ -z "$DL_URLS" ]; then
		echo "honk prebuilt: no matching APK for arch $HONK_ARCH!"
		return 1
	fi

	local URL COUNT=0
	for URL in $DL_URLS; do
		echo "honk prebuilt: downloading $URL"
		curl -fsSL --retry 5 --retry-all-errors -o "$HONK_DIR/$(basename "$URL")" "$URL" && COUNT=$((COUNT + 1))
	done

	if [ "$COUNT" -eq 0 ]; then
		echo "honk prebuilt: all downloads failed!"
		return 1
	fi

	# 写入首次开机安装脚本（离线 apk add，依赖已在镜像内）
	cat > "$UCI_DIR/99-honk-install" <<'EOF'
#!/bin/sh
HONK_DIR="/etc/honk"
if command -v apk >/dev/null 2>&1 && [ -d "$HONK_DIR" ]; then
	if apk add --allow-untrusted "$HONK_DIR"/*.apk >/dev/null 2>&1; then
		rm -f "$HONK_DIR"/*.apk
		echo "honk: prebuilt packages installed at first boot."
	else
		echo "honk: prebuilt install skipped (missing dependencies or unsupported target)."
	fi
fi
EOF
	chmod +x "$UCI_DIR/99-honk-install"

	echo "honk prebuilt: $COUNT package(s) staged for $HONK_ARCH, will install at first boot."
}
# 临时禁用 Honk 插件（2026-08-12）：取消下行注释即可重新启用
# INSTALL_HONK_PREBUILT

#更新软件包版本
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-false}
	local PKG_FILES=$(find ./ ../feeds/packages/ -maxdepth 3 -type f -wholename "*/$PKG_NAME/Makefile")

	if [ -z "$PKG_FILES" ]; then
		echo "$PKG_NAME not found!"
		return
	fi

	echo -e "\n$PKG_NAME version update has started!"

	for PKG_FILE in $PKG_FILES; do
		local PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" $PKG_FILE)
		local PKG_TAG=$(curl -sL "https://api.github.com/repos/$PKG_REPO/releases" | jq -r "map(select(.prerelease == $PKG_MARK)) | first | .tag_name")

		local OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")
		local OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE")
		local OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE")
		local OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE")

		local PKG_URL=$([[ "$OLD_URL" == *"releases"* ]] && echo "${OLD_URL%/}/$OLD_FILE" || echo "${OLD_URL%/}")

		local NEW_VER=$(echo $PKG_TAG | sed -E 's/[^0-9]+/\./g; s/^\.|\.$//g')
		local NEW_URL=$(echo $PKG_URL | sed "s/\$(PKG_VERSION)/$NEW_VER/g; s/\$(PKG_NAME)/$PKG_NAME/g")
		local NEW_HASH=$(curl -sL "$NEW_URL" | sha256sum | cut -d ' ' -f 1)

		echo "old version: $OLD_VER $OLD_HASH"
		echo "new version: $NEW_VER $NEW_HASH"

		if [[ "$NEW_VER" =~ ^[0-9].* ]] && dpkg --compare-versions "$OLD_VER" lt "$NEW_VER"; then
			sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
			sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
			echo "$PKG_FILE version has been updated!"
		else
			echo "$PKG_FILE version is already the latest!"
		fi
	done
}

#UPDATE_VERSION "软件包名" "测试版，true，可选，默认为否"
#UPDATE_VERSION "sing-box"

# 防共享上网检测：kmod-rkp-ipid（改写 IP 头 ID 字段）
# 来源 CHN-beta/rkp-ipid —— 仓库根目录本身就是 OpenWrt 内核包
#   （KernelPackage/rkp-ipid，SUBMENU=Other modules），故不加 special 参数，
#   克隆后目录名保持 rkp-ipid，配置符号为 CONFIG_PACKAGE_kmod-rkp-ipid。
#
# ⚠️ **默认不克隆、不编译**（稳定优先，2026-09-21 决策）：
#   上游已 archived（最后提交 2020-10-21），树外内核模块对 6.18 无兼容性保证；
#   编不过＝整次构建失败，编过若在新内核上 OOPS＝整机重启。保留能力但默认关闭。
# 开启方法（两处同时改）：
#   ① 取消下面这行的注释
#   ② Config/GENERAL.txt 里把 CONFIG_PACKAGE_kmod-rkp-ipid 改成 =y
#UPDATE_PACKAGE "rkp-ipid" "CHN-beta/rkp-ipid" "master"

# 网络调优：注入 Files/etc 下的 sysctl 与 uci-defaults（随固件打包，首次开机生效）
INSTALL_NET_TUNING

#引入私有扩展脚本
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi
