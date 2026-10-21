# Dispatcharr AIO for Raspberry Pi 16 KiB kernels

This repository builds the smallest practical derivative of the official Dispatcharr AIO image: it replaces only `/usr/bin/redis-server` with Redis 8.10.1 compiled using `MALLOC=libc`. The official entrypoint, PostgreSQL, Celery, nginx, Redis tools, environment variables, and `/data` storage remain unchanged.

The current defaults target Dispatcharr 0.32.0:

- Official multi-platform index: `sha256:b7d695c5cc98b9abd64c74a94539c1ebffc23d965021613c820c67e25dea41a3`
- Official ARM64 manifest: `sha256:dce6a6617b23b221eac59e69544995e2a2c52906da05e41cf367145bf3c4e167`
- Redis package/source: `8.10.1`
- Redis executable: `/usr/bin/redis-server`

The Docker build fails if a future upstream image changes the architecture, Redis package version, executable path, or the `redis-check-aof`/`redis-check-rdb` symlinks. This prevents an upstream layout change from silently producing a misleading image.

## Build and test on the Raspberry Pi

```sh
docker build --platform linux/arm64 -t dispatcharr-arm:0.32.0 .
```

Use the local image in the existing Compose service. Gluetun remains unchanged and Dispatcharr still publishes no ports itself:

```yaml
dispatcharr:
  image: dispatcharr-arm:0.32.0
  container_name: dispatcharr
  restart: unless-stopped
  environment:
    - DISPATCHARR_ENV=aio
    - TZ=${TIMEZONE}
    - REDIS_HOST=localhost
    - CELERY_BROKER_URL=redis://localhost:6379/0
  volumes:
    - ${ROOT_DOCKER}/dispatcharr:/data
  depends_on:
    - gluetun
  network_mode: service:gluetun
```

Recreate only Dispatcharr, then run the real-device check:

```sh
docker compose up -d --no-deps --force-recreate dispatcharr
sh scripts/test-compatibility.sh
```

The decisive probe is:

```sh
docker exec dispatcharr redis-cli ping
```

It must return `PONG`. The script also requires `aarch64`, a host page size of exactly `16384`, Redis 8.10.1, and `malloc=libc`. It will not turn an ordinary 4 KiB ARM64 result into a Raspberry Pi compatibility claim.

## Automated releases

[`.github/workflows/upstream-release.yml`](.github/workflows/upstream-release.yml) runs every Sunday at 03:17 UTC and on manual dispatch. It:

1. Queries `Dispatcharr/Dispatcharr` releases and selects the newest non-draft, non-prerelease version.
2. Resolves that version's official `linux/arm64` GHCR manifest digest.
3. Uses GHCR tags as the version ledger, so an unchanged upstream version is not rebuilt or republished.
4. Builds natively on GitHub's ARM64 runner and runs Redis, AIO startup, PostgreSQL/Celery, HTTP initialization, and JWT authentication checks.
5. Rebuilds from the same pinned inputs on the Raspberry Pi and reruns the complete suite with `REQUIRE_PAGE_SIZE=16384` without publishing anything.
6. Pushes `:<upstream-version>` only after the Raspberry Pi test passes.
7. Updates `:latest` to that validated digest only after the versioned push succeeds.
8. Opens or updates a version-specific GitHub issue on failure. Existing stable tags remain untouched.

No candidate tag is published. The exact image pushed from the Raspberry Pi is tested locally first. If the versioned push succeeds but updating `:latest` fails, the next workflow run repairs `:latest` without rebuilding or republishing the version.

### Required Raspberry Pi runner

Install a GitHub Actions self-hosted runner for this private repository on the actual Raspberry Pi, then add the custom label:

```text
raspberry-pi-16k
```

The runner must have these labels: `self-hosted`, `linux`, `arm64`, and `raspberry-pi-16k`. Its account must be able to use the local Docker daemon. Confirm before enabling releases:

```sh
uname -m
getconf PAGESIZE
docker version
```

Expected architecture and page size are `aarch64` and `16384`. The workflow never deploys to the existing `dispatcharr` container; it uses an isolated temporary container and tmpfs-backed `/data` directory.

### Repository and package permissions

- Keep Actions enabled and allow workflows read/write package access.
- Keep Issues enabled so failures can be reported.
- The workflow uses only `GITHUB_TOKEN`; no PAT is stored in the repository.
- Confirm the generated `ghcr.io/<owner>/dispatcharr-arm` package remains private and grants this repository Actions access.

To pull the private stable image for normal Compose deployment, authenticate the Pi with a separate GitHub token that has only `read:packages`, then use:

```sh
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
docker pull ghcr.io/adunavolgyi/dispatcharr-arm:latest
```

## Tests

`scripts/test-image.sh IMAGE` is the CI test suite. It creates an ephemeral AIO instance and checks:

- Redis 8.10.1 is linked to libc and starts successfully.
- `redis-cli ping` returns `PONG`.
- Existing Redis check-tool symlinks resolve to the replacement server.
- PostgreSQL, Celery, and the Dispatcharr web application initialize.
- Initial admin creation, JWT token issuance, and an authenticated user request succeed.
- When `REQUIRE_PAGE_SIZE=16384` is set, the host really uses 16 KiB pages.

`scripts/test-compatibility.sh` is the short post-deployment check for the real `dispatcharr` container.

## Rollback

Pin Compose to the previous known-good versioned tag, then recreate only Dispatcharr:

```sh
docker compose up -d --no-deps --force-recreate dispatcharr
```

The image does not migrate or delete the host's existing `/data` volume outside Dispatcharr's normal upstream startup behavior.
