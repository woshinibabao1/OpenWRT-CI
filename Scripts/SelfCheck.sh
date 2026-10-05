#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# 静态自检：在**编译之前**用几秒钟拦下那些「编译几小时后才暴露」、
# 或者「刷完机才发现、而排查时根本不会怀疑到编译脚本」的问题。
#
# 定位：本仓没有单元测试 —— 编译脚本的副作用是拉源码 + 编几小时固件，
# 没法在 CI 里 cheap 地跑一遍验证。能 cheap 做的是**静态契约检查**，
# 而下面每一条都对应一个**真踩过**的坑（出处写在各条上方）：
#
#   C1 shell 语法 + 禁 C 风格块注释
#   C2 workflow YAML 可解析
#   C3 调用方不许再抄 WRT-CORE 已有的默认值（防「改一处漏一处」复发）
#   C4 单个 Config/*.txt 内同一 CONFIG_ 符号不许出现两次
#   C5 Files/ 覆盖层必须是 LF
#   C6 plugin-deps 标记区存在且条目数达标
#   C7 MT_MODE 的 default 必须保持空
#   C8 apk 索引缓存持久化：文件 / START= / enable / 为软链父目录建目录，四者齐备
#   C9 README 项目结构树不得漏列 Scripts / Files / workflows / Config
#   C10 软件页在慢链路上的两条防线：uhttpd CGI 预算 + package-manager-call 的补丁
#   C11 Rust 交叉编译前提：不赌组件名 + 按产物验收 rust-lld
#   C12 二进制覆盖层行尾保护（*.bin binary）+ 若固化无线校准则校验其格式
#   C13 Wi-Fi MAC 唯一化守卫（CID 派生 / 不覆盖用户值 / 不重建无线配置）
#   C14 uci-defaults 幂等性守卫（保留配置升级会重放它们 → 会覆盖用户设置的键必须有标记）
#   C15 flow offload 默认值四处一致且为 on（该默认值两个月内反转过两次，auto 不得有 TTL 阻断）
#
# 退出码：0 = 通过；1 = 有违规（每条以 ::error:: 上报，在 Actions 里直接标红）
#
# 用法：
#   bash Scripts/SelfCheck.sh        # 在仓库根目录跑
#   CI：见 .github/workflows/Guard-Check.yml

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0

fail() {
	echo "::error::$1"
	FAIL=1
}

pass() {
	echo "  ok  $1"
}

echo "===== SelfCheck ====="

# ---------- C1：shell 语法 + 禁 C 风格块注释 ----------
# 为什么连注释风格都要管：**斜杠加星号**形式的块注释**不是** shell 注释。
# 行首那个二字符序列会被 glob 展开成 `/` 下的文件列表，然后被当成命令执行 ——
# 报错形如 "/LICENSE.txt: line 2: Note: command not found"，而 `bash -n`
# **查不出来**（语法上它就是一串合法命令）。本仓统一用 `#`。
#
# ★ 本文件自身也在被检查之列，所以下面把那两个字符拆成变量再拼出正则，
#   避免「用来检查的正则自己触发检查」——那样要么恒红、要么得把本文件整体
#   排除，两种都会让守卫在**别处**失效时也看不出来。
SLASH='/'
STAR='*'
# ★ 星号必须转义成字面量：不转义时它是 ERE 的**量词**（含义是「斜杠出现 0 次或多次」），
#   于是正则匹配**任意**位置甚至空串 —— 首次运行时全仓文件一起飘红，报的行号是
#   1:#!/bin/bash 这种完全正常的行，就是此症状。
# ★ 只认「行首 / 空格后 / tab 后」这三种位置，不能退化成「任意位置」：
#   实测全位置匹配会命中一堆**合法 glob**（`/sys/class/net/*/queues/...`、
#   `/etc/nftables.d/*.nft`、`/proc/irq/*/smp_affinity`），全仓误报 8 处。
#   真正会被 glob 展开的正是「作为独立单词开头」的那三种位置。
# ★ 也不能写成 `(^|[[:space:]])/\*`：Windows 的 Git-Bash grep 对**字符类**
#   （`[[:space:]]` / `[A-Za-z]`）匹配恒失败，写了等于在那类环境里恒绿。
#   所以这里用三条显式 -e 分支，tab 用 printf 生成（`$'\t'` 在部分 bash 不展开）。
SLASH='/'
STAR='*'
C_RE_HEAD="^${SLASH}\\${STAR}"
C_RE_SPACE=" ${SLASH}\\${STAR}"
C_RE_TAB="$(printf '\t')${SLASH}\\${STAR}"

echo "-- C1 shell 语法与注释风格"
N=$FAIL
BASH_BIN=""
if command -v bash >/dev/null 2>&1; then
	BASH_BIN=bash
else
	echo "  skip  未找到 bash，跳过语法检查（仍跑注释风格检查）"
fi

# Scripts/ 下：语法 + 注释。
# Files/ 下的 init.d / uci-defaults / hotplug：只查注释 —— 它们跑在 busybox ash 上，
# `bash -n` 对 ash 专有写法可能误报，语法交给真机，注释风格这里就能查。
while IFS= read -r SH; do
	[ -n "$BASH_BIN" ] && { "$BASH_BIN" -n "$SH" || fail "C1 $SH 语法错误（bash -n 未通过）"; }
	HITS="$(grep -nE -e "$C_RE_HEAD" -e "$C_RE_SPACE" -e "$C_RE_TAB" "$SH" || true)"
	[ -n "$HITS" ] && fail "C1 $SH 出现 C 风格块注释（会被 glob 展开成文件列表并当命令执行，bash -n 查不出）：$(printf '%s' "$HITS" | head -n 2 | tr '\n' ' ')"
done < <(find Scripts -maxdepth 1 -type f -name '*.sh' | sort)

while IFS= read -r SH; do
	HITS="$(grep -nE -e "$C_RE_HEAD" -e "$C_RE_SPACE" -e "$C_RE_TAB" "$SH" || true)"
	[ -n "$HITS" ] && fail "C1 $SH 出现 C 风格块注释：$(printf '%s' "$HITS" | head -n 2 | tr '\n' ' ')"
done < <(find Files -type f \( -path '*/init.d/*' -o -path '*/uci-defaults/*' -o -path '*/hotplug.d/*' \) | sort)

[ "$FAIL" -eq "$N" ] && pass "shell 语法通过且无 C 风格块注释"

# ---------- C2/C3/C7：workflow YAML（需要 python3 + PyYAML）----------
# 没有 python3 时**降级为跳过**而不是判红：这三条是防回归的守卫，
# 缺工具就查不了，不能因此把编译挡在门外（守卫误伤比没有守卫更糟）。
echo "-- C2/C3/C7 workflow YAML"
N=$FAIL
PY_BIN=""
for CAND in python3 python; do
	if command -v "$CAND" >/dev/null 2>&1; then
		PY_BIN="$CAND"
		break
	fi
done

if [ -z "$PY_BIN" ]; then
	echo "  skip  未找到 python3，跳过 C2/C3/C7（YAML 解析依赖它）"
else
	# ★ 一律用**相对路径**：脚本开头已 cd 到仓库根。
	#   早先版本把根目录当参数传进来再 os.path.join，在 Windows 上拼出
	#   `/d/xxx\.github/...`（MSYS 风格路径 + 反斜杠），直接 FileNotFoundError。
	YAML_OUT="$("$PY_BIN" <<'PY'
import os, glob, yaml

bad = []

def load(p):
    with open(p, encoding='utf-8') as f:
        return yaml.safe_load(f)

