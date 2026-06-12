#!/usr/bin/env bash
set -uo pipefail
TEST_NAME="profile-lib"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/plugin/commands/_profile-lib.sh"

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
no() { echo "FAIL: $1"; fail=$((fail+1)); }

WS=""
setup_ws() { WS=$(mktemp -d -t "smp-lib-XXXX"); mkdir -p "$WS/context"; cd "$WS"; }
teardown_ws() { cd "$ROOT"; [ -n "$WS" ] && rm -rf "$WS"; WS=""; }

# --- smp_validate_slug (no cwd dependency) ---
for good in main nas-01 a a1; do
  smp_validate_slug "$good" && ok "valid slug: $good" || no "valid slug rejected: $good"
done
for bad in "" "../etc" "a/b" "UPPER" "-lead" "a b"; do
  smp_validate_slug "$bad" && no "invalid slug accepted: '$bad'" || ok "invalid slug rejected: '$bad'"
done
long33=$(printf 'a%.0s' $(seq 1 33))
smp_validate_slug "$long33" && no "33-char slug accepted" || ok "33-char slug rejected"

# --- smp_derive_slug: always valid, never empty (R2-1) ---
deq() { local got; got=$(smp_derive_slug "$1"); [ "$got" = "$2" ] && ok "derive '$1' -> $2" || no "derive '$1' -> got '$got' want '$2'"; }
deq "MyNAS"   "mynas"
deq "My NAS!" "my-nas"
deq ""        "main"
deq "!!!"     "main"
deq "---"     "main"
gotlong=$(smp_derive_slug "$(printf 'X%.0s' $(seq 1 40))")
smp_validate_slug "$gotlong" && ok "derive long -> valid ($gotlong)" || no "derive long -> invalid '$gotlong'"

# --- smp_active_nas fallback rules (Sec 4.2) ---
setup_ws
smp_active_nas >/dev/null 2>&1 && no "active: empty should fail" || ok "active: empty fails"
teardown_ws

setup_ws
mkdir -p context/nas/only; echo x > context/nas/only/profile.md
out=$(smp_active_nas 2>/dev/null) && [ "$out" = "only" ] && [ -f context/active-nas ] && ok "active: single self-heals" || no "active: single failed ($out)"
teardown_ws

setup_ws
mkdir -p context/nas/a context/nas/b; echo x>context/nas/a/profile.md; echo x>context/nas/b/profile.md
smp_active_nas >/dev/null 2>&1 && no "active: multi w/o pointer should fail" || ok "active: multi w/o pointer fails"
teardown_ws

setup_ws
mkdir -p context/nas/a context/nas/b; echo x>context/nas/a/profile.md; echo x>context/nas/b/profile.md
echo b > context/active-nas
out=$(smp_active_nas 2>/dev/null); [ "$out" = "b" ] && ok "active: valid pointer honored" || no "active: pointer ignored ($out)"
teardown_ws

setup_ws
printf '# old\n- hostname: nas9\n' > context/nas-profile.md
# Capture-then-grep: smp_active_nas returns 1 here, and piping it directly into
# grep under `set -o pipefail` would make the pipeline exit 1 (false FAIL).
out=$(smp_active_nas 2>&1) || true
printf '%s\n' "$out" | grep -q "Legacy single-NAS" && ok "active: legacy hint" || no "active: no legacy hint"
teardown_ws

# --- smp_list_nas: sorted, ignores dirs without profile.md ---
setup_ws
mkdir -p context/nas/zeta context/nas/alpha context/nas/empty
echo x>context/nas/zeta/profile.md; echo x>context/nas/alpha/profile.md
out=$(smp_list_nas | tr '\n' ' '); [ "$out" = "alpha zeta " ] && ok "list: sorted, filtered" || no "list: got '$out'"
teardown_ws

# --- smp_load_profile: extracts + validates; key_path charset ---
setup_ws
mkdir -p context/nas/main
cat > context/nas/main/profile.md <<EOF
## Connection
- host: 192.168.1.10
- port: 22
- user: admin
- key_path: ~/.ssh/synology-manager-plus_ed25519
- connect_timeout_seconds: 10
EOF
echo main > context/active-nas
if smp_load_profile && [ "$HOST" = "192.168.1.10" ] && [ "$PORT" = "22" ] && [ "$NAS_USER" = "admin" ] && [ "$SLUG" = "main" ]; then
  ok "load: extracts fields"; else no "load: extraction failed"; fi
