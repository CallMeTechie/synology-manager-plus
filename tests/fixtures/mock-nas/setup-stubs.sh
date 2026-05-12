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

cat > /usr/local/bin/synoservice <<'EOF'
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
chmod +x /usr/local/bin/synoservice

# Phase 2: smartctl 6.5 Mock — Text-Output statt JSON
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

# Phase 2: Stub-Logs für /logs-Command-Tests
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

# Phase 2: synoupgrade Mock — emuliert DSM 7.3.1 Verhalten
# Real-Output: "UPGRADE_CHECKNEWDSM" + exit 255 (beobachtet)
mkdir -p /usr/syno/sbin
cat > /usr/syno/sbin/synoupgrade <<'SYNO_EOF'
#!/usr/bin/env bash
case "$1" in
  --check)
    case "${MOCK_SYNOUPGRADE_STATE:-new}" in
      new)         echo "UPGRADE_CHECKNEWDSM"; exit 255 ;;
      up-to-date)  echo "UPGRADE_HAS_NO_NEW_DSM"; exit 0 ;;
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
