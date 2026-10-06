#!/usr/bin/env python3
"""
检查 shell 守卫里的管道写法是否会静默失效。

三个已实测的坑（`bash -n` 全部能过，只有运行时才暴露）：

  坑 1  路径列表落在管道符之后
         grep --include='*.md' ... | \\
         Config/ CHANGELOG.md 2>/dev/null | ...
       => 路径列表被当成「待执行命令」。目录不可执行 -> 报错被 2>/dev/null
         吞掉 -> grep 无输入 -> 判据恒空，永不触发。

  坑 2  漏写管道符 |
       => bash 把后面的 sed/grep 当成 grep 的「文件名参数」，
         判据退化成 cat 整个仓库。

  坑 3  grep -vE '^[[:space:]]*#'
       => 会把「整个文件都是 # 注释」的文档（如 Config/GENERAL.txt）整片放行。
         本工具只提示，需人工确认被扫范围里有没有这种纯注释文档。

用法：  python tools/audit-shell-pipes.py <file.sh> [...]
退出码：0 = 通过（坑 3 只 warn）；1 = 发现坑 1/坑 2
"""
import re
import sys

FILTER = re.compile(r'(?<![\w-])(grep|sed|awk|cut|tr|sort|uniq|wc|head|tail|cat)\s')
PATHY = re.compile(r'(?:^|\s)(?:Files/|Scripts/|Config/|\.github/|CHANGELOG\.md\b|README\.md\b|[A-Za-z0-9_.-]+/)')
DIRTY = re.compile(r"grep\s+-v\w*\s+['\"]?\^\[\[:space:\]\]\*#")


def split_blocks(lines):
    """按反斜杠续行合并；返回 [(起始行号, [物理行...])]"""
    out, i = [], 0
    while i < len(lines):
        start, buf = i + 1, [lines[i]]
        while buf[-1].rstrip().endswith('\\') and i + 1 < len(lines):
            i += 1
            buf.append(lines[i])
        out.append((start, buf))
        i += 1
    return out


def audit(path):
    hard, soft = [], []
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')

    for start, buf in split_blocks(lines):
        body = [l for l in buf if l.strip() and not l.strip().startswith('#')]
        if not body:
            continue
        text = '\n'.join(body)
        if not FILTER.search(text):
            continue

        # ---------- 坑 1 ----------
        # 逐物理行找第一处管道符：若该行管道符左侧没有路径，
        # 而下一物理行以路径开头 -> 路径落到了管道右侧。
        for k, line in enumerate(body):
            if '|' not in line:
                continue
            left = line.split('|')[0]
            nxt = body[k + 1] if k + 1 < len(body) else ''
            if not PATHY.search(left) and PATHY.search(nxt):
                hard.append((start, '坑1',
                             '路径列表落在管道符之后 -> grep 无输入，该判据恒空（永不触发）'))
            break

        # ---------- 坑 2 ----------
        n_filter = len(FILTER.findall(text))
        n_pipe = text.count('|')
        if n_filter >= 2 and n_pipe < n_filter - 1:
            hard.append((start, '坑2',
                         '%d 个过滤器只有 %d 个管道符 -> 后面的被当成文件名参数，判据退化成 cat'
                         % (n_filter, n_pipe)))

        # ---------- 坑 3（warn） ----------
        if DIRTY.search(text):
            soft.append((start, '坑3',
                         '排除 # 开头行：若被扫范围含「整片都是 # 注释」的文档（如 Config/GENERAL.txt），'
                         '该文档会被整片放行'))

    return hard, soft


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    bad = 0
    for path in sys.argv[1:]:
        try:
            hard, soft = audit(path)
        except OSError as e:
            print('::error::读不了 %s：%s' % (path, e))
            bad += 1
            continue
        for ln, kind, msg in soft:
            print('  warn %s:%d [%s] %s' % (path, ln, kind, msg))
        if hard:
            bad += 1
            for ln, kind, msg in hard:
                print('::error::%s:%d [%s] %s' % (path, ln, kind, msg))
        else:
            print('  ok   %s 未见坑 1/坑 2' % path)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
