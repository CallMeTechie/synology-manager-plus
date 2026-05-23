#!/usr/bin/env bash
set -euo pipefail

cat > /etc/VERSION <<'EOF'
majorversion="7"
minorversion="2"
productversion="7.2.1"
buildnumber="69057"
smallfixnumber="6"
EOF

cat > /etc/synoinfo.conf <<'EOF'
unique="synology_apollolake_218+"
upnpmodelname="DS218+ (mock)"
EOF

mkdir -p /volume1/documents /volume1/media /volume1/backups
echo "test file" > /volume1/documents/readme.txt
chown -R nas-test:nas-test /volume1

mkdir -p /usr/syno/sbin
cat > /usr/syno/sbin/synoservice <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --list)
    echo "ssh-shell"
    echo "smbd"
    echo "nfsd"
    echo "synocrond"
    echo "synonetd"
    ;;
  *)
    echo "synoservice mock: command '$*' not implemented"
    exit 0
    ;;
esac
EOF
chmod +x /usr/syno/sbin/synoservice

# smartctl 6.5 Mock — Text-Output statt JSON
mkdir -p /opt/mock-smartctl
# Profile-Dateien werden vom Dockerfile dorthin kopiert (siehe COPY-Step).

if [ -x /usr/bin/smartctl ] && [ ! -x /usr/bin/smartctl-real ]; then
  mv /usr/bin/smartctl /usr/bin/smartctl-real
fi

cat > /usr/bin/smartctl <<'SMART_EOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *-a*/dev/sda*)  cat /opt/mock-smartctl/healthy.txt ;;
  *-a*/dev/sdb*)  cat /opt/mock-smartctl/warning.txt ;;
  *-a*/dev/sdc*)  cat /opt/mock-smartctl/critical.txt ;;
  *--scan*)       echo "/dev/sda -d sat # /dev/sda, ATA device"
                  echo "/dev/sdb -d sat # /dev/sdb, ATA device" ;;
  *--version*|*-V*)
                  echo "smartctl 6.5 (mock build) [x86_64-linux] (local build)" ;;
  *-i*/dev/sd*)
                  echo "smartctl 6.5 (mock build) [x86_64-linux] (local build)"
                  echo ""
                  echo "=== START OF INFORMATION SECTION ==="
                  echo "Device Model:     MOCK-DISK-2TB"
                  echo "Serial Number:    WD-MOCKSERIAL01" ;;
  *)              [ -x /usr/bin/smartctl-real ] && exec /usr/bin/smartctl-real "$@"
                  echo "mock-smartctl: unhandled args: $*" >&2; exit 1 ;;
esac
SMART_EOF
chmod +x /usr/bin/smartctl

# Stub-Logs für /logs-Command-Tests
mkdir -p /var/log/synolog

cat > /var/log/messages <<'MSG_EOF'
May 11 09:01:23 nas3 kernel: [    0.000000] Linux version 4.4.302+
May 11 09:01:24 nas3 systemd[1]: Started SSH Daemon.
May 11 10:14:02 nas3 kernel: ata1.00: exception Emask 0x0 SAct 0x0 SErr 0x0 action 0x6 frozen
May 11 13:45:30 nas3 sshd[2345]: Accepted publickey for nas-test from 10.0.0.5 port 41523 ssh2
May 11 17:22:45 nas3 docker[3456]: container abc123 started: nextcloud
May 11 22:18:55 nas3 sshd[5678]: Failed publickey for nas-test from 10.0.0.99 port 53210 ssh2
May 12 00:30:15 nas3 docker[3456]: container abc123 health check failed
May 12 00:30:20 nas3 docker[3456]: container abc123 restarting
May 12 01:15:33 nas3 kernel: md/raid:md2: read error corrected (8 sectors at 12345 on sda3)
May 12 09:00:00 nas3 docker[3456]: container abc123 critical: out of memory
May 12 09:15:30 nas3 docker[3456]: container abc123 stopped
MSG_EOF

cat > /var/log/synolog/synolog.cur <<'SYNO_EOF'
2026-05-11T09:00:00+02:00 nas3 SYSTEM info: System startup completed
2026-05-11T10:14:02+02:00 nas3 STORAGE warning: ata1.00 reported transient error
2026-05-11T22:18:55+02:00 nas3 AUTH warning: Failed SSH login attempt from 10.0.0.99
2026-05-12T00:30:15+02:00 nas3 DOCKER error: Container abc123 health check failed
2026-05-12T09:00:00+02:00 nas3 DOCKER critical: Container abc123 out of memory
SYNO_EOF