teardown_ws

setup_ws
mkdir -p context/nas/main
printf '## Connection\n- host: h\n- port: 22\n- user: u\n- key_path: /bad;rm\n' > context/nas/main/profile.md
echo main > context/active-nas
smp_load_profile >/dev/null 2>&1 && no "load: bad key_path accepted" || ok "load: bad key_path rejected"
teardown_ws

# --- smp_migrate: lossless + idempotent + resume ---
seed_legacy() {
  printf '# Synology NAS Profile\n- host: 192.168.1.10\n- port: 22\n- user: admin\n- hostname: nasbox\n' > context/nas-profile.md
  echo "report" > context/storage-report.md
  mkdir -p context/volumes context/mounts; echo v > context/volumes/v1.txt; echo m > context/mounts/current.txt
}
setup_ws
seed_legacy
smp_migrate >/dev/null
if [ -f context/nas/nasbox/profile.md ] && [ -f context/nas/nasbox/storage-report.md ] \
   && [ -f context/nas/nasbox/volumes/v1.txt ] && [ -f context/nas/nasbox/mounts/current.txt ] \
   && [ "$(cat context/active-nas)" = "nasbox" ] && [ ! -f context/nas-profile.md ] \
   && [ ! -d context/volumes ] && [ ! -d context/.nas-migrate.tmp ]; then ok "migrate: lossless"; else no "migrate: layout wrong"; fi
smp_migrate >/dev/null 2>&1 && ok "migrate: re-run idempotent" || no "migrate: re-run errored"
teardown_ws

setup_ws
seed_legacy
mkdir -p context/.nas-migrate.tmp/junk context/nas/nasbox; echo partial > context/nas/nasbox/profile.md
smp_migrate >/dev/null
[ "$(cat context/active-nas)" = "nasbox" ] && grep -q 192.168.1.10 context/nas/nasbox/profile.md \
  && [ ! -d context/.nas-migrate.tmp ] && ok "migrate: resume lossless" || no "migrate: resume failed"
teardown_ws

# --- smp_repoint_active ---
setup_ws
mkdir -p context/nas/a context/nas/b; echo x>context/nas/a/profile.md; echo x>context/nas/b/profile.md
echo a > context/active-nas; rm -rf context/nas/a
smp_repoint_active a
[ "$(cat context/active-nas)" = "b" ] && ok "repoint: single remaining becomes active" || no "repoint: did not pick b"
teardown_ws

setup_ws
mkdir -p context/nas/a context/nas/b context/nas/c
echo x>context/nas/a/profile.md; echo x>context/nas/b/profile.md; echo x>context/nas/c/profile.md
echo a > context/active-nas; rm -rf context/nas/a
smp_repoint_active a
[ ! -f context/active-nas ] && ok "repoint: multiple remaining clears pointer" || no "repoint: pointer not cleared"
teardown_ws

setup_ws
mkdir -p context/nas/a; echo x>context/nas/a/profile.md
echo a > context/active-nas; rm -rf context/nas/a
smp_repoint_active a
[ ! -f context/active-nas ] && ok "repoint: none remaining removes pointer" || no "repoint: pointer left behind"
teardown_ws

setup_ws
mkdir -p context/nas/a context/nas/b; echo x>context/nas/a/profile.md; echo x>context/nas/b/profile.md
echo a > context/active-nas; rm -rf context/nas/b
smp_repoint_active b
[ "$(cat context/active-nas)" = "a" ] && ok "repoint: removing non-active leaves pointer" || no "repoint: clobbered active"
teardown_ws

# --- smp_verdict_rank ---
rq() { local got; got=$(smp_verdict_rank "$1"); [ "$got" = "$2" ] && ok "rank '$1' = $2" || no "rank '$1' = got '$got' want '$2'"; }
rq ok 0
rq pass 0
rq warn 1
rq unreachable 1
rq critical 2
rq fail 2
rq "" 2

echo ""
echo "=== test-profile-lib: $pass pass, $fail fail ==="
[ "$fail" -eq 0 ]
