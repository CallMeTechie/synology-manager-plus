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
