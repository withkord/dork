# dork

Parallel git worktrees for agentic coding.

`dork yolo 4` gives you four isolated worktrees — each with its own branch, port,
dev server, and coding agent (Claude Code by default, Codex with
`dork yolo codex 4`) — tiled in your terminal.
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
curl -fsSL https://raw.githubusercontent.com/withkord/dork/main/install.sh | bash
```

Or via npm: `npm install -g @withkord/dork`. Or from a clone:
`git clone https://github.com/withkord/dork && ./dork/install.sh`.
Update any time with `dork update` (it detects how dork was installed).

**Requirements:** git ≥ 2.31 and bash. Optional but recommended: [`gh`](https://cli.github.com)
(for `dork pr` and merge detection), [Claude Code](https://claude.com/claude-code)
(the default agent) or [Codex](https://developers.openai.com/codex/cli)
(`dork new codex`), and [Ghostty](https://ghostty.org) on macOS **or** tmux anywhere
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
| `dork new [agent] [N]` | New worktree(s) + deps + dev server + agent. N tiles the terminal (Ghostty: 2 or 4, tmux: 2–8). |
| `dork yolo [agent] [N]` | Same, but the agent skips its permission prompts (`claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`). |
| `dork sync [all\|P …]` | Rebase worktree branch(es) onto the latest trunk (see above). |
| `dork pr [title]` | Commit pending changes, push, open a GitHub PR, open its page. |
| `dork kill [P …]` | Stop dev server(s), remove worktree(s), delete branch(es). |
| `dork init [--permissions]` | Set up the current repo (config, gitignore, Claude guard hook, optional permission set). |
| `dork db squash` / `dork db repair …` | Supabase migration squash & repair for teams — see below. |
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

# Coding agent launched in each worktree (default: claude; see "Agents").
#DORK_AGENT=codex

# How an agent is launched. The un-suffixed pair applies to the default
# agent; the _<AGENT> pair applies to that agent only — and is how you teach
# dork an agent it doesn't know.
#DORK_AGENT_CMD='claude'
#DORK_YOLO_CMD='claude --dangerously-skip-permissions'
#DORK_AGENT_CMD_CODEX='codex'
#DORK_YOLO_CMD_CODEX='codex --dangerously-bypass-approvals-and-sandbox'

# Trunk branch (auto-detected), worktree dir, terminal backend.
#DORK_MAIN_BRANCH=main
#DORK_WORKTREE_DIR="$REPO_ROOT/.dork/worktrees"
#DORK_TERMINAL=tmux   # ghostty | tmux | none (auto-detected)
```

Per-user (not committed): `git config --global dork.branch-prefix yourname`,
`git config dork.main-branch <branch>` (per repo, overrides detection),
`git config --global dork.agent codex` (your default agent, overrides
`DORK_AGENT` in `.dork.sh`).

## Agents

dork launches Claude Code by default and knows Codex out of the box. Name the
agent on the command line — bare or as a flag, before or after the pane count:

```sh
dork new codex          # one worktree, codex in the pane
dork yolo codex 4       # four worktrees, codex with approvals+sandbox off
dork yolo --codex       # same thing, flag form
dork new                # claude (the default)
```

Change the default without typing it every time — personally with
`git config --global dork.agent codex`, or for the whole project with
`DORK_AGENT=codex` in `.dork.sh` (the git config wins).

Any other agent works too: an unknown name that's on your `PATH` is simply run
under that name (`dork new gemini` → `gemini`). Since dork can't guess another
agent's skip-the-prompts flag, `dork yolo <that agent>` asks you to spell it
out once in `.dork.sh`:

```sh
DORK_AGENT_CMD_GEMINI='gemini'
DORK_YOLO_CMD_GEMINI='gemini --yolo'
```

(Variable suffix = the agent name uppercased, non-alphanumerics as `_`.)

One caveat when you switch away from Claude Code: the worktree guard hook and
the starter permission set that `dork init` writes are Claude Code features —
other agents ignore them, so in `dork yolo` you're relying on that agent's own
sandbox.

## Supabase migrations (`dork db`)

For repos on Supabase, `dork db` gives the whole team a safe squash/repair
loop for `supabase/migrations/`. **Requires** the `supabase` CLI, `jq`, and
docker (for the local stack); `gh` makes squash open the PR for you.

- **`dork db squash`** — one person consolidates every migration file into a
  single baseline: preflights that local == linked and that the local schema
  really matches the files (via a shadow-database diff), snapshots the linked
  project's bookkeeping to /tmp for rollback, runs
  `supabase migration squash --linked`, re-attaches DDL a pg_dump can't emit
  (see the fences below), inserts an ACL reset ahead of the dump's GRANT
  block so a `REVOKE` survives the squash, gates the result on a clean
  `supabase db diff --linked --schema public`, then commits on its own branch
  and opens the PR.
- **`dork db repair --local`** — everyone else runs this after pulling (or
  wires `dork db repair --auto-local` into dev startup so it's hands-free).
  It reconciles the local bookkeeping, refuses to record anything the actual
  schema doesn't back up, and when the DB turns out to have been **behind**
  the squash it offers a catch-up: the deleted migrations are recovered from
  git history and replayed in ONE transaction. Works from any state — your
  own unapplied migration files included.
- **`dork db repair --verify-local`** — read-only shadow-DB diff of your
  local schema against the migration files.

**The invariant:** squash and repair only ever change the bookkeeping table
`supabase_migrations.schema_migrations`. Nothing in `dork db` runs
`supabase db reset` or `supabase db push`, on any scope, ever — the linked
(production) project's schema, RLS, data and storage are never touched. The
one schema-changing operation is the **local** catch-up replay (real
historical migrations, single transaction, local docker DB only), and even
that is not a reset: local data stays.

**Which local database:** `dork db` resolves the local Postgres from
`supabase status` and, when the stack is down, from `[db] port` in
`supabase/config.toml` — never from a fixed port. It then refuses a port that
another project's `supabase_db_*` container is serving, so a repair or
catch-up run in one project can never read, or replay into, a neighbour's
database.

Migration-file markers `dork db` understands (all optional):

```sql
-- >>> squash-preserve: my_extra_role     ← re-PREPENDED to every new baseline
create role ...;                          -- (cluster-level DDL pg_dump drops)
-- <<< squash-preserve

-- >>> squash-append: keep this trigger  ← re-APPENDED after the dump body
create trigger ...;                       -- (DDL a dump cannot express)
-- <<< squash-append

-- >>> dork-db:acl-reset                  ← written by squash, not by you:
DO $$ ... revoke all ... $$;              --   revokes anon/authenticated/
-- <<< dork-db:acl-reset                  --   service_role on every public
                                          --   relation + routine right before
                                          --   the dump's GRANT block, so the
                                          --   GRANTs rebuild each ACL exactly
                                          --   and a REVOKE survives the squash

-- dork-db:drops old_table.* other.col    ← declare drops done in DO blocks /
                                          --   dynamic SQL the parser can't see
```

`.dork.sh` keys (all optional): `DORK_DB_DEV_CMD` (what boots your local
stack, for messages), `DORK_DB_DEV_AUTOREPAIR=1` (set when dev startup runs
`repair --auto-local`), `DORK_DB_REPAIR_CMD` / `DORK_DB_VERIFY_CMD` (how your
repo spells those commands, e.g. wrapper scripts or npm aliases),
`DORK_DB_DROPS_TAGS` (extra `-- <tag>:drops` marker tags),
`DORK_DB_POST_SQUASH_CHECKS` (multi-line project checks printed after a
squash and put in the PR body), `DORK_DB_PR_BASE` (squash PR base branch), `DORK_DB_ACL_RESET=0` (skip the
ACL reset), `DORK_DB_ACL_RESET_ROLES` (roles it revokes from; default
`anon,authenticated,service_role` - the ones Supabase's default privileges
grant to).

## Upgrading to 0.5

Worktrees moved from `.claude/worktrees/` to `.dork/worktrees/` — they were never
Claude-specific, and dork supports other agents. `.claude/` still holds the guard
hook and permissions, which really are Claude Code's.

If you have live worktrees from an older version, finish and `dork kill` them
before upgrading. Already upgraded and they've gone missing from `dork kill` /
`dork sync` / `dork pr`? Point dork back at the old directory in `.dork.sh`:

```bash
DORK_WORKTREE_DIR="$REPO_ROOT/.claude/worktrees"
```

Then drop that line once they're cleared. Re-run `dork init` afterwards to get
the new `.gitignore` entry.

## Notes & limitations

- Worktrees live under `.dork/worktrees/<port>` inside the repo (gitignored);
  the port doubles as the worktree/branch id.
- Pane tiling drives Ghostty via AppleScript (macOS) or tmux (anywhere). In
  any other terminal, `dork new` still creates the worktree and starts the
  agent — it just prints the dev-server command instead of splitting.
- The worktree guard hook and starter permissions are Claude Code-specific;
  other agents (`dork new codex`) run without them.
- `dork pr` and squash-merge detection need `gh` authenticated for your repo's
  host. Without `gh`, sync still fast-forwards and rebases; it just can't
  detect merged PRs.
- Repo paths containing spaces are not supported in tiled mode.
- `dork kill` force-kills whatever listens on the worktree's port — keep your
  dork port ranges away from ports other services use.

## License

MIT
