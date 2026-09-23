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
#   C8 apk 索引缓存持久化：文件 / START= / enable 三者齐备
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
fi
[ "$FAIL" -eq "$N" ] && pass "apk 索引缓存持久化：脚本存在、有 START=、已被 uci-defaults 启用"

# ---------- C9：README 项目结构树不得漏列实际文件 ----------
# 出处：2026-09-23 上一轮人工修过 6 处「README 与代码矛盾」，但那种比对是**一次性**的、
#   没有记忆 —— 同一轮里新增的 SelfCheck.sh 与 Guard-Check.yml 就都没进结构树，
#   本轮的 apk-index-cache 要不是先写这条守卫也会漏。同一个坑踩到第三次，交给机器。
#
# 判据：Scripts/*.sh、Files/etc/**、.github/workflows/*.yml 里真实存在的每个文件，
#   其文件名都必须出现在 README.md 的结构树中。
#   ★ 按 **basename** 而不是相对路径比对：README 的树里写作 `init.d/mt5700-rps`
#     这种带父目录的短名，按完整路径比对会全量误报。
echo "-- C9 README 结构树完整性"
N=$FAIL
MISS=""
CNT=0
for F in $(find Scripts -maxdepth 1 -type f -name '*.sh' | sort) \
	$(find Files/etc -type f | sort) \
	$(find .github/workflows -type f -name '*.yml' | sort); do
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
	[ "$FAIL" -eq "$N" ] && pass "README 结构树覆盖了全部 Scripts / Files/etc / workflow"
fi

echo "===== SelfCheck 结束 ====="
if [ "$FAIL" -ne 0 ]; then
	echo "::error::静态自检未通过，请修正后再编译"
	exit 1
fi
echo "全部通过"
exit 0
