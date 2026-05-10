# Mock NAS — Test Fixture

> **Test fixture only.** Credentials are generated at build time and passed via ARG.
> No hardcoded passwords live in this image or in any test script.

Alpine + OpenSSH server with Synology-shaped stub files (`/etc/VERSION`,
`/etc/synoinfo.conf`, `/volume1/{documents,media,backups}`).

## Build (with random password)

    NAS_TEST_PASSWORD=$(openssl rand -hex 12)
    docker build --build-arg NAS_TEST_PASSWORD="$NAS_TEST_PASSWORD" -t mock-nas .

## Run

    docker run -d --rm --name mock-nas -p 12222:2222 mock-nas

## Test credentials

- User: `nas-test`
- Password: passed via `--build-arg NAS_TEST_PASSWORD`, exported to test scripts via the same env var.
- Port: `2222` (host: `12222`)

## What is mocked

- `/etc/VERSION` — fake DSM 7 line
- `/etc/synoinfo.conf` — fake `upnpmodelname` entry
- `/volume1/{documents,media,backups}` — three test shares
- `df -h`, `mount`, `uname` — native (real container values)
- `synoservice` — stub script with hardcoded service list

## What is NOT mocked

- `/proc/mdstat` — Linux-host-dependent, tests should tolerate absence
- BTRFS, snosnap, real DSM utilities
