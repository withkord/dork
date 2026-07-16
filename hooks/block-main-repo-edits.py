#!/usr/bin/env python3
"""PreToolUse guard: block edits that leak out of the active git worktree.

When the session runs inside a linked git worktree, an Edit/Write whose target
path lives in the MAIN checkout (or a sibling worktree) instead of this worktree
lands the work on the wrong branch. This hook blocks that.

Exit codes: 2 = block the tool call (stderr is shown to Claude); 0 = allow.
Fails OPEN (exit 0) on any error or ambiguity so a hiccup never wedges editing.
"""

import json
import os
import subprocess
import sys


def git(cwd, *args):
    out = subprocess.run(
        ["git", "-C", cwd, *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout.strip()


def under(child, parent):
    """True if `child` is `parent` itself or a path beneath it."""
    parent = parent.rstrip(os.sep)
    return child == parent or child.startswith(parent + os.sep)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    tool_input = payload.get("tool_input") or {}
    target = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not target:
        return 0

    cwd = payload.get("cwd") or os.getcwd()
    if not os.path.isabs(target):
        target = os.path.join(cwd, target)
    target = os.path.normpath(target)

    try:
        worktree_top = os.path.normpath(git(cwd, "rev-parse", "--show-toplevel"))
        common = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    except Exception:
        return 0  # not a git repo / git unavailable — never block

    common = os.path.normpath(common)
    main_root = os.path.dirname(common) if os.path.basename(common) == ".git" else common

    # Not a linked worktree (we're in the main checkout) — nothing to guard.
    if worktree_top == main_root:
        return 0

    # Block only edits under the main root that fall OUTSIDE this worktree —
    # i.e. the main checkout or a sibling worktree. Edits inside the active
    # worktree, /tmp, or anywhere else are allowed.
    if under(target, main_root) and not under(target, worktree_top):
        rel = os.path.relpath(target, main_root)
        suggested = os.path.join(worktree_top, rel)
        sys.stderr.write(
            "BLOCKED: this edit targets the main checkout / another worktree, "
            "not the active worktree — it would leak onto the wrong branch.\n"
            f"  attempted: {target}\n"
            f"  worktree:  {worktree_top}\n"
            f"  remap to:  {suggested}\n"
            "Re-issue the edit against the worktree path above. Search tools and "
            "sub-agents return main-repo paths; always remap the prefix first.\n"
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