# C2：所有 workflow 都能被解析（YAML 缩进错误在 Actions 里的报错信息极差）
for p in sorted(glob.glob(os.path.join('.github', 'workflows', '*.yml'))):
    try:
        load(p)
    except Exception as e:
        bad.append('C2 %s YAML 解析失败：%s' % (p, e))

defaults = {}

# C3：调用方不许再抄 WRT-CORE 的 default
#   出处：2026-09-23 之前 WRT_THEME/WRT_NAME/WRT_SSID/WRT_WORD/WRT_IP/WRT_PW
#   在两个调用工作流里各抄一遍，改默认值必然漏一处。
#   ⚠️ 只判「值完全相同」：调用方**有意覆盖**默认值是合法用法，不能误伤。
try:
    core = load('.github/workflows/WRT-CORE.yml')
    # YAML 1.1 里 `on:` 会被解析成布尔 True，两种键名都要试
    on = core.get('on', core.get(True, {}))
    inputs = (on.get('workflow_call') or {}).get('inputs') or {}
    defaults = {k: v.get('default') for k, v in inputs.items()
                if isinstance(v, dict) and 'default' in v}

    for p in ['.github/workflows/WRT-BUILD.yml', '.github/workflows/H5000M-MT-AUTO.yml']:
        if not os.path.exists(p):
            continue
        d = load(p)
        for jn, j in (d.get('jobs') or {}).items():
            for k, v in (j.get('with') or {}).items():
                if k in defaults and str(defaults[k]) == str(v):
                    bad.append('C3 %s (%s).with.%s = %r 与 WRT-CORE 的 default 完全相同 '
                               '—— 删掉这一行，改默认值请改 WRT-CORE 的 inputs.default'
                               % (p, jn, k, v))
except Exception as e:
    bad.append('C3 检查自身出错：%s' % e)

# C7：MT_MODE 的 default 必须是空
#   空值语义是「不装任何 MT 插件，保持普通 CI 行为」；两个调用方各自传
#   MT5700 属于**有意的差异化**。把 default 改成 MT5700 会悄悄改变「不传」的行为。
try:
    if str(defaults.get('MT_MODE', '')) != '':
        bad.append('C7 WRT-CORE 的 MT_MODE.default = %r，必须保持空字符串'
                   '（空 = 不装 MT 插件；调用方显式传 MT5700 才装）' % defaults.get('MT_MODE'))
except Exception:
    pass

print('\n'.join(bad))
PY
)"
	if [ -n "$YAML_OUT" ]; then
		printf '%s\n' "$YAML_OUT" | while IFS= read -r LINE; do [ -n "$LINE" ] && fail "$LINE"; done
	fi
	# 注意：上面的 fail 在管道子 shell 里执行，$FAIL 改不到当前 shell，
	# 所以这里用「有没有输出」二次判定，不能只靠 $FAIL。
	if [ -n "$YAML_OUT" ]; then
		fail "C2/C3/C7 workflow 检查未通过（见上）"
	else
		[ "$FAIL" -eq "$N" ] && pass "workflow YAML 可解析、调用方未重复默认值、MT_MODE 默认仍为空"
	fi
fi

# ---------- C4：单文件内 CONFIG_ 符号重复 ----------
# kconfig 对同一符号的多次赋值取**最后一条**，前一条静默失效。
# 跨文件重复是分层的正常用法（机型配置 ← GENERAL ← PRIVATE，后者覆盖前者），
# 所以只查**单个文件内部**。
echo "-- C4 配置文件内符号唯一"
N=$FAIL
while IFS= read -r CFG; do
	# ★ 用 `[^=]` 而不是 `[A-Za-z0-9_]`：同样是 Windows Git-Bash grep 对字符类恒不匹配
	#   的坑（实测 `^CONFIG_[A-Za-z]+=` 计数为 0，而 `^CONFIG_[^=]+=` 与 `^CONFIG_.*=`
	#   都是 6）。语义等价：CONFIG_ 后至少一个非等号字符，再跟等号。
	DUP="$(grep -E '^CONFIG_[^=]+=' "$CFG" | cut -d= -f1 | sort | uniq -d || true)"
	if [ -n "$DUP" ]; then
		fail "C4 $CFG 内以下符号重复赋值（kconfig 只认最后一条，前者静默失效）：$(printf '%s' "$DUP" | tr '\n' ' ')"
	fi
done < <(find Config -maxdepth 1 -type f -name '*.txt' | sort)
[ "$FAIL" -eq "$N" ] && pass "Config/*.txt 单文件内无重复符号"

# ---------- C5：Files/ 覆盖层必须 LF ----------
# CRLF 下 `#!/bin/sh` 变成 `#!/bin/sh` + CR：找不到解释器 → 脚本**静默不执行**
# （rc.common / uci-defaults / hotplug.d 都不报错），是「刷完没生效」最难查的一类。
# .gitattributes 已按目录声明 Files/** text eol=lf，这里兜底查已入库的内容。
#
# ★ 用 `tr -dc` 而不是 grep 查 CR，原因有两条（都是实测，不是推测）：
#   ① MSYS / Git-Bash 的 grep 以**文本模式**读文件，会把 CR 剥掉 ——
#      造一个货真价实的 CRLF 文件（printf 'a\r\nb\r\n'），`grep -c` 照样报 0。
#      也就是说用 grep 查 CR 在 Windows 上是**恒绿**，等于没有这条守卫。
#   ② `$'\r'`（ANSI-C quoting）在部分 bash 里根本不展开，会变成字面 5 个字符，
#      且在命令替换内外行为还不一致（同一条命令直接跑得 0、赋给变量得 1）。
#   tr 是字节级过滤，两种环境行为一致；`wc -c` 的输出再用 tr 去掉空白以便比较。
echo "-- C5 覆盖层行尾"
N=$FAIL
CRLF=""
while IFS= read -r F; do
	# ★ 2026-09-30：二进制覆盖层豁免。本条查的是「shell/conf 覆盖层必须是 LF」，
	#   而校准 e2p 这类二进制里出现 0x0d 是**数据**，不是行尾 —— 7690 字节的表里
	#   出现几个 0x0d 完全正常，按本条判就是恒假红（本文件的 C5 首次纳入无线校准
	#   时就命中了这一条）。它们的完整性由 C12 按大小 / CHIP_ID / FEM 位校验，
	#   .gitattributes 也有 *.bin binary 兜住行尾转换。
	#   ⚠️ 将来新增别的二进制覆盖层时，这里与 .gitattributes 要一起加。
	case "$F" in
		*.bin) continue ;;
	esac
	CR_CNT="$(tr -dc '\r' < "$F" 2>/dev/null | wc -c | tr -d '[:space:]')"
	if [ "${CR_CNT:-0}" -gt 0 ]; then
		CRLF="$CRLF $F"
	fi
done < <(find Files -type f | sort)
if [ -n "$CRLF" ]; then
	fail "C5 以下 Files/ 文件含 CR（设备上会让 #!/bin/sh 找不到解释器、脚本静默不执行）：$CRLF"
else
	[ "$FAIL" -eq "$N" ] && pass "Files/ 全部为 LF"
fi

