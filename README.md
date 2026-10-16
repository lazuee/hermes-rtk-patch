## hermes-rtk-patch

> `hermes-rtk-patch` patches Hermes Agent's terminal tool so every shell command goes through [RTK](https://github.com/rtk-ai/rtk) first. RTK rewrites the command to produce shorter output, so the agent reads less.

## Install

`rtk` and `hermes` both need to be on your `PATH`. If either is missing, the patch exits with `ERR_RTK_NOT_INSTALLED` or `ERR_HERMES_NOT_INSTALLED`.

Install RTK with one of:

```bash
brew install rtk        # macOS / Linux
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
```

Check that it's installed with `which rtk`, then apply the patch:

```bash
curl -fsSL https://raw.githubusercontent.com/lazuee/hermes-rtk-patch/refs/heads/main/patch.sh | sh
```

The script is idempotent. It replaces any existing `# RTK - START` / `# RTK - END` block, so just run it again after upgrading Hermes. Restart any running Hermes sessions so they load the patched module.

Your Hermes build must contain the comment `# The guard chain runs on the deadline worker` in `~/.hermes/hermes-agent/tools/terminal_tool.py`. Tested against the October 2026 release.

## How it works

The patch adds a block to `terminal_tool.py` that rewrites each command before it runs.

1. The command is split into segments on top-level `;`, `&&`, `||`, `|`, `&` and newlines. Quotes, backticks, subshells and comments are handled correctly. Commands containing heredocs are left alone.
2. Each segment is passed to `rtk rewrite` (no shell, 2 second timeout). The exit code decides what happens:

| Result | What runs |
|---|---|
| Exit `0` or `3`, output differs | The rewritten command |
| Exit `2` | Nothing. RTK blocked it, and the call fails with RTK's message on stderr |
| Anything else | The original command |

Segments that already start with `rtk` aren't wrapped again. If `rtk` disappears from `PATH` while Hermes is running, the patch does nothing.

### Uninstall

Remove the marker block and delete the cached bytecode:

```bash
python3 - <<'EOF'
import os
p = os.path.expanduser("~/.hermes/hermes-agent/tools/terminal_tool.py")
lines = open(p).read().splitlines(keepends=True)
skip, out = False, []
for ln in lines:
    if "RTK - START" in ln:
        skip = True
        continue
    if "RTK - END" in ln:
        skip = False
        continue
    if not skip:
        out.append(ln)
open(p, "w").writelines(out)
EOF
rm -f ~/.hermes/hermes-agent/tools/__pycache__/terminal_tool.cpython-*.pyc
```

Restart Hermes afterwards.
