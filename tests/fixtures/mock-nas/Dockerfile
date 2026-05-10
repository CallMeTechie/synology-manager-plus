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

RUN apk add --no-cache openssh-server bash coreutils sudo \
    && ssh-keygen -A \
    && adduser -D -s /bin/bash nas-test \
    && [ -n "$NAS_TEST_PASSWORD" ] || (echo "Build requires --build-arg NAS_TEST_PASSWORD" >&2; exit 1) \
    && printf 'nas-test:%s\n' "$NAS_TEST_PASSWORD" | chpasswd \
    && echo 'nas-test ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/nas-test \
    && chmod 0440 /etc/sudoers.d/nas-test \
    && mkdir -p /home/nas-test/.ssh \
    && chown nas-test:nas-test /home/nas-test/.ssh \
    && chmod 700 /home/nas-test/.ssh

COPY setup-stubs.sh /usr/local/bin/setup-stubs.sh
RUN chmod +x /usr/local/bin/setup-stubs.sh && /usr/local/bin/setup-stubs.sh

RUN sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config \
    && sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

RUN cat > /entrypoint.sh <<'ENTRYPOINT_EOF'
#!/bin/bash
exec sudo /usr/sbin/sshd -D -e
ENTRYPOINT_EOF
RUN chmod +x /entrypoint.sh

EXPOSE 2222
USER nas-test
ENTRYPOINT ["/entrypoint.sh"]