# ---------- C6：plugin-deps 标记区 ----------
# WRT-CORE 依赖这个区间做「常见依赖断言」。标记被误删/改名时 awk 提取为空，
# 那条断言会退化成「零个包、全部通过」的恒绿 —— 必须显式拦下。
echo "-- C6 plugin-deps 标记区"
N=$FAIL
# ★ 两个标记都必须 `[[:space:]]*$` 锚到行尾：不加锚点时
#   `/^# >>> plugin-deps:begin/` 会把 `…:beginX` 也当成 begin，
#   标记被改名这条守卫就**恒绿**（变异测试实测放过）。
DEPS_N="$(awk '/^# >>> plugin-deps:begin[[:space:]]*$/{f=1;next} /^# >>> plugin-deps:end[[:space:]]*$/{f=0} f && /^CONFIG_PACKAGE_/' Config/GENERAL.txt 2>/dev/null | grep -c . || true)"
if [ "${DEPS_N:-0}" -lt 10 ]; then
	fail "C6 Config/GENERAL.txt 的 plugin-deps 区只提取到 ${DEPS_N:-0} 个包（应 >= 10）—— 标记被改动会让 WRT-CORE 的依赖断言变成恒绿"
else
	[ "$FAIL" -eq "$N" ] && pass "plugin-deps 区提取到 ${DEPS_N} 个包"
fi

# ---------- C8：apk 索引缓存持久化的启用链 ----------
# 出处：2026-09-23 真机 —— LuCI「系统 → 软件」页**每次重启之后**都用不了，
#   必须手动点一次「Update lists…」才恢复。根因是 apk 的索引缓存目录
#   /var/cache/apk 位于 tmpfs 的 /var（真机 `readlink -f /var` 输出 /tmp），
#   索引随重启蒸发；而空缓存时 apk **不会**自动补拉（实测 `apk list -a` 返回 0
#   且不联网），于是页面拿到空数组却不报错 —— 现象和归因之间隔了三层。
#   修法落在 Files/etc/init.d/apk-index-cache，但**文件进了固件 ≠ 会被执行**，
#   下面三件事缺一件都是**静默失效**：固件照出、能刷、能开机，只有软件页不可用。
#     ① 首行是 shebang —— Packages.sh 靠它判定要不要 +x，没有就当成普通文本，
#        留在固件里是 0644，enable 会失败；
#     ② 声明了 START= —— rc.common 靠它排开机顺序，没有就压根不进启动序列；
#     ③ uci-defaults 里有**非注释**行对它 enable —— OpenWrt 不会因为它躺在
#        /etc/init.d/ 下就自动启用。
#     ④ 为软链的**目标父目录**建过目录 —— 本固件 /var 是指向 /tmp 的**软链**，
#        /tmp 是 tmpfs，**每次开机 /var/cache 都不存在**；此时
#        `ln -sfn /usr/share/apk/cache /var/cache/apk` 直接 rc=1
#        （真机实测 `No such file or directory`），整支脚本当场 return 1，
#        连「后台补一次索引」都不执行 —— 只留一行日志，行为与没装它一样。
#        ★ 2026-09-23 首版就是缺这一条，而当时的验证是绿的：复位步骤把
#          /var/cache/apk 留成了空目录，父目录被测试装置顺便建好了。
#          「在错误的前提下验证通过」→ 所以这条必须交给机器。
echo "-- C8 apk 索引缓存持久化"
N=$FAIL
APK_INIT="Files/etc/init.d/apk-index-cache"
if [ ! -f "$APK_INIT" ]; then
	fail "C8 缺少 $APK_INIT —— 没有它，每次重启后 LuCI 软件页都得手动 Update lists 才能用"
else
	# ★ 用 awk 而不是 grep：MSYS / Git-Bash 的 grep 对**字符类**（[[:space:]] 这类）
	#   匹配恒失败，写成 grep 会让这条守卫在 Windows 上**恒绿**（本文件 C1 已踩过同一条）。
	[ "$(head -c 2 "$APK_INIT")" = '#!' ] || fail "C8 $APK_INIT 首行不是 shebang：Packages.sh 按 shebang 判 +x，缺了它文件会以 0644 进固件、enable 直接失败"
	START_N="$(awk '/^#/ { next } /^START=/ { n++ } END { print n+0 }' "$APK_INIT")"
	[ "${START_N:-0}" -ge 1 ] || fail "C8 $APK_INIT 没有 START=：rc.common 排不进开机序列，等于没写"
	# 只看非注释行：注释里提到这个名字不算「启用」
	ENA_N="$(awk '/^#/ { next } /apk-index-cache/ && /enable/ { n++ } END { print n+0 }' Files/etc/uci-defaults/* 2>/dev/null)"
	[ "${ENA_N:-0}" -ge 1 ] || fail "C8 Files/etc/uci-defaults/ 里没有对 apk-index-cache 执行 enable：OpenWrt 不会自动启用 init.d 下的文件，脚本会在固件里躺着不动"

	# ③ 入库文件模式必须是 100755：git 不继承本机的 exec 位，
	#   在不同机器上创建的文件会默默变成 100644。
	#   虽然 Packages.sh 会按 shebang 兜底 chmod，但仓库内保持一致
	#   才能让人一眼看出“这是可执行文件”（现有的
	#   mt5700-rps / mt5700-smp 都是 100755）。
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		APK_MODE="$(git ls-files -s "$APK_INIT" 2>/dev/null | awk '{print $1}')"
		if [ -n "$APK_MODE" ] && [ "$APK_MODE" != "100755" ]; then
			fail "C8 $APK_INIT 入库模式是 $APK_MODE（应 100755）。修法：git update-index --chmod=+x $APK_INIT"
		fi
	else
		echo "  skip  不在 git 工作树内，跳过文件模式检查"
	fi

	# ④ 必须为软链的**目标父目录**建目录（见上方 C8 注释 ④）。
	#   ★ 判据锚在 `dirname ... APK_CACHE` 上，而不是写死 /var/cache/apk：
	#     写死的话，哪天有人改了 $APK_CACHE 的取值，守卫会跟着代码一起走偏、
	#     继续报绿 —— 「守卫与实现各自漂移」是本仓 C6/C9 反复踩过的坑。
	#     代价是这条属于**结构性钉死**：若将来重构这行，守卫必须同步改
	#     （与①②③同性质，均无法在 CI 里跑真机）。
	if [ "$(awk '/^[[:space:]]*#/ { next } /mkdir/ && /dirname/ && /APK_CACHE/ { n++ } END { print n+0 }' "$APK_INIT")" -ge 1 ]; then
		:
	else
		fail "C8 $APK_INIT 没有为软链目标的父目录 mkdir -p：“/var” 是指向 tmpfs 的软链，开机时 /var/cache 不存在，ln 会失败 —— 脚本进固件、被 enable、却只留一行日志，apk 行为与没装它一样"
	fi
fi
[ "$FAIL" -eq "$N" ] && pass "apk 索引缓存持久化：脚本存在、有 START=、已被 uci-defaults 启用、已为软链父目录建目录"

