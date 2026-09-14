#!/usr/bin/env bash
# Integration test for `dork-db repair --catchup-local` against a throwaway
# Postgres container and a synthetic git history. Needs docker. Run from
# anywhere: ./test/db-catchup.sh
#
# History under test (versions are 2026010100000N):
#   0 dummy      select 1                       - deleted by the rename commit,
#                                                 which makes that commit a
#                                                 ledger boundary
#   1 base       create table t
#   2 add_a      alter table t add column a
#   3 b          create table b                 - renamed to 5 past the squash
#   4 branch     create table br
#   6 last       alter table t add column c     - rewritten in place as the
#                                                 squash baseline
# Scenarios differ only in which of these the local DB already ran.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DORK_DB="$HERE/../bin/dork-db"
IMAGE="${DORK_TEST_PG_IMAGE:-postgres:16-alpine}"
CONTAINER="supabase_db_dorktest"
PORT=54399
WORK=$(mktemp -d)
PASS=0; FAIL=0

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

sql() { docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atq "$@"; }

# ---------------------------------------------------------------------------
# Throwaway Postgres
# ---------------------------------------------------------------------------
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -p "${PORT}:5432" -e POSTGRES_PASSWORD=postgres "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
  if printf 'select 1;' | sql >/dev/null 2>&1; then break; fi
  sleep 1
done
printf 'select 1;' | sql >/dev/null || { echo "postgres did not come up"; exit 1; }

