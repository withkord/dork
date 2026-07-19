# dork

Parallel git worktrees for agentic coding.

`dork yolo 4` gives you four isolated worktrees — each with its own branch, port,
dev server, and coding agent (Claude Code by default) — tiled in your terminal.
When PRs merge, `dork sync all` rebases every worktree onto the fresh trunk.
Linear history, no merge commits, no branch babysitting.

```
┌─────────────┬─────────────┐   each pane =
│ agent :3001 │ agent :3002 │   ┌────────┬───────────┐
├─────────────┼─────────────┤   │ agent  │ dev server│
│ agent :3003 │ agent :3004 │   │        ├───────────┤
└─────────────┴─────────────┘   │        │ shell     │
                                └────────┴───────────┘
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/pipedreamerai/dork/main/install.sh | bash
```

Or via npm: `npm install -g @pipedreamerai/dork`. Or from a clone:
`git clone https://github.com/pipedreamerai/dork && ./dork/install.sh`.
Update any time with `dork update` (it detects how dork was installed).

**Requirements:** git ≥ 2.31 and bash. Optional but recommended: [`gh`](https://cli.github.com)
(for `dork pr` and merge detection), [Claude Code](https://claude.com/claude-code)
(the default agent), and [Ghostty](https://ghostty.org) on macOS **or** tmux anywhere
(for pane tiling — without either, dork still manages worktrees, it just doesn't split panes).

## Set up a repo (once per project, committed)

```sh
cd your-repo
dork init
```

This writes three things **meant to be committed**, so teammates who install
dork need zero extra setup:

- **`.dork.sh`** — project config (port range, dev command, env files, …).
  Everything is optional; defaults are auto-detected.
- **`.gitignore`** entries for the worktree directory.
- **`.claude/hooks/block-main-repo-edits.py`** + wiring in `.claude/settings.json` —
  a Claude Code guard that blocks the agent from accidentally editing the main
  checkout (or a sibling worktree) while working inside a worktree.

Branches are named `<prefix>/<port>`. The prefix defaults to your login name;
set your own once with `git config --global dork.branch-prefix yourname`.

### Optional: starter Claude Code permissions

```sh
dork init --permissions
```

Merges a starter permission set into `.claude/settings.json` (additive only —
your existing entries are never removed). Two halves:

- **allow** — common read-only and dev commands (`ls`, `grep`, `git`, `gh`,
  `pnpm`, `node`, …) plus file edits run without permission prompts in normal
  mode. It's a permissive, agent-friendly baseline — trim it to taste.
- **deny** — destructive git is blocked: force-pushing or deleting the trunk,
  `git clean -f`, `git reset --hard`, `git stash`, and `git push` entirely
  (in the dork flow the agent edits and commits; *you* run `dork pr`).
  **Deny rules keep applying in yolo mode** — `--dangerously-skip-permissions`
  skips prompts, not denies — which is what makes `dork yolo` sane.

The set lives in [`claude/permissions.json`](claude/permissions.json). A bare
`dork init` run interactively asks whether to add it; in scripts it defaults
to off (`--no-permissions` silences the question).

## Daily flow

```
1. Start of day    dork yolo 4             4 worktrees, 4 agents, 4 dev servers
2. Develop         edit + test on http://localhost:<port>, commit as you go
3. Open a PR       dork pr "Fix the thing"  commit pending changes, push, gh pr create
4. Review & merge  gh pr merge --squash    (--delete-branch also works)
5. Sync everyone   dork sync all           every branch rebased/reset onto fresh trunk
6. Keep going      next task on the same branch: commit → dork pr "…"
7. Tear down       dork kill               (or dork kill 3001 3002 …)
```

`dork flow` prints this cheat sheet with the details.

### How sync keeps history linear

`dork sync` pulls the trunk, then per worktree:

- nothing the trunk lacks → **fast-forward** to the trunk
- PR squash-merged (gh confirms the exact tip) → **reset** the branch to the fresh trunk
- otherwise → **rebase** onto the trunk; a pushed branch is then pushed with
  `--force-with-lease`, so its PR follows the rewrite and the lease refuses to
  clobber remote commits you haven't fetched

A surviving stale `origin/<branch>` is realigned to the new tip only when
everything it has is already in the trunk — so the branch stays alive between
PRs, and unintegrated work is never touched. Conflicts stay local to one
worktree: resolve there, `git rebase --continue`, re-run sync.

## Commands

| Command | What it does |
|---|---|
| `dork new [N]` | New worktree(s) + deps + dev server + agent. N tiles the terminal (Ghostty: 2 or 4, tmux: 2–8). |
| `dork yolo [N]` | Same, but the agent runs with `--dangerously-skip-permissions`. |
| `dork sync [all\|P …]` | Rebase worktree branch(es) onto the latest trunk (see above). |
| `dork pr [title]` | Commit pending changes, push, open a GitHub PR, open its page. |
| `dork kill [P …]` | Stop dev server(s), remove worktree(s), delete branch(es). |
| `dork init [--permissions]` | Set up the current repo (config, gitignore, Claude guard hook, optional permission set). |
| `dork flow` | Print the daily-flow cheat sheet. |
| `dork update` | Update dork itself. |

## Configuration (`.dork.sh`)

A plain bash file at the repo root, sourced by dork. Commit it. All keys are
optional — with no config at all, dork auto-detects the package manager from
the lockfile, runs `PORT=<port> <pm> run dev` when `package.json` has a `dev`
script, copies `.env` / `.env.local` into each worktree, and uses ports
3001–3008.

```sh
# Port range — give each of your projects a distinct range so parallel
# worktrees across projects never collide.
DORK_BASE_PORT=3101
DORK_MAX_PORT=3108

# Dev-server command; {port} is replaced per worktree.
DORK_DEV_CMD='PORT={port} pnpm dev'
# …or a function, for anything dynamic:
#dork_dev_command() { echo "uv run uvicorn main:app --reload --port $1"; }

# Dependency install for a fresh worktree (auto-detected from the lockfile:
# pnpm / yarn / npm / bun / uv / poetry / bundler).
#DORK_INSTALL_CMD='pnpm install --frozen-lockfile'

# Env files copied into each worktree (default: .env .env.local).
#DORK_ENV_FILES='.env .env.local'
# For per-worktree rewrites, define a function (args: worktree path, port):
#dork_setup_env() {
#  grep -v '^APP_URL=' "$REPO_ROOT/.env.local" > "$1/.env.local" || true
#  echo "APP_URL=http://localhost:$2" >> "$1/.env.local"
#}

# Agent launched in each worktree (default: Claude Code).
#DORK_AGENT_CMD='claude'
#DORK_YOLO_CMD='claude --dangerously-skip-permissions'

# Trunk branch (auto-detected), worktree dir, terminal backend.
#DORK_MAIN_BRANCH=main
#DORK_WORKTREE_DIR="$REPO_ROOT/.claude/worktrees"
#DORK_TERMINAL=tmux   # ghostty | tmux | none (auto-detected)
```

Per-user (not committed): `git config --global dork.branch-prefix yourname`,
`git config dork.main-branch <branch>` (per repo, overrides detection).

## Notes & limitations

- Worktrees live under `.claude/worktrees/<port>` inside the repo (gitignored);
  the port doubles as the worktree/branch id.
- Pane tiling drives Ghostty via AppleScript (macOS) or tmux (anywhere). In
  any other terminal, `dork new` still creates the worktree and starts the
  agent — it just prints the dev-server command instead of splitting.
- `dork pr` and squash-merge detection need `gh` authenticated for your repo's
  host. Without `gh`, sync still fast-forwards and rebases; it just can't
  detect merged PRs.
- Repo paths containing spaces are not supported in tiled mode.
- `dork kill` force-kills whatever listens on the worktree's port — keep your
  dork port ranges away from ports other services use.

## License

MIT