cat > /var/log/synopkg.log <<'PKG_EOF'
2026-04-15T03:00:00 [INFO] Updated Docker from 24.0.2 to 24.0.7
2026-04-15T03:00:45 [INFO] Updated Hyper Backup from 4.0.1 to 4.0.2
2026-05-01T03:00:10 [INFO] No new updates available
2026-05-08T03:00:15 [INFO] Updated Container Manager from 23.1.0 to 23.1.1
2026-05-10T03:00:08 [INFO] No new updates available
PKG_EOF

# synoupgrade Mock — emuliert DSM 7.3.1 Verhalten
# Real-Output: "UPGRADE_CHECKNEWDSM" + exit 255 (beobachtet)
mkdir -p /usr/syno/sbin
cat > /usr/syno/sbin/synoupgrade <<'SYNO_EOF'
#!/usr/bin/env bash
case "$1" in
  --check)
    # Default changed: real DSM 7.3.1-86003 returns UPGRADE_CHECKNEWDSM
    # to mean "check completed, no update available" (verified against
    # Marc's DS218+, latest DSM release). Mock now mirrors that:
    # default state is "up-to-date" returning UPGRADE_CHECKNEWDSM.
    case "${MOCK_SYNOUPGRADE_STATE:-up-to-date}" in
      new)         echo "UPGRADE_HAS_NEW_DSM"; exit 0 ;;
      up-to-date)  echo "UPGRADE_CHECKNEWDSM"; exit 255 ;;
      failed)      echo "UPGRADE_CHECKNEWDSM_FAILED"; exit 1 ;;
      *)           echo "UPGRADE_UNKNOWN_STATE_$MOCK_SYNOUPGRADE_STATE"; exit 2 ;;
    esac
    ;;
  *)
    echo "synoupgrade mock: only --check is implemented" >&2
    exit 1
    ;;
esac
SYNO_EOF
chmod +x /usr/syno/sbin/synoupgrade

# docker + docker-compose Mock
# State per env var, default "up". Daemon-Pre-Check classification
# uses stderr output patterns identical to a real docker client.
mkdir -p /var/lib/mock-docker
cat > /usr/local/bin/docker <<'DOCKER_EOF'
#!/usr/bin/env bash
state="${MOCK_DOCKER_DAEMON_STATE:-up}"

case "$1" in
  version|--version)
    # `docker --version` needs neither daemon nor sudo — used by /first-run
    # discovery to detect that docker is installed at /usr/local/bin/docker.
    echo "Docker version 24.0.2, build mock"
    exit 0
    ;;
  logs)
    # `docker logs <container>` — used by /logs --source=docker. Include an
    # error/warn line so the default (error-only) filter has output to show.
    echo "2026-05-12T12:00:00Z INFO  startup ok"
    echo "2026-05-12T12:00:05Z WARN  cache miss, refetching"
    echo "2026-05-12T12:01:10Z ERROR upstream timeout"
    exit 0
    ;;
  info)
    case "$state" in
      up)
        echo "24.0.2"
        exit 0
        ;;
      down)
        echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
        exit 1
        ;;
      noperm)
        # Mocks the case where sudoers is not configured. Real
        # sudo output is "sudo: a password is required" on stderr.
        echo "sudo: a password is required" >&2
        exit 1
        ;;
      *)
        echo "mock-docker: unknown MOCK_DOCKER_DAEMON_STATE=$state" >&2
        exit 1
        ;;
    esac
    ;;
  compose)
    shift
    config_file=""
    project_override=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) config_file="$2"; shift 2 ;;
        -p) project_override="$2"; shift 2 ;;
        --env-file) shift 2 ;;
        *) break ;;
      esac
    done
    sub="${1:-}"; shift || true
    case "$sub" in
      ls)
        if [[ "$*" == *--format*json* ]]; then
          if [ -n "${MOCK_COMPOSE_PROJECTS:-}" ]; then
            echo "$MOCK_COMPOSE_PROJECTS"
          else
            cat <<'LS_EOF'
