#!/usr/bin/env bash
# Lockfile detection for fresh worktrees: which installs run, and where.
# Builds throwaway git repos; needs only git. Run: ./test/install-detect.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DORK="$HERE/../bin/dork"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0

# new_repo <name> <tracked file>... : a repo whose tracked files are given
new_repo() {
  local dir="$WORK/$1" f; shift
  mkdir -p "$dir"
  git -C "$dir" init -q
  for f in "$@"; do mkdir -p "$dir/$(dirname "$f")"; echo '{}' > "$dir/$f"; done
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -qm init
  echo "$dir"
}

# expect <name> <repo> <expected plan>  (plan lines: "<dir> <command>")
expect() {
  local name="$1" repo="$2" want="$3" got
  got="$(cd "$repo" && "${BASH:-bash}" "$DORK" _install-plan | tr '\t' ' ')"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); echo "ok   $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $name"
    echo "  want: $(printf '%q' "$want")"; echo "  got:  $(printf '%q' "$got")"
  fi
}

r=$(new_repo pnpm-root package.json pnpm-lock.yaml)
expect "single root lockfile" "$r" ". pnpm install --frozen-lockfile"

r=$(new_repo mixed pyproject.toml uv.lock web/package.json web/package-lock.json)
expect "python root + npm subdir" "$r" $'. uv sync\nweb npm ci'

r=$(new_repo both-root package.json yarn.lock pyproject.toml poetry.lock)
expect "js and python in one dir" "$r" $'. yarn install --frozen-lockfile\n. poetry install'

r=$(new_repo js-priority package.json package-lock.json pnpm-lock.yaml)
expect "pnpm beats a stray package-lock" "$r" ". pnpm install --frozen-lockfile"

r=$(new_repo workspace package.json pnpm-lock.yaml examples/a/package.json examples/a/yarn.lock)
expect "JS workspace root covers nested lockfiles" "$r" ". pnpm install --frozen-lockfile"

r=$(new_repo ws-python package.json pnpm-lock.yaml backend/uv.lock backend/sub/package-lock.json)
expect "JS workspace still installs a nested Python project" "$r" $'. pnpm install --frozen-lockfile\nbackend uv sync'

r=$(new_repo apps apps/web/package.json apps/web/bun.lock apps/api/Gemfile.lock)
expect "two levels deep, no root lockfile" "$r" $'apps/api bundle install\napps/web bun install'

r=$(new_repo too-deep a/b/c/package.json a/b/c/package-lock.json)
expect "deeper than DORK_LOCKFILE_DEPTH is ignored" "$r" ""

r=$(new_repo untracked package.json)
mkdir -p "$r/node_modules/x"; echo '{}' > "$r/node_modules/x/package-lock.json"
expect "untracked lockfiles are ignored" "$r" ""

r=$(new_repo override uv.lock web/package-lock.json)
echo "DORK_INSTALL_CMD='make deps'" > "$r/.dork.sh"
expect "DORK_INSTALL_CMD replaces detection" "$r" ". make deps"

r=$(new_repo depth0 uv.lock web/package-lock.json)
echo "DORK_LOCKFILE_DEPTH=0" > "$r/.dork.sh"
expect "DORK_LOCKFILE_DEPTH=0 is root only" "$r" ". uv sync"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