# ---------------------------------------------------------------------------
# Fake `supabase` CLI: just enough for the catch-up path.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/supabase" <<EOF
#!/usr/bin/env bash
C="$CONTAINER"
q() { docker exec -i "\$C" psql -U postgres -d postgres -Atq -c "\$1"; }
case "\${1:-} \${2:-}" in
  "status -o") exit 1 ;;                    # stack "down": dork-db falls back to config.toml's port
  "migration list")
    {
      for f in supabase/migrations/*.sql; do printf 'L %s\n' "\$(basename "\$f" | cut -d_ -f1)"; done
      q "select version from supabase_migrations.schema_migrations" | sed 's/^/R /'
    } | awk '{ if (\$1=="L") l[\$2]=1; else r[\$2]=1; all[\$2]=1 }
        END { printf "{\"migrations\":["; sep=""
              for (v in all) { printf "%s{\"local\":\"%s\",\"remote\":\"%s\"}", sep, (v in l)?v:"", (v in r)?v:""; sep="," }
              print "]}" }'
    ;;
  "migration repair")                       # migration repair --local --status <applied|reverted> <v>
    case "\$5" in
      applied)  q "insert into supabase_migrations.schema_migrations(version) values ('\$6') on conflict do nothing" >/dev/null ;;
      reverted) q "delete from supabase_migrations.schema_migrations where version = '\$6'" >/dev/null ;;
    esac ;;
  "db diff") echo "test shim: no differ here"; exit 1 ;;   # deep check reports "could not run"
  *) echo "test shim: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/supabase"
export PATH="$WORK/bin:$PATH"

# ---------------------------------------------------------------------------
# Synthetic repo
# ---------------------------------------------------------------------------
REPO="$WORK/repo"; M="$REPO/supabase/migrations"
mkdir -p "$M"
cd "$REPO"
git init -q; git config user.email t@example.com; git config user.name t
printf 'project_id = "dorktest"\n\n[db]\nport = %s\n' "$PORT" > supabase/config.toml

V0=20260101000000; V1=20260101000001; V2=20260101000002; V3=20260101000003
V4=20260101000004; V5=20260101000005; V6=20260101000006
echo 'select 1;'                                    > "$M/${V0}_dummy.sql"
echo 'create table public.t (id int primary key);'  > "$M/${V1}_base.sql"
echo 'alter table public.t add column a int;'       > "$M/${V2}_add_a.sql"
echo 'create table public.b (id int primary key);'  > "$M/${V3}_b.sql"
echo 'create table public.br (id int primary key);' > "$M/${V4}_branch.sql"
echo 'alter table public.t add column c int;'       > "$M/${V6}_last.sql"
git add -A; git commit -qm "history"

git rm -q "$M/${V0}_dummy.sql"; git mv "$M/${V3}_b.sql" "$M/${V5}_b.sql"
git commit -qm "rename b past the coming squash"

git rm -q "$M/${V1}_base.sql" "$M/${V2}_add_a.sql" "$M/${V4}_branch.sql" "$M/${V5}_b.sql"
cat > "$M/${V6}_last.sql" <<'SQL'
-- dork-db:baseline (squashed by test)
CREATE TABLE IF NOT EXISTS "public"."t" (
    "id" integer NOT NULL,
    "a" integer,
    "c" integer
);
CREATE TABLE IF NOT EXISTS "public"."b" (
    "id" integer NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."br" (
    "id" integer NOT NULL
);
SQL
git add -A; git commit -qm "Squash migrations into ${V6}_last"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
reset_db() {   # $@ = versions to apply (their incremental SQL from git) and record
  sql <<'SQL' >/dev/null
drop schema if exists public cascade; create schema public;
create schema if not exists supabase_migrations;
drop table if exists supabase_migrations.schema_migrations;
create table supabase_migrations.schema_migrations (version text primary key, statements text[], name text);
SQL
  local v path
  for v in "$@"; do   # HEAD~2 is the pre-squash history: every file incremental
    path=$(git ls-tree --name-only HEAD~2 supabase/migrations/ | grep "/${v}_")
    git show "HEAD~2:${path}" | sql >/dev/null
    printf "insert into supabase_migrations.schema_migrations(version) values ('%s');" "$v" | sql >/dev/null
  done
}

columns() { printf "select table_name || '.' || column_name from information_schema.columns where table_schema='public' order by 1;" | sql | tr '\n' ' '; }

expect() {   # $1 = label, $2 = output, $3.. = "+text" must appear / "-text" must not
  local label="$1" out="$2"; shift 2
  local want ok=1
  for want in "$@"; do
    case "$want" in
      +*) grep -qF -- "${want#+}" <<<"$out" || { echo "  MISSING: ${want#+}"; ok=0; } ;;
      -*) grep -qF -- "${want#-}" <<<"$out" && { echo "  UNWANTED: ${want#-}"; ok=0; } ;;
    esac
  done
  if [ "$ok" -eq 1 ]; then echo "PASS  $label"; PASS=$((PASS + 1)); else echo "FAIL  $label"; FAIL=$((FAIL + 1)); fi
  if [ "$ok" -eq 0 ] || [ -n "${DORK_TEST_VERBOSE:-}" ]; then printf '%s\n' "$out" | sed 's/^/    | /'; fi
}

run_catchup() { printf 'y\n' | bash "$DORK_DB" repair --catchup-local 2>&1 || true; }

FULL="b.id br.id t.a t.c t.id "

# --- 1. contiguous: DB stopped at 1, nothing out of order ------------------
reset_db "$V1"
out=$(run_catchup)
expect "contiguous history replays as before" "$out" \
  "+renamed past a squash, replayed once: ${V3} -> ${V5}" \
  "+this DB sits just before ${V2}" \
  "-SKIPPED" \
  "+Catch-up complete"
[ "$(columns)" = "$FULL" ] && echo "PASS  schema complete (contiguous)" || { echo "FAIL  schema: $(columns)"; FAIL=$((FAIL + 1)); }

# --- 2. out of order, stray migration LAST (a branch's own file) -----------
reset_db "$V1" "$V6"
out=$(run_catchup)
expect "stray migration at the end of history" "$out" \
  "+probing from ${V2} (the first entry the schema is missing)" \
  "+1 migration(s) in that range are SKIPPED" \
  "+${V6}  ${V6}_last.sql" \
  "+42701" \
  "+Catch-up complete"
[ "$(columns)" = "$FULL" ] && echo "PASS  schema complete (stray last)" || { echo "FAIL  schema: $(columns)"; FAIL=$((FAIL + 1)); }

# --- 3. out of order, stray migration in the MIDDLE -----------------------
reset_db "$V1" "$V4"
out=$(run_catchup)
expect "stray migration in the middle of history" "$out" \
  "+a contiguous run replays from ${V5}" \
  "+applied something out of order" \
  "+1 migration(s) in that range are SKIPPED" \
  "+${V4}  ${V4}_branch.sql" \
  "+42P07" \
  "+Catch-up complete"
[ "$(columns)" = "$FULL" ] && echo "PASS  schema complete (stray middle)" || { echo "FAIL  schema: $(columns)"; FAIL=$((FAIL + 1)); }

# --- 4. real drift is still refused ---------------------------------------
# t is a VIEW here, so 2's ALTER TABLE fails with 42809 (wrong object type):
# not a collision, so the sparse probe must stop instead of skipping it.
reset_db "$V1"
printf 'drop table public.t; create view public.t as select 1 as id;' | sql >/dev/null
out=$(run_catchup)
expect "non-collision failure is still refused" "$out" \
  "+probing from ${V2}" \
  "+42809" \
  "+cannot repair automatically. Nothing was changed" \
  "-Catch-up complete"

echo
echo "passed ${PASS}, failed ${FAIL}"
[ "$FAIL" -eq 0 ]
