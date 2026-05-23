# Test fixture image — Alpine major-tag pin tracks the latest 3.x release.
# Pinning to a specific minor (3.19) would silently rot at EOL (~Nov 2025
# for that release). The major tag auto-rolls and a CI run produces a fresh
# image per invocation anyway.
FROM alpine:3

# Test-fixture only — see README.md.
# The test password is supplied via --build-arg NAS_TEST_PASSWORD.
# Builds without this arg fail loud, so no default password ever ends up
# baked into the image.
ARG NAS_TEST_PASSWORD

RUN apk add --no-cache openssh-server bash coreutils sudo shadow jq \
    && ssh-keygen -A \
    && adduser -D -s /bin/bash nas-test \
    && [ -n "$NAS_TEST_PASSWORD" ] || (echo "Build requires --build-arg NAS_TEST_PASSWORD" >&2; exit 1) \
    && printf 'nas-test:%s\n' "$NAS_TEST_PASSWORD" | chpasswd \
    && echo 'nas-test ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/nas-test \
    && echo 'Defaults env_keep += "MOCK_DOCKER_DAEMON_STATE MOCK_COMPOSE_PROJECTS MOCK_COMPOSE_PS MOCK_COMPOSE_PS_PROJECT MOCK_COMPOSE_PULL_RESULT"' >> /etc/sudoers.d/nas-test \
    && chmod 0440 /etc/sudoers.d/nas-test \
    && mkdir -p /home/nas-test/.ssh \
    && chown nas-test:nas-test /home/nas-test/.ssh \
    && chmod 700 /home/nas-test/.ssh

COPY setup-stubs.sh /usr/local/bin/setup-stubs.sh
RUN chmod +x /usr/local/bin/setup-stubs.sh && /usr/local/bin/setup-stubs.sh

RUN sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config \
    && sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && printf '\n# Test-fixture tweaks: run-all.sh fires multiple ssh-copy-id calls in\n# rapid succession (one per test). ssh-copy-id always does a probe\n# pubkey-auth that fails before falling back to password auth, which\n# OpenSSH 9.8+ counts as "failed auth" and triggers PerSourcePenalties\n# (default on). After ~5 tests the source IP is penalised for 17s+ and\n# subsequent tests time out. Disable the penalty system in the mock —\n# real Synology NAS is not affected.\nPerSourcePenalties no\nMaxStartups 100:30:200\nMaxSessions 100\nMaxAuthTries 10\n' >> /etc/ssh/sshd_config

RUN cat > /entrypoint.sh <<'ENTRYPOINT_EOF'
#!/bin/bash
exec sudo /usr/sbin/sshd -D -e
ENTRYPOINT_EOF
RUN chmod +x /entrypoint.sh

# smartctl-Mock-Profile in den Container kopieren
COPY smartctl-profiles/ /opt/mock-smartctl/

EXPOSE 2222
USER nas-test
ENTRYPOINT ["/entrypoint.sh"]