[{"Name":"healthy-stack","Status":"running(3)","ConfigFiles":"/srv/compose/healthy/docker-compose.yml"},{"Name":"partial-stack","Status":"running(1)","ConfigFiles":"/srv/compose/partial/docker-compose.yml"},{"Name":"stopped-stack","Status":"exited(0)","ConfigFiles":"/srv/compose/stopped/docker-compose.yml"}]
LS_EOF
          fi
        else
          echo "NAME             STATUS         CONFIG FILES"
          echo "healthy-stack    running(3)     /srv/compose/healthy/docker-compose.yml"
          echo "partial-stack    running(1)     /srv/compose/partial/docker-compose.yml"
          echo "stopped-stack    exited(0)      /srv/compose/stopped/docker-compose.yml"
        fi
        exit 0
        ;;
      ps)
        if [[ "$*" == *--format*json* ]]; then
          if [ -n "${MOCK_COMPOSE_PS:-}" ]; then
            # Pass-through: caller can inject any array literal
            printf '%s\n' "$MOCK_COMPOSE_PS"
          else
            case "${project_override:-${MOCK_COMPOSE_PS_PROJECT:-healthy}}" in
              healthy*)
                # JSON array (Compose v2.20.1 behavior). Fields mirror real
                # output: ID, Name, Image, Project, Service, State, Status, Health.
                echo '[{"ID":"abc1","Name":"healthy-stack-web-1","Image":"nginx:alpine","Project":"healthy-stack","Service":"web","State":"running","Status":"Up 1h (healthy)","Health":"healthy"},{"ID":"abc2","Name":"healthy-stack-db-1","Image":"postgres:16","Project":"healthy-stack","Service":"db","State":"running","Status":"Up 1h (healthy)","Health":"healthy"},{"ID":"abc3","Name":"healthy-stack-cache-1","Image":"redis:7-alpine","Project":"healthy-stack","Service":"cache","State":"running","Status":"Up 1h","Health":""}]'
                ;;
              partial*)
                echo '[{"ID":"def1","Name":"partial-stack-web-1","Image":"nginx:alpine","Project":"partial-stack","Service":"web","State":"running","Status":"Up 1h","Health":""},{"ID":"def2","Name":"partial-stack-worker-1","Image":"busybox:latest","Project":"partial-stack","Service":"worker","State":"exited","Status":"Exited (0) 5m ago","Health":""}]'
                ;;
              stopped*)
                echo '[]'
                ;;
            esac
          fi
        else
          echo "NAME                    SERVICE     STATUS"
        fi
        exit 0
        ;;
      up)
        echo "[mock] compose up -d ok" >&2
        exit 0
        ;;
      stop)
        echo "[mock] compose stop ok" >&2
        exit 0
        ;;
      down)
        echo "[mock] compose down ok" >&2
        exit 0
        ;;
      pull)
        case "${MOCK_COMPOSE_PULL_RESULT:-up-to-date}" in
          up-to-date) echo "[mock] all images already up to date" ;;
          updated)    echo "[mock] pulled new images" ;;
          fail)       echo "[mock] pull failed: registry unreachable" >&2; exit 1 ;;
        esac
        exit 0
        ;;
      logs)
        echo "web-1  | 2026-05-12T12:00:00Z INFO  startup ok"
        echo "web-1  | 2026-05-12T12:00:01Z INFO  ready"
        echo "db-1   | 2026-05-12T12:00:00Z INFO  pg starting"
        echo "db-1   | 2026-05-12T12:00:02Z INFO  pg ready"
        exit 0
        ;;
      *)
        echo "mock compose: unhandled subcommand '$sub'" >&2
        exit 1
        ;;
    esac
    ;;
  ps)
    # Order matters: /docker-list's format carries BOTH .Names and the
    # com.docker.compose.project label, so match the more specific label first.
    # /logs uses a plain '{{.Names}}' format and falls through to the .Names arm.
    if [[ "$*" == *--format*com.docker.compose.project* ]]; then
      printf 'healthy-stack-web-1\tnginx:alpine\tUp 1h\thealthy-stack\n'
      printf 'healthy-stack-db-1\tpostgres:16\tUp 1h\thealthy-stack\n'
      printf 'standalone-redis\tredis:7-alpine\tUp 30m\t\n'
    elif [[ "$*" == *--format*.Names* ]]; then
      # `docker ps --format '{{.Names}}'` — used by /logs --source=docker.
      printf 'healthy-stack-web-1\n'
      printf 'standalone-redis\n'
    else
      echo "CONTAINER ID   IMAGE          STATUS"
      echo "abc123         nginx:alpine   Up 1h"
    fi
    exit 0
    ;;
  *)
    echo "mock docker: unhandled top-level arg '$1'" >&2
    exit 1
    ;;
esac
DOCKER_EOF
chmod +x /usr/local/bin/docker