# ---------- C9：README 项目结构树不得漏列实际文件 ----------
# 出处：2026-09-23 上一轮人工修过 6 处「README 与代码矛盾」，但那种比对是**一次性**的、
#   没有记忆 —— 同一轮里新增的 SelfCheck.sh 与 Guard-Check.yml 就都没进结构树，
#   本轮的 apk-index-cache 要不是先写这条守卫也会漏。同一个坑踩到第三次，交给机器。
#
# 判据：Scripts/*.sh、Files/**、.github/workflows/*.yml、Config/*.txt 里真实存在的
#   每个文件，其文件名都必须出现在 README.md 的结构树中。
#   ★ 按 **basename** 而不是相对路径比对：README 的树里写作 `init.d/mt5700-rps`
#     这种带父目录的短名，按完整路径比对会全量误报。
#   ★ 2026-09-28 扩到 Config/：原先不扫它，于是 Config/PRIVATE.txt 从来没进过
#     结构树也没人告警 —— 而它是 Settings.sh 里**最后写入 .config 的一层**
#     （可以覆盖 GENERAL 的同名项），正好属于「不看 README 就不知道它存在」的那类。
#     加进来之后 README 必须同步补上该文件，否则本条会红（这正是要的）。
#   ★ 2026-09-30 由 Files/etc 扩到整个 Files/：无线校准二进制落在
#     Files/lib/firmware/mediatek/mt7996/ 下，只扫 etc/ 会让它成为「文档里不存在的
#     覆盖层文件」—— 而它的作用（顶掉 mt76 的默认校准）恰恰是看不见就想不到的那类。
echo "-- C9 README 结构树完整性"
N=$FAIL
MISS=""
CNT=0
for F in $(find Scripts -maxdepth 1 -type f -name '*.sh' | sort) \
	$(find Files -type f | sort) \
	$(find .github/workflows -type f -name '*.yml' | sort) \
	$(find Config -maxdepth 1 -type f -name '*.txt' | sort); do
	B="${F##*/}"
	CNT=$(( CNT + 1 ))
	grep -qF "$B" README.md || MISS="$MISS $B"
done
# ★ 「扫到多少个」本身也要断言（与 C6 同一道防线）：find 的目标目录一旦改名或
#   失效，for 循环一轮都不进 —— CNT=0、MISS 恒为空，这条守卫就退化成**永远通过**，
#   而它恰恰是最后一道防止「文档与代码又一次走散」的检查。
if [ "${CNT:-0}" -lt 20 ]; then
	fail "C9 只扫描到 ${CNT:-0} 个脚本/覆盖层/workflow（应 >= 20）—— find 目标变了会让本条守卫退化成恒绿"
fi
if [ -n "$MISS" ]; then
	fail "C9 README 项目结构树漏列：$MISS —— 「新增了文件却忘了同步文档」正是文档与代码矛盾的复发入口"
else
	[ "$FAIL" -eq "$N" ] && pass "README 结构树覆盖了全部 Scripts / Files / workflow / Config"
fi

# ---------- C10：「软件页在慢链路上用得成吗」的两条防线 ----------
# 出处：2026-09-27 用户报「无法执行 apk update 命令：SyntaxError: Unexpected end of
#   JSON input」。真机复现并**计时到 60.2 秒**，正好等于 uhttpd 的 `-t 60`：
#   /usr/libexec/package-manager-call 是「跑完 apk update 才 json_dump」，
#   中途零输出；uhttpd 到点关掉 CGI 那条连接 → HTTP 200 + **空 body**；
#   前端 fs.js 的 handleCgiIoReply 对 'json' 走 `res.json()`，空串直接抛那句话。
#   慢链路上（本机 5G 漫游、6 个源逐个下，实测还常被截断重试）apk update
#   一两分钟是常态 ⇒ 60 秒预算 ＝「Update lists 永远失败」，跟包管理器好坏无关。
# ★ 两条防线都属于「删掉之后一切照旧能编译、能刷机，只在真机点按钮时才暴露」，
#   所以必须静态钉住。
echo "-- C10 软件页慢链路：CGI 预算 + 并发失败"
N=$FAIL

# ① uhttpd 的 CGI 超时被抬高过（★ 必须跳过注释行 —— 注释里那段「想回退」的
#    说明就写着 script_timeout='60'，不排除会把它当成实际配置值读出来）
UP_T="$(awk '!/^[[:space:]]*#/ && /script_timeout/ {print}' Files/etc/uci-defaults/* 2>/dev/null \
	| grep -oE "script_timeout='?[0-9]+" | grep -oE '[0-9]+' | head -1)"
if [ -z "$UP_T" ]; then
	fail "C10 Files/etc/uci-defaults/ 里没有设置 uhttpd.main.script_timeout：CGI 预算仍是 uhttpd 默认的 60 秒，慢链路上点「Update lists」必得空 body → 前端报 SyntaxError: Unexpected end of JSON input"
elif [ "$UP_T" -lt 120 ]; then
	fail "C10 uhttpd.main.script_timeout 设成了 $UP_T（应 >= 120）：慢链路上 apk update 一两分钟是常态，60 秒预算必失败"
fi

# ② Handles.sh 对 package-manager-call 的两个补丁都必须在
#   ★ 判据必须锁进 **sed 的替换串**，不能只 grep `flock -n -x 200`：
#     Handles.sh 里还有一条运行时自检 `if grep -q 'flock -n -x 200' "$PMC_FILE"`，
#     只按裸字符串匹配的话，**替换串被改坏时这条守卫照样绿**（命中自检那句）——
#     即「守卫被自己的自检顶住」，和 C9 的 CNT 断言是同一类陷阱。
#     尾部那个 `|` 是 sed 的分隔符，只在替换串里出现，拿它当锚最稳。
if ! grep -qF 'if flock -n -x 200; then|' Scripts/Handles.sh; then
	fail "C10 Scripts/Handles.sh 里 sed 的替换串没有 flock -n：并发点「Update lists」会一直等锁，而脚本跑完才输出 JSON ⇒ CGI 零输出熬到超时 ⇒ 前端又报那条 SyntaxError（实测旧行为：空转 60.2 秒）"
fi
if ! grep -qF 'cmd="$cmd --allow-untrusted"' Scripts/Handles.sh; then
	fail "C10 Scripts/Handles.sh 的 sed 替换串里没有 --allow-untrusted：LuCI 软件页将装不上自编译 apk（既有能力被弄丢了）"
fi

[ "$FAIL" -eq "$N" ] && pass "慢链路两点都守着：uhttpd CGI 预算 ${UP_T}s、package-manager-call 的两个补丁都在"

# ---------- C11：Rust 交叉编译前提 —— 不许赌「组件名」 ----------
# 事故（GHA run 36408269360，10:20:18 在 Custom Packages 中断）：Packages.sh 写的是
# `rustup component add rust-lld`，而**Rust 官方发行清单里没有名为 rust-lld 的组件**
# （channel-rust-stable.toml 里携带 LLD 的只有 llvm-tools-preview 与
# llvm-bitcode-linker-preview）。于是那行**每次必失败**：重试 3 次白烧 30 秒，
# 最后以「rust 工具链不完整」终止整条流水线 —— 真实原因只是一个不存在的组件名。
# 判定证据：同一 job 内 `rustup target add aarch64-unknown-linux-musl` 是成功的
# （工具链可写、可用、默认 toolchain 正常），只有 component add 那条瞬时失败，
# 且失败间隔恰好等于重试的 sleep 10s —— 确定性参数错误，不是网络抖动。
# 钉两件事：① 只用清单里真实存在的组件名；② 判据是**产物存在**（rust-lld 可执行
# 文件），不是某条命令的返回码 —— 前者换 toolchain 也不会误判，后者会随版本漂移。
echo "-- C11 Rust 交叉编译前提（组件名 + 产物验收）"
N=$FAIL

PKG_SH="Scripts/Packages.sh"

# ① 可执行的 `component add <名>` 必须在白名单内。
#    ★ 必须排除注释行 —— 上面的修复说明里正引用了那个错误写法，
#      不排除的话这条守卫会把自己判红（和 C1 拆 SLASH/STAR 是同一个动机）。
#    ★ 匹配 `component add` 而不是 `rustup component add`：本仓是通过
#      add_component() 包装调用的，只认前者会**漏掉真正的调用点**。
COMP_NAMES="$(awk '!/^[[:space:]]*#/' "$PKG_SH" \
	| grep -oE 'component add [a-z0-9-]+' | awk '{print $3}' | sort -u || true)"
