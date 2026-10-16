#!/bin/sh
set -eu

if ! command -v rtk >/dev/null 2>&1; then
    printf "Error [ERR_RTK_NOT_INSTALLED]: 'rtk' is not installed or not on PATH. Install RTK first (e.g. 'brew install rtk') and re-run this patch.\n" >&2
    exit 1
fi

if ! command -v hermes >/dev/null 2>&1; then
    printf "Error [ERR_HERMES_NOT_INSTALLED]: 'hermes' is not installed or not on PATH. Install Hermes Agent first and re-run this patch.\n" >&2
    exit 1
fi

tools_dir="$HOME/.hermes/hermes-agent/tools"
target_file="$tools_dir/terminal_tool.py"
anchor_line="The guard chain runs on the deadline worker"

if [ ! -f "$target_file" ] || [ ! -w "$target_file" ]; then
    printf "Error [ERR_FILE_ACCESS]: Target file does not exist or is not writable: %s\n" "$target_file" >&2
    exit 1
fi

if ! grep -Fq "$anchor_line" "$target_file"; then
    printf "Error [ERR_ANCHOR_NOT_FOUND]: Target anchor '%s' not found in %s\n" "$anchor_line" "$target_file" >&2
    exit 1
fi

python3 - "$target_file" "$anchor_line" << 'EOF'
import os
import shutil
import sys
import textwrap

target_file = sys.argv[1]
anchor_line = sys.argv[2]

TEMPLATE = r'''# RTK - START
try:
    import re, shlex, shutil, subprocess
    if shutil.which("rtk"):
        _WRAP_RE = re.compile(r"^rtk\s+rewrite\s+(.+)$", re.DOTALL)
        _RTK_RE = re.compile(r"^rtk(\s|$)")
        _HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)")
        _blocked = []

        def _rw(c):
            fallback = c
            try:
                stripped = c.strip()
                if not stripped:
                    return c
                leading = c[:len(c) - len(c.lstrip())]
                trailing = c[len(c.rstrip()):]

                if _RTK_RE.match(stripped) and not _WRAP_RE.match(stripped):
                    return c

                inner = stripped
                while True:
                    m = _WRAP_RE.match(inner)
                    if not m:
                        break
                    inner = m.group(1).strip()

                if inner != stripped:
                    fallback = leading + inner + trailing

                if not inner or _RTK_RE.match(inner):
                    return fallback

                res = subprocess.run(
                    ["rtk", "rewrite", inner],
                    shell=False, timeout=2,
                    capture_output=True, text=True,
                )
                rc = res.returncode
                out = res.stdout.strip()

                if rc == 2:
                    msg = out or res.stderr.strip()
                    if msg:
                        _blocked.append(msg)
                    return fallback
                if rc not in (0, 3):
                    return fallback

                if not out or out == inner:
                    return fallback
                return leading + out + trailing
            except Exception:
                return fallback

        def _split_cmd(c):
            parts, cur = [], []
            in_s = in_d = ansi = esc = bt = bad = False
            depth, i, n = 0, 0, len(c)

            def flush():
                if cur:
                    parts.append(("".join(cur), False))
                    cur.clear()

            while i < n:
                ch = c[i]
                if esc:
                    cur.append(ch); esc = False; i += 1; continue
                if ch == '\\' and (not in_s or ansi):
                    cur.append(ch); esc = True; i += 1; continue
                if bt:
                    cur.append(ch)
                    if ch == '`':
                        bt = False
                    i += 1; continue
                if in_s:
                    cur.append(ch)
                    if ch == "'":
                        in_s = ansi = False
                    i += 1; continue
                if in_d:
                    cur.append(ch)
                    if ch == '"':
                        in_d = False
                    i += 1; continue
                if ch == "'":
                    in_s = True
                    ansi = bool(cur) and cur[-1] == '$'
                    cur.append(ch); i += 1; continue
                if ch == '"':
                    in_d = True
                    cur.append(ch); i += 1; continue
                if ch == '`':
                    bt = True
                    cur.append(ch); i += 1; continue
                if ch == '#' and (i == 0 or c[i-1].isspace() or c[i-1] in ';&|('):
                    j = c.find('\n', i)
                    j = n if j == -1 else j
                    flush()
                    parts.append((c[i:j], True))
                    i = j; continue
                if ch == '(':
                    depth += 1
                    cur.append(ch); i += 1; continue
                if ch == ')':
                    depth -= 1
                    if depth < 0:
                        bad = True
                        depth = 0
                    cur.append(ch); i += 1; continue

                if depth == 0:
                    two = c[i:i+2]
                    if two in ('&&', '||', '|&'):
                        flush(); parts.append((two, True)); i += 2; continue
                    if ch in (';', '\n'):
                        flush(); parts.append((ch, True)); i += 1; continue
                    if ch == '|' and not (i > 0 and c[i-1] == '>'):
                        flush(); parts.append((ch, True)); i += 1; continue
                    if ch == '&':
                        is_redirect = (i > 0 and c[i-1] in '<>') or c[i+1:i+2] == '>'
                        if not is_redirect:
                            flush(); parts.append((ch, True)); i += 1; continue
                cur.append(ch)
                i += 1

            if in_s or in_d or bt or esc or bad or depth != 0:
                return None
            flush()
            return parts

        if not _HEREDOC_RE.search(command):
            _parts = _split_cmd(command)
            if _parts is not None:
                command = "".join(t if keep else _rw(t) for t, keep in _parts)
                if _blocked:
                    command = "printf '%s\\n' " + shlex.quote(_blocked[0]) + " >&2; false"
except Exception:
    pass
# RTK - END

'''

with open(target_file, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

kept = []
skipping = False
for line in lines:
    if "RTK - START" in line:
        skipping = True
        continue
    if "RTK - END" in line:
        skipping = False
        continue
    if not skipping:
        kept.append(line)

if skipping:
    print("Error: RTK - START found without RTK - END, aborting without changes", file=sys.stderr)
    sys.exit(1)

content = "\n".join(kept) + "\n"

anchor_idx = content.find(anchor_line)
if anchor_idx == -1:
    print("Error: Anchor not found", file=sys.stderr)
    sys.exit(1)

line_start = content.rfind("\n", 0, anchor_idx) + 1
indent = ""
for ch in content[line_start:]:
    if ch in " \t":
        indent += ch
    else:
        break

block = textwrap.indent(TEMPLATE, indent, lambda l: l.strip() != "")
content = content[:line_start] + block + content[line_start:]

tmp_path = target_file + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    f.write(content)
shutil.copymode(target_file, tmp_path)
os.replace(tmp_path, target_file)

print("SUCCESS")
EOF

rm -f "$tools_dir/__pycache__/"terminal_tool.cpython-*.pyc
printf "Info [PATCH_APPLIED]: RTK block updated in %s and bytecode cache removed.\n" "$target_file"