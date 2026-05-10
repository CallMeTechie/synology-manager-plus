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