while IFS= read -r COMP; do
	[ -n "$COMP" ] || continue
	case "$COMP" in
		llvm-tools|llvm-tools-preview) ;;
		*) fail "C11 $PKG_SH 执行了 'component add $COMP'，但它不是 Rust 发行清单里的组件（携带 LLD 的只有 llvm-tools / llvm-tools-preview）—— 这行会每次必失败，报错还会把根因引向「工具链不完整」" ;;
	esac
done <<EOF
$COMP_NAMES
EOF

# ② 必须按**产物**验收 rust-lld，而不是按命令返回码。
if ! grep -qF 'find_rust_lld()' "$PKG_SH"; then
	fail "C11 $PKG_SH 缺少 find_rust_lld()：rust-lld 必须按「可执行文件找得到」判定"
fi
if ! awk '!/^[[:space:]]*#/' "$PKG_SH" | grep -qF '[ -z "$RUST_LLD" ]'; then
	fail "C11 $PKG_SH 没有对 RUST_LLD 的空值判定 —— 找不到 rust-lld 时必须就地判红，否则故障推迟到 Compile Firmware 才以 'linker rust-lld not found' 暴露，离根因几小时"
fi

# ③ 报错必须看得见：add_component 不许再丢弃 rustup 输出。
#    原实现 `rustup ... >/dev/null 2>&1` 导致连续 3 次失败零证据，只能靠猜。
if ! awk '!/^[[:space:]]*#/' "$PKG_SH" | grep -qF 'out="$(rustup'; then
	fail "C11 $PKG_SH 的 add_component 没有捕获 rustup 输出：失败时会打印「第 N 次失败」却没有任何真实报错，无法定位（run 36408269360 就是无证据排查）"
fi

[ "$FAIL" -eq "$N" ] && pass "组件名合法（只用 $(printf '%s' "${COMP_NAMES:-无}" | tr '\n' '/')）、rust-lld 按产物验收、失败时带 rustup 原始报错"

# ---------- C12：二进制覆盖层（行尾保护）+ 若固化无线校准则校验其格式 ----------
# ★ 2026-09-30 回退说明（下面的历史结论仍然成立，但**结论变了**）：
#   本仓当天先按下面的推理把厂家 BE5040 校准固化进了 Files/lib/firmware/mediatek/mt7996/，
#   随后用厂家固件镜像（mwrt-hiveton-h5000m-1139-24）里的**真品**做了逐字节复核，发现：
#     · 本机实际使用的那个槽位（_23_2i5i，内部 FEM）与 mt76 自带默认文件**只差 3 个字节**，
#       其中 2 个是 MAC 字段（MTK 样例地址）、1 个落在 mt76 不解析的区域 → **收益为 0**；
#     · 且 eeprom 里的 MAC 字段就是 mt76 取接口 MAC 的来源，固化一份带**另一段 OUI**
#       （厂家真品是 00:0c:8c）的文件会改掉设备 Wi-Fi MAC → 有多机同 MAC 的风险；
#     · 「上游改名导致校准丢失」这个动机也不成立：mt76 的默认 eeprom 文件与其驱动
#       **同仓库同版本发布**（package/kernel/mt76 从 $(PKG_BUILD_DIR)/firmware/ 安装），
#       不存在"驱动改文件名、文件却没跟上来"的漂移。
#   故**回退该固化**，真正的问题改用 `Files/etc/uci-defaults/99-h5000m-wifi-mac` 解决
#   （见 C13：全机型 BSSID 相同才是那个真缺陷）。下面保留条件式校验：将来若有人再放
#   校准文件进来，四项检查立刻生效。
# 出处（2026-09-30 真机取证，192.168.10.1）：
#   · H5000M 的 factory 分区 /dev/mmcblk0p2 **整块全零**（`dd | tr -d '\000' | wc -c` = 0），
#     所以 mt76 每次开机都打印
#       "eeprom tx_power zeros detected, using defaults" + "eeprom load fail, use default bin"；
#   · 读 /sys/kernel/debug/ieee80211/phy0/mt76/eeprom 拿到驱动真正加载的 7680 字节校准，
#     与 mt76 自带的 mediatek/mt7996/mt7992_eeprom_23_2i5i.bin 逐字节相比只差 11 字节
#     （都是驱动运行时按芯片 efuse 打的补丁）→ 本机确实走的是这个默认文件。
# 结论：整机射频校准**只依赖上游 mt76 的默认文件名**，而这个名字历史上改过
#   （mt7992_eeprom.bin → _23 → _24）。上游一改，本固件的校准就静默消失：WiFi 照常起来，
#   只是功率/频段按**别的板子**的默认值走，没有任何报错。所以把厂家（higowrt）用的
#   BE5040 校准固化进 Files/，由 Packages.sh 铺进固件顶掉同名文件。
# 下面钉住四件事（都是「装错也照样能编译、能刷机、WiFi 也能起」的那种静默失效）：
#   ① 两个文件都在，且大小恰好 7680（mt76 的 MT7996_EEPROM_SIZE；小于它驱动会判
#      "Invalid default bin size" 并放弃 eeprom 初始化）；
#   ② CHIP_ID == 0x7992（MT7992，小端 16 位）—— 拿错芯片的 bin 时驱动虽然会接受，
#      但功率表按别的芯片解析；
#   ③ FEM 类型与文件名对应：`_2i5i`（内部 PA/LNA）文件里的 MT_EE_WIFI_PA_LNA_CONFIG
#      必须是 0，另一个（外部 FEM）必须是 3。驱动按芯片 efuse 判定 FEM 后挑文件，
#      两个文件装反 = 等于没装（而且不会报错）；
#   ④ .gitattributes 必须把 *.bin 声明为 binary，且**排在 `Files/** text eol=lf` 之后**
#      （后写者胜）—— 否则 7680 字节的校准会被当文本翻成 CRLF，驱动按固定偏移读到的
#      是整体错位的表。
echo "-- C12 H5000M 无线校准（厂家 e2p）固化"
N=$FAIL
EE_DIR="Files/lib/firmware/mediatek/mt7996"
EE_INT="$EE_DIR/mt7992_eeprom_23_2i5i.bin"   # 内部 FEM（iPAiLNA，本机实际使用）
EE_EXT="$EE_DIR/mt7992_eeprom_23.bin"        # 外部 FEM（ePAeLNA）
EE_WANT_SIZE=7680
EE_WANT_ID=31122   # 0x7992

# 条件式：目录在就按四项校验；不在就明确 skip（打印理由，而不是静默通过）
if [ -d "$EE_DIR" ]; then

for pair in "$EE_INT:0" "$EE_EXT:3"; do
	EE_F="${pair%:*}"
	EE_FEM="${pair##*:}"
	if [ ! -f "$EE_F" ]; then
		fail "C12 缺少 $EE_F —— 没有它，固件的无线校准只剩上游 mt76 的默认文件名这一条路（上游改名即静默丢失）"
		continue
	fi
	EE_SZ="$(wc -c < "$EE_F" | tr -d '[:space:]')"
	[ "$EE_SZ" = "$EE_WANT_SIZE" ] || fail "C12 $EE_F 大小是 $EE_SZ，应为 $EE_WANT_SIZE（mt76 的 MT7996_EEPROM_SIZE，小于它会被判 Invalid default bin size）"
	# od 是字节级读取，不受核心/行尾设置影响；-tu2 输出本机序（x86/arm 均为小端）
	EE_ID="$(od -An -tu2 -N2 -j0 "$EE_F" 2>/dev/null | tr -d '[:space:]')"
	[ "$EE_ID" = "$EE_WANT_ID" ] || fail "C12 $EE_F 的 CHIP_ID 是 $EE_ID，应为 $EE_WANT_ID（0x7992，MT7992）"
	# MT_EE_WIFI_CONF = 0x190，+6 / +7 各取低 2 位（MT_EE_WIFI_PA_LNA_CONFIG）
	EE_F0="$(od -An -tu1 -N1 -j406 "$EE_F" 2>/dev/null | tr -d '[:space:]')"
	EE_F1="$(od -An -tu1 -N1 -j407 "$EE_F" 2>/dev/null | tr -d '[:space:]')"
	EE_ACT0=$(( ${EE_F0:-99} & 3 ))
	EE_ACT1=$(( ${EE_F1:-99} & 3 ))
	[ "$EE_ACT0" = "$EE_FEM" ] && [ "$EE_ACT1" = "$EE_FEM" ] \
		|| fail "C12 $EE_F 的 FEM 位是 ($EE_ACT0,$EE_ACT1)，按文件名应为 ($EE_FEM,$EE_FEM)：两个文件装反等于没装，且不会报错"
