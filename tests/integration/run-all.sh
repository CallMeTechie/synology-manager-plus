#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Per-process container/image names so parallel CI matrix runs don't collide.
CONTAINER_NAME="mock-nas-runner-$$"
IMAGE_NAME="mock-nas:test-$$"

# Define cleanup BEFORE any docker operation. If `docker build` or `docker run`
# fails (port collision, daemon hiccup, broken image), set -e exits — and we
# still want the half-built image and any half-started container removed.
cleanup() {
  echo "[run-all] Cleanup: stopping mock-nas"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Required tools — fail loud if anything is missing rather than letting tests
# explode with cryptic errors deep in a child script.
for tool in docker nc openssl sshpass ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[run-all] FAIL: required tool '$tool' not on PATH"
    case "$tool" in
      nc) echo "  Install: sudo apt-get install -y netcat-openbsd";;
      sshpass) echo "  Install: sudo apt-get install -y sshpass";;
    esac
    exit 1
  }
done

# Generate a fresh random password for the test container on every run.
# It is passed to docker build via --build-arg and exported so child test
# scripts can read it from $NAS_TEST_PASSWORD. Nothing is hardcoded.
NAS_TEST_PASSWORD=$(openssl rand -hex 12)
export NAS_TEST_PASSWORD

echo "[run-all] Building mock-nas image (with generated test password)"
docker build --build-arg NAS_TEST_PASSWORD="$NAS_TEST_PASSWORD" \
  -t "$IMAGE_NAME" "$ROOT/tests/fixtures/mock-nas/" >/dev/null

echo "[run-all] Starting mock-nas container"
docker run -d --rm --name "$CONTAINER_NAME" -p 12222:2222 "$IMAGE_NAME" >/dev/null

# shellcheck disable=SC2034
for i in $(seq 1 15); do
  if nc -z -w1 localhost 12222 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! nc -z -w1 localhost 12222; then
  echo "[run-all] FAIL: mock-nas not reachable after 15s"
  exit 1
fi
echo "[run-all] mock-nas ready"

TESTS=(
  test-setup-ssh.sh
  test-first-run.sh
  test-diag.sh
  test-nas-status.sh
  test-list-shares.sh
  test-manage-mounts.sh
  # Smart health, summary, logs, DSM updates:
  test-smart-status.sh
  test-health-summary.sh
  test-logs.sh
  test-dsm-update-check.sh
  # Docker / Compose:
  test-compose-list.sh
  test-docker-list.sh
  test-compose-logs.sh
  test-compose-up.sh
  test-compose-down.sh
  test-compose-update.sh
  test-daemon-down.sh
  test-daemon-noperm.sh
)

mkdir -p "$SCRIPT_DIR/logs"

UNIT_TESTS_DIR="$(cd "$SCRIPT_DIR/../unit" 2>/dev/null && pwd || echo "")"
if [ -n "$UNIT_TESTS_DIR" ] && [ -d "$UNIT_TESTS_DIR" ]; then
  for ut in "$UNIT_TESTS_DIR"/test-*.sh; do
    [ -f "$ut" ] || continue
    name=$(basename "$ut")
    echo "[run-all] Unit: $name"
    if ! bash "$ut" >"$SCRIPT_DIR/logs/$name.log" 2>&1; then
      echo "[run-all] FAIL unit: $name (see $SCRIPT_DIR/logs/$name.log)"
      exit 1
    fi
    echo "[run-all] PASS unit: $name"
  done
fi

fail_count=0
for t in "${TESTS[@]}"; do
  log="$SCRIPT_DIR/logs/$t.log"
  echo "[run-all] Running $t"
  if bash "$SCRIPT_DIR/$t" >"$log" 2>&1; then
    echo "[run-all] PASS: $t"
  else
    echo "[run-all] FAIL: $t (see $log)"
    fail_count=$((fail_count + 1))
  fi
done

if [ $fail_count -gt 0 ]; then
  echo "[run-all] $fail_count test(s) failed"
  exit 1
fi

echo "[run-all] All ${#TESTS[@]} tests passed."
