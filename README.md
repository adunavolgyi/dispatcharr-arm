# Dispatcharr AIO for ARM64 systems with 16 KiB pages

This repository builds a minimal derivative of the official Dispatcharr AIO image for ARM64 kernels that use 16 KiB memory pages, including relevant Raspberry Pi configurations.

Only `/usr/bin/redis-server` is replaced. Redis 8.10.1 is compiled with `MALLOC=libc` so it does not depend on jemalloc's unsupported page-size assumptions. The official Dispatcharr entrypoint, application, PostgreSQL, Celery, nginx, Redis tools, environment variables, and `/data` storage remain unchanged.

Current build defaults:

- Dispatcharr: `0.32.0`
- Official ARM64 base digest: `sha256:dce6a6617b23b221eac59e69544995e2a2c52906da05e41cf367145bf3c4e167`
- Redis: `8.10.1`, built with `MALLOC=libc`

The build deliberately fails if the upstream architecture, Redis package version, executable path, or Redis check-tool symlinks change.

## Usage

Follow the [official Dispatcharr setup](https://github.com/Dispatcharr/Dispatcharr) and change only the image reference:

```yaml
services:
  dispatcharr:
    image: ghcr.io/adunavolgyi/dispatcharr-arm:latest
```

Versioned tags are recommended for reproducible deployments:

```yaml
image: ghcr.io/adunavolgyi/dispatcharr-arm:0.32.0
```

This derivative does not require changes to the host kernel, network configuration, volumes, or other Dispatcharr settings.

## Local build and test

```sh
docker build --platform linux/arm64 -t dispatcharr-arm:0.32.0 .
sh scripts/test-image.sh dispatcharr-arm:0.32.0
```

On a native ARM64 host with 16 KiB pages:

```sh
REQUIRE_PAGE_SIZE=16384 sh scripts/test-image.sh dispatcharr-arm:0.32.0
```

For an existing container named `dispatcharr`, the short compatibility check is:

```sh
sh scripts/test-compatibility.sh
```

Its decisive probe is:

```sh
docker exec dispatcharr redis-cli ping
```

It must return `PONG`.

## Automated releases

[`upstream-release.yml`](.github/workflows/upstream-release.yml) runs every Sunday at 03:17 UTC and can also be started manually. It:

1. Selects the latest non-draft, non-prerelease `Dispatcharr/Dispatcharr` release.
2. Resolves and pins the official `linux/arm64` image digest.
3. Skips an unchanged upstream image that has already been published.
4. Registers ARM64 QEMU user-mode emulation on a GitHub-hosted x86 Linux worker.
5. Requires the ARM64 container to report a page size of exactly `16384` bytes.
6. Runs Redis startup, `PING`, AIO initialization, PostgreSQL/Celery, HTTP initialization, and authentication API tests under that emulated page size.
7. Pushes the versioned image only after every test passes, then updates `latest` to the same digest.
8. Leaves existing stable tags untouched and opens or updates a GitHub issue if processing fails.

No self-hosted runner, Raspberry Pi software, test-image pull, or manual promotion is required.

### What the 16 KiB test proves

QEMU's `QEMU_PAGESIZE=16384` mode makes the ARM64 processes inside the actual AIO image observe a 16 KiB page size. The workflow asserts that value before testing Redis and the complete application. This directly exercises the condition that caused the bundled jemalloc Redis binary to fail.

This is an emulated kernel-ABI compatibility test, not a physical Raspberry Pi hardware test. Raspberry Pi OS userspace is not used because containers use the Ubuntu userspace in the Dispatcharr image; the host contributes the kernel ABI, which is the part being emulated here.

## Repository and package settings

- Enable GitHub Actions and allow workflows to write packages and issues.
- Keep Issues enabled for automated failure reports.
- After GHCR creates the package for the first time, change its visibility to public if anonymous pulls are desired. A public Git repository does not automatically make its GHCR package public.
- The workflows use only `GITHUB_TOKEN`; no repository PAT is required.

## Tests

`scripts/test-image.sh IMAGE` checks:

- The container is ARM64 and observes the required page size.
- Redis 8.10.1 uses libc and starts successfully.
- `redis-cli ping` returns `PONG`.
- Redis check-tool symlinks still resolve to the replacement server.
- PostgreSQL, Celery, and the Dispatcharr web application initialize.
- Initial administrator creation, JWT issuance, and an authenticated request succeed.

`scripts/test-compatibility.sh` provides a shorter post-deployment check for a container named `dispatcharr`.

## Rollback

Restore the previous known-good versioned image tag using the normal deployment procedure for your environment. The derivative does not add migrations or modify persistent data outside the official Dispatcharr startup behavior.