done

else
	echo "  skip  $EE_DIR 不存在 —— 本仓当前**不固化**无线校准（2026-09-30 审计结论，"
	echo "        见本节顶部的 ★ 回退说明：与 mt76 自带默认文件实质等价、且会连带钉住 Wi-Fi MAC）"
fi

# .gitattributes：*.bin 必须是 binary，且必须排在 Files/** 那条之后
EE_ATTR="$(awk '
	/^\*\.bin/ && (/binary/ || /-text/) { bin = NR }
	/^Files\/\*\*[[:space:]]+text/ { files = NR }
	END { if (bin && files && bin > files) print "ok"; else print "bad:" bin "/" files }
' .gitattributes 2>/dev/null)"
[ "$EE_ATTR" = "ok" ] || fail "C12 .gitattributes 里 *.bin 必须是 binary 且排在 Files/** text eol=lf 之后（后写者胜）：当前 $EE_ATTR —— 否则校准二进制会在 Windows 检出时被翻成 CRLF，驱动按固定偏移读到错位的表"

[ "$FAIL" -eq "$N" ] && pass "二进制覆盖层行尾保护就位（*.bin binary 且排在 Files/** 之后）；无线校准按审计结论未固化"

# ---------- C13：Wi-Fi MAC 唯一化守卫 ----------
# 出处（2026-09-30 真机取证，192.168.10.1）：
#   H5000M 的 factory 分区整块全零 → mt76 走内置默认 eeprom，而那份 eeprom 里写死了
#   MediaTek 的**样例 MAC**（MT_EE_MAC_ADDR=00:0c:43:26:60:10 / MAC_ADDR2=...:11），
#   mt76 按频段从 eeprom 取接口 MAC —— 实测：
#     · /sys/class/ieee80211/phy0/macaddress 已被上游 11_fix_wifi_mac 改成 eMMC CID
#       派生值（56:9d:93:7b:f5:a5），但那是 **phy 级**地址；
#     · AP 接口 `phy0.1-ap0` 仍是 00:0c:43:26:60:11（来自 eeprom）。
#   ⇒ **所有刷本固件的 H5000M，2.4G/5G 的 BSSID 都是同一对地址**，同网段必冲突。
#   修法：在 uci 里显式给 wifi-iface 写本机唯一 MAC（OpenWrt 官方路径，
#   /usr/share/ucode/wifi/ap.uc 会把它作为 hostapd 的 bssid=），取值沿用 immortalwrt
#   既有约定（同一颗 phy：radio0 = CID+2、radio1 = CID+3）。
# 下面钉三条「改坏也照样能编译、能刷机」的红线：
#   ① 唯一来源必须是 eMMC CID（不得改成常量/写死某段地址 —— 那就等于换了个固定 MAC）；
#   ② 必须"已有 macaddr 就跳过"，**不得覆盖**用户/上游设过的值；
#   ③ 取不到 base MAC 时必须 `exit 1` 保留待下次开机，不得 `exit 0`（那台机器就永久
#      拿不到唯一 MAC 了；这也是本仓 uci-defaults 的统一语义）。
#   ★ 本门是**结构性钉死**：若将来有意重构这两个脚本，守卫要同步改（与 C8 同性质）。
echo "-- C13 Wi-Fi MAC 唯一化"
N=$FAIL
MAC_UCI="Files/etc/uci-defaults/99-h5000m-wifi-mac"
SCRUB_UCI="Files/etc/uci-defaults/99-h5000m-wifi-scrub"

if [ ! -f "$MAC_UCI" ]; then
	fail "C13 缺少 $MAC_UCI —— 没有它，全机型的 Wi-Fi BSSID 都会是 eeprom 里那对固定样例地址（同网段冲突）"
else
	grep -qF 'macaddr_generate_from_mmc_cid' "$MAC_UCI" \
		|| fail "C13 $MAC_UCI 没有用 macaddr_generate_from_mmc_cid 派生（改成常量就等于把固定 MAC 从 eeprom 搬到脚本里）"
	# ② 必须存在"读到已有值就跳过"的守卫：读 .macaddr 的那一行之后 6 行内要有 continue。
	#    ★ 首版判据写成"文件里出现过 continue"，结果**变异验证时漏判**：脚本里
	#    `[ -n "$dev" ] || continue` 这类无关 continue 也算了命中。改成行窗口后，
	#    删掉守卫会判红（三处变异已复验）。
	awk '/uci -q get/ && /\.macaddr/ { start = NR }
	     start && NR > start && NR <= start + 6 && /continue/ { ok = 1 }
	     END { exit ok ? 0 : 1 }' "$MAC_UCI" \
		|| fail "C13 $MAC_UCI 缺少「已有 macaddr 则跳过」的守卫（读 .macaddr 之后 6 行内没有 continue —— 会覆盖用户设置过的 MAC）"
	# ③ 必须有非 0 退出分支（拿不到 CID 时保留待重试）
	awk '/^[[:space:]]*exit[[:space:]]+1/ { n++ } END { exit (n >= 1) ? 0 : 1 }' "$MAC_UCI" \
		|| fail "C13 $MAC_UCI 没有 exit 1 分支：拿不到 eMMC CID 时会静默成功，那台机器永久拿不到唯一 MAC"
fi

if [ ! -f "$SCRUB_UCI" ]; then
	fail "C13 缺少 $SCRUB_UCI —— 从厂家固件升级过来的机器会带着 assocresp_elements 等私有键（关联成功但 BA 协商超时）"
else
	# 红线：清理脚本只许删私有键，绝不许重建/删除用户的无线配置
	for bad in 'rm -f /etc/config/wireless' 'rm /etc/config/wireless' 'uci delete wireless.radio' 'wifi config'; do
		grep -qF "$bad" "$SCRUB_UCI" && fail "C13 $SCRUB_UCI 出现 '$bad'：清理脚本不得重建/删除用户无线配置（只允许删私有键）"
	done
fi

[ "$FAIL" -eq "$N" ] && pass "Wi-Fi MAC 唯一化与厂家残留清理脚本就位，且红线（CID 派生 / 不覆盖 / 不重建配置）都在"

# ---------- C14：uci-defaults 幂等性（防"每次升级抹掉用户设置"复发）----------
# 根因（2026-09-30 核实到上游源码 + 真机）：eMMC 机型 sysupgrade 走 emmc_copy_config，
# 保留配置升级只还原 keep.d 里列出的文件，而 `/etc/uci-defaults/*` 来自**新 rootfs**
# → 这些脚本**每次刷机都会再执行一遍**。任何"无条件覆盖用户设置"的写法，都会在每次
#   升级后把用户手改的值抹回产品默认（已发生过的两处：5G 信道/频宽、NTP 源；真机证据
#   见 CHANGELOG 2026-09-30 第五节）。
# 本门只钉**确实会覆盖用户设置**的那两个键，要求对应文件必须带"只应用一次"的标记守卫：
#   · Files/etc/uci-defaults/99-mt5700-net → wireless.radio1 的 channel/htmode
#   · Files/etc/uci-defaults/99-mt5700-sys → system.ntp.server
# 判据不是"文件里出现过 .applied 字样"（注释也能满足），而是**条件判断里真的测试了标记**
#   —— 形如 `[ ! -e /etc/config/h5000m-defaults-*.applied ]`。删掉该条件即判红。
echo "-- C14 uci-defaults 幂等性（保留配置升级会重放它们）"
N=$FAIL
for pair in "Files/etc/uci-defaults/99-mt5700-net:wireless.radio1.channel" \
            "Files/etc/uci-defaults/99-mt5700-sys:system.ntp.server"; do
	C14_F="${pair%%:*}"
	C14_KEY="${pair##*:}"
	if [ ! -f "$C14_F" ]; then
		fail "C14 缺少 $C14_F（它负责写 $C14_KEY 的产品默认值）"
		continue
	fi
	# 该文件已不再写这个键 → 本门对它不适用（不误伤有意的删除/改名）
	grep -qF "$C14_KEY" "$C14_F" || continue
	awk '/\[ *!? *-e .*h5000m-defaults-[a-z]+\.applied *\]/ { ok = 1 } END { exit ok ? 0 : 1 }' "$C14_F" \
		|| fail "C14 $C14_F 会写 $C14_KEY，但缺少「只在标记不存在时才应用」的守卫：保留配置升级后本脚本会重跑，用户手改的值会被抹回产品默认（标记路径形如 /etc/config/h5000m-defaults-*.applied；标记放 /etc/config/ 下才能跨升级存活，见 keep.d/base-files）"
done
[ "$FAIL" -eq "$N" ] && pass "两处会覆盖用户设置的 uci-defaults 都带上了「只应用一次」标记守卫"

# ---------- C15：flow offload 默认值四处一致，且默认是 on ----------
# 这条守卫存在的原因：flow offload 的默认值在两个月内被反转过**两次**
#   （2026-09-21 开 → 2026-09-22 关 → 2026-10-05 又开），
# 而每次反转都只改了其中几处、其余靠注释互相"提醒"，必然留下不一致。
# 更糟的是：两次反转的依据都不可靠 —— 支撑「卸载开就断网」的实测，
# 流量根本没经过这台路由器（开发机双网卡，有线 192.168.8.103 跃点 25 优先于
# Wi-Fi 192.168.10.202 跃点 30，tracert 第一跳是另一台路由器的 192.168.8.1）。
# 2026-10-05 绑定源地址重测：开 → conntrack 带 [OFFLOAD]、44.15 MB/39s 全成功、不断网。
#
# 本门钉两件事：
#   ① 四处默认取值必须都是 on（改一处漏三处 = 用户拿到不自洽的固件）：
#      Files/etc/mt5700/flow-offload            → MODE=on
#      Scripts/ApplyFlowOffload.sh              → WRT_FLOW_OFFLOAD:-on
#      WRT-BUILD.yml / H5000M-MT-AUTO.yml / WRT-CORE.yml 的 FLOW_OFFLOAD → 'on'
#   ② 99-mt5700-net 的 auto 分支**不得**再出现"检测到 TTL 规则就强制关卸载"的阻断 ——
#      留着它会让 auto 永远退化成 off，等于默认值改了也不生效。
#      SQM 互斥判定必须保留（那是真互斥：被卸载的连接完全绕过 qdisc）。
echo "-- C15 flow offload 默认值一致且为 on"
N=$FAIL

# ① 四处默认值。判据用"实际取值那行"而不是全文搜 on/off —— 注释里满是
#    auto|off|on|on-hw 的枚举与历史结论，搜关键词必然误判。
for f in Files/etc/mt5700/flow-offload Scripts/ApplyFlowOffload.sh; do
	[ -f "$f" ] || fail "C15 缺少 $f（flow offload 默认值的来源之一）"
done
if [ -f Files/etc/mt5700/flow-offload ]; then
	grep -qx 'MODE=on' Files/etc/mt5700/flow-offload \
		|| fail "C15 Files/etc/mt5700/flow-offload 的默认值不是 MODE=on。2026-10-05 真机 A/B 实测：开启后 conntrack 带 [OFFLOAD]、44.15 MB/39s 全程正常、不断网（原先「默认 off」所依据的「HTTP 25s 超时」实测，流量根本没经过本机——开发机双网卡且有线优先，tracert 第一跳是另一台路由器的 192.168.8.1）。确需关闭请在编译入口选 FLOW_OFFLOAD=off 并在 PR 里说明"
fi
if [ -f Scripts/ApplyFlowOffload.sh ]; then
	grep -q 'WRT_FLOW_OFFLOAD:-on' Scripts/ApplyFlowOffload.sh \
		|| fail "C15 Scripts/ApplyFlowOffload.sh 的兜底默认值不是 on（应与 flow-offload 文件一致，否则老调用方不传参时会写出与固件默认值相反的选型）"
fi
for wf in .github/workflows/WRT-CORE.yml .github/workflows/WRT-BUILD.yml .github/workflows/H5000M-MT-AUTO.yml; do
	[ -f "$wf" ] || continue
	# WRT-CORE 是被调用方（inputs 级 default），另两个是 workflow_dispatch 级
	awk '/^ *WRT_FLOW_OFFLOAD:|^ *FLOW_OFFLOAD:/ {inblk=1; next}
	     inblk && /default:/ { if ($0 !~ /'"'"'on'"'"'/) { print FILENAME": "FNR": "$0; bad=1 } inblk=0 }
	     inblk && /^[A-Za-z_]/ && !/^ / { inblk=0 }
	     END { exit bad ? 1 : 0 }' "$wf" \
		|| fail "C15 $wf 里 FLOW_OFFLOAD 的 default 不是 'on'（四处必须一致，理由见本门注释）"
done

# ② auto 分支不得再有 TTL 阻断，但 SQM 互斥必须保留
NET="Files/etc/uci-defaults/99-mt5700-net"
if [ -f "$NET" ]; then
	# 判据：TTL_RULE 这个变量名只允许出现在注释里，代码里出现即判红。
	# ★ 必须先剥掉行首空白再判 `#` —— 本仓脚本大量用 tab 缩进，注释行是 "\t\t# ..."，
	#   直接用 /^[^#]/ 会把注释误判成代码行（第一版就踩了，C15 首次跑即误报）。
	awk '{ line = $0; sub(/^[ \t]+/, "", line) }
	     line !~ /^#/ && line ~ /TTL_RULE/ { print FNR": "line; bad=1 }
	     END { exit bad ? 1 : 0 }' "$NET" \
		|| fail "C15 $NET 的 auto 分支里又出现了 TTL_RULE 判定（代码行）。该阻断会让 auto 永远退化成 off，等于默认值改了也不生效。2026-10-05 已确认：TTL 规则失效是真的（快转包绕过 postrouting），但不导致断网（flowtable 在 neigh_xmit() 前自行递减 TTL），故该阻断已删除"
	grep -q 'SQM_ON' "$NET" \
		|| fail "C15 $NET 里 SQM 互斥判定（SQM_ON）不见了。它必须保留：被卸载的连接完全绕过 qdisc，CAKE/HTB 一律失效——那才是真互斥"
fi

[ "$FAIL" -eq "$N" ] && pass "flow offload 四处默认值都是 on，auto 分支无 TTL 阻断且保留 SQM 互斥"

# ---------- C16：全仓禁止 init.d/firewall4（真机上不存在，且错误被重定向吞掉）----------
# 这条守卫来自 2026-10-05 一次真实的、连续多轮数据作废的排查。
#
# 【坑】本机（ImmortalWrt SNAPSHOT / nft 体系）的防火墙服务是
#       /etc/init.d/firewall，**不是** /etc/init.d/firewall4。
#       用错名字时 shell 报 `not found`，而 `cmd >/dev/null 2>&1` 会把这个错吃掉，
#       于是「uci 写了 1 + reload 已执行」看起来都成立，实际 **nft 里一条 flowtable 规则都没有**。
#       症状极具欺骗性：uci get 读回来确实是 1、fw4 print 也能生成 flowtable 片段，
#       但设备上 `nft list table inet fw4 | grep -c flowtable` 恒为 0，
#       conntrack 永远看不到 [OFFLOAD] 标记 —— 看起来像「卸载开了却不生效」。
#       2026-10-05 换成 /etc/init.d/firewall 后，flowtable ft 立刻出现。
#
# 【本门范围】全仓扫描（含未来新增的脚本），但**排除本文件自身** ——
#   本注释里就写着这个字符串，否则守卫会把自己判红。
#   当前仓内**没有任何**脚本需要重载防火墙 —— 99-mt5700-net 只写 uci，
#   且跑在 uci-defaults 阶段（彼时防火墙尚未启动，写完自然生效，无需 reload）。
#   因此本门只做「禁止 firewall4」这一件事；将来若有人加了 reload 逻辑，
#   必须同时补 flowtable 落地校验，理由见本注释。
echo "-- C16 全仓禁止 init.d/firewall4（本机真机无此服务名）"
N=$FAIL

BAD_HITS=$(grep -rn 'init\.d/firewall4' \
	--include='*.sh' --include='*.uc' --include='99-*' --include='*.yml' \
	Files/ Scripts/ .github/ 2>/dev/null \
	| grep -v '^\S*:[0-9]*: *#' \
	| grep -v "^Scripts/SelfCheck\.sh:")
if [ -n "$BAD_HITS" ]; then
	echo "$BAD_HITS"
	fail "C16 上列文件里调用了 /etc/init.d/firewall4。本机真机上该服务名不存在（实测 \`/etc/init.d/firewall4: not found\`），而重定向会把错误吞掉，导致 uci 写了 flow_offloading=1 却**一条 flowtable 规则都没生成**。正确服务名是 /etc/init.d/firewall（2026-10-05 实测：换对之后 nft 里立刻出现 flowtable ft）。若你确实要重载，还必须紧跟一次 \`nft list table inet fw4 | grep -c flowtable\` 校验——写完 uci 不等于生效"
fi

[ "$FAIL" -eq "$N" ] && pass "全仓无 init.d/firewall4 调用"

# ---------- C17：TTL 归一链的结构不能被改坏 ----------
# 2026-10-06 刷机验收实测：`mangle_ttl_unify`（hook postrouting/300）与
# `flowtable ft`（hook ingress）是**两个各自独立的 base chain**，同时存在、互不干扰。
# 这正是「offload 默认开」能安全落地的结构前提：TTL 规则失效只是"快转包绕过它"，
# 不是"两个 hook 打架"。
#
# 本门钉住三处一旦改坏就会静默失效的地方：
#   ① 必须声明为 chain（自带 hook）。若被改成普通 chain 再靠别处 jump 过来，
#      语义会变，且 `nft list ruleset | grep ttl` 仍能搜到 → 肉眼查不出来。
#   ② 必须自己带 hook postrouting。挂在 forward 上取不到真实出接口 oifname。
#   ③ 必须用 $wan_devices 而不是写死接口名（写死 "wan" 在本机一条都匹配不上）。
echo "-- C17 TTL 归一链是独立的 postrouting base chain"
N=$FAIL

TTL_NFT="Files/etc/nftables.d/12-mangle-ttl-128.nft"
if [ -f "$TTL_NFT" ]; then
	grep -q '^chain mangle_ttl_unify {' "$TTL_NFT" \
		|| fail "C17 $TTL_NFT 里没有顶格声明 \`chain mangle_ttl_unify {\`。fw4 的 nftables.d 片段在 inet fw4 表内被 include，此处必须自成一个带 hook 的 base chain（实测正确形态：\`chain mangle_ttl_unify { type filter hook postrouting priority 300; ... }\`）。若改成普通 chain 靠别处 jump，规则会静默不生效，而 grep 仍搜得到"
	grep -q 'hook postrouting priority 300' "$TTL_NFT" \
		|| fail "C17 $TTL_NFT 的 chain 声明里没有 \`hook postrouting priority 300\`。必须在 postrouting（路由决策之后）才能拿到真实出接口 oifname，且 priority 300 要大于 fw4 srcnat 的 100 以保证 SNAT 之后再改 TTL"
	grep -q 'oifname \$wan_devices' "$TTL_NFT" \
		|| fail "C17 $TTL_NFT 的规则没有用 \$wan_devices。写死 oifname \"wan\"/\"pppoe-wan\" 是 x86 软路由的习惯命名，在本机（H5000M）一条都匹配不上、规则静默失效；本机实测 wan_devices = { \"eth1\", \"eth2\" }（eth1=有线WAN，eth2=5G模组）"
	# ★ 上一条只是「至少有一处用了变量」，对本文件有两处规则（ip ttl / ip6 hoplimit）
	#   的结构**不设防** —— 只把其中一处换成写死的 oifname，grep 仍能命中剩余那处，
	#   守卫就静默放过了（2026-10-06 反向验证实测判红 4/5，漏的就是这一条）。
	#   所以补一条**定位断言**：禁止出现任何带引号的字面 oifname。
	#   ⚠️ 必须先剥掉注释行再判 —— 本文件注释里正解释着「原方案写死 oifname "wan" /
	#   "pppoe-wan" 是 x86 习惯命名」，直接 grep 会把这段说明当成违规
	#   （2026-10-06 首次跑就误报，还原后仍判红）。
	# 同理 chain 名也不能只按「有 chain 声明」判，必须顶格且与本链同名。
	LITERAL_OIF=$(grep -v '^[[:space:]]*#' "$TTL_NFT" | grep -n 'oifname "' || true)
	if [ -n "$LITERAL_OIF" ]; then
		echo "$LITERAL_OIF"
		fail "C17 $TTL_NFT 的规则代码里出现了写死的 \`oifname \"...\"\`（已排除注释行）。本文件所有出方向匹配必须用 \$wan_devices（本机实测 = { \"eth1\", \"eth2\" }）。写死 \"wan\"/\"pppoe-wan\" 是 x86 软路由的习惯命名，在本机一条都匹配不上 ⇒ 规则静默失效，而 grep wan_devices 仍会命中本文件里的另一处规则，所以不能只靠「有没有用变量」来判"
	fi
else
	fail "C17 缺少 $TTL_NFT（TTL 归一规则被删了）。该规则即便在 offload 开启时不处理快转包，也仍是 offload 关闭时的功能项，不应消失"
fi

[ "$FAIL" -eq "$N" ] && pass "TTL 归一链是独立的 postrouting base chain 且用 \$wan_devices"

echo "===== SelfCheck 结束 ====="
if [ "$FAIL" -ne 0 ]; then
	echo "::error::静态自检未通过，请修正后再编译"
	exit 1
fi
echo "全部通过"
exit 0
